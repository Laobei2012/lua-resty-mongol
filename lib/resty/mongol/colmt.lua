local mod_name = (...):match ( "^(.*)%..-$" )

local error = error
local next = next
local ipairs , pairs = ipairs , pairs
local type = type
local math_abs = math.abs

local ll = require ( mod_name .. ".ll" )
local int64_to_le = ll.int64_to_le
local le_to_int64 = ll.le_to_int64

local bson = require ( mod_name .. ".bson" )
local to_bson = bson.to_bson
local ordered = bson.ordered
local int32 = bson.int32
local int64 = bson.int64
local null = bson.null

local wire = require ( mod_name .. ".wire" )

local new_cursor = require ( mod_name .. ".cursor" )

local colmethods = { }
local colmt = { __index = colmethods }

local ZERO_ID = "\0\0\0\0\0\0\0\0"

-- nil, false and 0 are false; Lua treats 0 as true, so the write
-- arguments must not be tested directly
local function flag(v)
    return not (v == nil or v == false or v == 0)
end

-- the first error message of a write reply, or nil
local function write_error(r)
    local we = r.writeErrors
    if type(we) == "table" and we[1] then
        return we[1].errmsg or "write error"
    end
    local wce = r.writeConcernError
    if type(wce) == "table" then
        return wce.errmsg or "write concern error"
    end
end

-- sends a write command; returns the reply | nil, err
local function write(self, cmd, seq_name, docs, safe)
    if not flag(safe) then
        cmd[#cmd + 1] = {"writeConcern", {w = 0}}
        local ok, err = wire.send_only(self.conn, self.db, ordered(cmd),
                                       {{seq_name, docs}})
        if not ok then
            return nil, err
        end
        return -1
    end
    local r, err = wire.command(self.conn, self.db, ordered(cmd),
                                {{seq_name, docs}})
    if not r then
        return nil, err
    end
    err = write_error(r)
    if err then
        return nil, err, r
    end
    return r
end

function colmethods:insert(docs, continue_on_error, safe)
    if type(docs) ~= "table" then
        error("bad argument #1 to 'insert' (table expected)", 2)
    end
    if #docs < 1 then
        return nil, "docs needed"
    end

    local is_ordered = not flag(continue_on_error)
    local limits = wire.limits

    local encoded = {}
    for i, d in ipairs(docs) do
        local s, err = to_bson(d)
        if not s then
            return nil, err
        end
        if #s > limits.max_bson_size then
            return nil, "document too large"
        end
        encoded[i] = s
    end

    local function command()
        local cmd = {{"insert", self.col}, {"ordered", is_ordered}}
        if not flag(safe) then
            cmd[3] = {"writeConcern", {w = 0}}
        end
        return ordered(cmd)
    end

    -- the size of a message without its documents
    local empty = wire.encode_msg(self.db, command(), {{"documents", {}}}, 0)
    if not empty then
        return nil, "message too large"
    end
    local base = #empty

    local batches, batch, size = {}, {}, base
    for _, s in ipairs(encoded) do
        if base + #s > limits.max_message_size then
            return nil, "document too large"
        end
        if #batch >= limits.max_write_batch_size
           or size + #s > limits.max_message_size then
            batches[#batches + 1] = batch
            batch, size = {}, base
        end
        batch[#batch + 1] = s
        size = size + #s
    end
    batches[#batches + 1] = batch

    local first_err
    for _, b in ipairs(batches) do
        local cmd = {{"insert", self.col}, {"ordered", is_ordered}}
        local r, err, reply = write(self, cmd, "documents", b, safe)
        if not r then
            -- a socket or command error stops an unordered insert too
            if is_ordered or not reply then
                return nil, err
            end
            first_err = first_err or err
        end
    end
    if first_err then
        return nil, first_err
    end
    if not flag(safe) then
        return -1
    end
    return 0
end

function colmethods:update(selector, update, upsert, multiupdate, safe)
    if type(selector) ~= "table" then
        error("bad argument #1 to 'update' (table expected)", 2)
    end
    if type(update) ~= "table" then
        error("bad argument #2 to 'update' (table expected)", 2)
    end
    local stmt = {
        q = selector,
        u = update,
        upsert = flag(upsert),
        multi = flag(multiupdate),
    }
    local r, err = write(self, {{"update", self.col}}, "updates", {stmt}, safe)
    if not r then
        return nil, err
    end
    if r == -1 then
        return -1
    end
    return r.n
end

function colmethods:delete(selector, single_remove, safe)
    if type(selector) ~= "table" then
        error("bad argument #1 to 'delete' (table expected)", 2)
    end
    local stmt = {
        q = selector,
        limit = flag(single_remove) and 1 or 0,
    }
    local r, err = write(self, {{"delete", self.col}}, "deletes", {stmt}, safe)
    if not r then
        return nil, err
    end
    if r == -1 then
        return -1
    end
    return r.n
end

local function cursor_flags(start, n)
    return {
        CursorNotFound = false,
        QueryFailure = false,
        ShardConfigStale = false,
        AwaitCapable = true,
        startingFrom = start or 0,
        numberReturned = n or 0,
    }
end

-- turns a find or getMore reply into the legacy return values
local function cursor_result(conn, r, err, doc, start, batch_name)
    if not r then
        if not doc then
            return nil, err
        end
        local flags = cursor_flags(start, 0)
        if doc.code == 43 then
            flags.CursorNotFound = true
        else
            flags.QueryFailure = true
        end
        return ZERO_ID, {}, flags, err
    end
    local c = r.cursor
    local batch, cerr = new_cursor.check_reply(conn, c, batch_name)
    if not batch then
        return nil, cerr
    end
    return int64_to_le(c.id), batch, cursor_flags(start, #batch)
end

function colmethods:query(query, returnfields, numberToSkip, numberToReturn,
                          options)
    numberToSkip = numberToSkip or 0
    options = options or {}

    local cmd = {{"find", self.col}, {"filter", query or {}}}
    if returnfields then
        cmd[#cmd + 1] = {"projection", returnfields}
    end
    if numberToSkip > 0 then
        cmd[#cmd + 1] = {"skip", int32(numberToSkip)}
    end
    if options.sort then
        cmd[#cmd + 1] = {"sort", options.sort}
    end

    local n = numberToReturn
    local limit = options.limit
    if n == nil then
        -- the old code sent numberToReturn or -1
        cmd[#cmd + 1] = {"singleBatch", true}
        limit = 1
    elseif n == 1 or n < 0 then
        n = math_abs(n)
        cmd[#cmd + 1] = {"singleBatch", true}
        cmd[#cmd + 1] = {"batchSize", int32(n)}
        limit = n
    elseif n > 1 then
        cmd[#cmd + 1] = {"batchSize", int32(n)}
    end
    if limit and limit > 0 then
        cmd[#cmd + 1] = {"limit", int64(limit)}
    end

    if options.TailableCursor then cmd[#cmd + 1] = {"tailable", true} end
    if options.AwaitData then cmd[#cmd + 1] = {"awaitData", true} end
    if options.NoCursorTimeout then
        cmd[#cmd + 1] = {"noCursorTimeout", true}
    end
    if options.Partial then
        cmd[#cmd + 1] = {"allowPartialResults", true}
    end

    local conn = options.conn or self.conn
    local r, err, doc = wire.command(conn, self.db, ordered(cmd))
    return cursor_result(conn, r, err, doc, numberToSkip, "firstBatch")
end

function colmethods:getmore(cursorID, numberToReturn, offset_i, opts)
    if type(cursorID) ~= "string" or #cursorID ~= 8 then
        error("bad argument #1 to 'getmore' (8-byte cursor id expected)", 2)
    end
    local cmd = {
        {"getMore", int64(le_to_int64(cursorID, 1))},
        {"collection", self.col},
    }
    if numberToReturn and numberToReturn > 0 then
        cmd[3] = {"batchSize", int32(numberToReturn)}
    end
    local conn = opts and opts.conn or self.conn
    local r, err, doc = wire.command(conn, self.db, ordered(cmd))
    return cursor_result(conn, r, err, doc, offset_i, "nextBatch")
end

function colmethods:kill_cursors(cursorIDs, opts)
    local ids = {}
    for i, id in ipairs(cursorIDs) do
        ids[i] = int64(le_to_int64(id, 1))
    end
    if #ids == 0 then
        return true
    end
    local conn = opts and opts.conn or self.conn
    local r, err = wire.command(conn, self.db, ordered{
        {"killCursors", self.col},
        {"cursors", ids},
    })
    if not r then
        return nil, err
    end
    return true
end

function colmethods:count(query)
    local r, err = wire.command(self.conn, self.db, ordered{
        {"count", self.col},
        {"query", query or {}},
    })
    if not r then
        return nil, err
    end
    return r.n
end

function colmethods:drop()
    local r, err = self.db_obj:cmd({drop = self.col})
    if not r then
        return nil, err
    end
    return 1
end

function colmethods:find(query, returnfields, num_each_query)
    num_each_query = num_each_query or 100
    if num_each_query == 1 then
        return nil, "num_each_query must larger than 1"
    end
    return new_cursor(self, query, returnfields, num_each_query)
end

-- runs an aggregation pipeline and returns a cursor over the results;
-- options.batch_size is the batch size of each fetch (default 100)
function colmethods:aggregate(pipeline, options)
    if type(pipeline) ~= "table" then
        error("bad argument #1 to 'aggregate' (table expected)", 2)
    end
    if options ~= nil and type(options) ~= "table" then
        error("bad argument #2 to 'aggregate' (table expected)", 2)
    end
    local batch_size = options and options.batch_size or 100
    if type(batch_size) ~= "number" or batch_size < 0
       or batch_size ~= batch_size - batch_size % 1 then
        error("bad argument #2 to 'aggregate' "
              .. "(batch_size must be a non-negative integer)", 2)
    end
    if next(pipeline) == nil then
        pipeline = bson.empty_array
    end
    local r, err = wire.command(self.conn, self.db, ordered{
        {"aggregate", self.col},
        {"pipeline", pipeline},
        {"cursor", {batchSize = int32(batch_size)}},
    })
    if not r then
        return nil, err
    end
    return new_cursor.from_reply(self, r.cursor, batch_size)
end

function colmethods:find_one(query, returnfields)
    local id, results, _, err = self:query(query, returnfields, 0, 1)
    if not id then
        return nil, results
    end
    if err then
        return nil, err
    end
    return results[1]
end

-- see https://docs.mongodb.com/manual/reference/command/findAndModify
function colmethods:find_and_modify(options)
    if type(options) ~= "table" or options.query == nil then
        error("bad argument #1 to 'find_and_modify' (query expected)", 2)
    end
    if options.update == nil and not options.remove then
        error("bad argument #1 to 'find_and_modify' "
              .. "(update or remove expected)", 2)
    end
    local cmd = {{"findAndModify", self.col}}
    for k, v in pairs(options) do
        if k ~= "findAndModify" then
            cmd[#cmd + 1] = {k, v}
        end
    end
    local doc, err = wire.command(self.conn, self.db, ordered(cmd))
    if not doc then
        return nil, err
    end
    if doc.value == null then
        return nil
    end
    return doc.value
end


return colmt
