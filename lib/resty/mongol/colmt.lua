local mod_name = (...):match ( "^(.*)%..-$" )

local misc = require ( mod_name .. ".misc" )

local assert = assert
local error = error
local ipairs = ipairs
local type = type
local t_concat = table.concat

local attachpairs_start = misc.attachpairs_start

local ll = require ( mod_name .. ".ll" )
local num_to_le_uint = ll.num_to_le_uint
local num_to_le_int = ll.num_to_le_int
local le_uint_to_num = ll.le_uint_to_num
local le_bpeek = ll.le_bpeek

local getlib = require ( mod_name .. ".get" )
local get_from_string = getlib.get_from_string

local bson = require ( mod_name .. ".bson" )
local from_bson = bson.from_bson
local to_bson = bson.to_bson
local ordered = bson.ordered

local wire = require ( mod_name .. ".wire" )

local new_cursor = require ( mod_name .. ".cursor" )

local colmethods = { }
local colmt = { __index = colmethods }


local opcodes = {
    REPLY = 1 ;
    MSG = 1000 ;
    UPDATE = 2001 ;
    INSERT = 2002 ;
    QUERY = 2004 ;
    GET_MORE = 2005 ;
    DELETE = 2006 ;
    KILL_CURSORS = 2007 ;
}

local function compose_msg ( requestID , reponseTo , opcode , message )
    return num_to_le_uint ( #message + 16 ) .. requestID .. reponseTo .. opcode .. message
end

local function full_collection_name ( self , collection )
    local db = assert ( self.db , "Not current in a database" )
    return  db .. "." .. collection .. "\0"
end

local id = 0
local function docmd ( conn , opcode , message ,  reponseTo )
    id = id + 1
    local req_id = id
    local requestID = num_to_le_uint ( req_id )
    reponseTo = reponseTo or "\255\255\255\255"
    opcode = num_to_le_uint ( assert ( opcodes [ opcode ] ) )

    local m = compose_msg ( requestID , reponseTo , opcode , message )
    local sent = assert ( conn.sock:send ( m ) )
    return req_id , sent
end

local function read_msg_header ( sock )
    local header = assert ( sock:receive ( 16 ) )

    local length = le_uint_to_num ( header , 1 , 4 )
    local requestID = le_uint_to_num ( header , 5 , 8 )
    local reponseTo = le_uint_to_num ( header , 9 , 12 )
    local opcode = le_uint_to_num ( header , 13 , 16 )

    return length , requestID , reponseTo , opcode
end

local function handle_reply ( conn , req_id )

    local r_len , _ , r_res_id , opcode = read_msg_header ( conn.sock )
    assert ( req_id == r_res_id )
    assert ( opcode == opcodes.REPLY )
    local data = assert ( conn.sock:receive ( r_len - 16 ) )
    local get = get_from_string ( data )

    local responseFlags = get ( 4 )
    local cursorid = get ( 8 )

    local t = { }
    t.startingFrom = le_uint_to_num ( get ( 4 ) )
    t.numberReturned = le_uint_to_num ( get ( 4 ) )
    t.CursorNotFound = le_bpeek ( responseFlags , 0 )
    t.QueryFailure = le_bpeek ( responseFlags , 1 )
    t.ShardConfigStale = le_bpeek ( responseFlags , 2 )
    t.AwaitCapable = le_bpeek ( responseFlags , 3 )

    local r = { }
    for i = 1 , t.numberReturned do
        r[i] = from_bson(get)
    end

    return cursorid, r, t
end

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

function colmethods:kill_cursors(cursorIDs)
    local n = #cursorIDs
    cursorIDs = t_concat(cursorIDs)

    local m = "\0\0\0\0" .. full_collection_name(self, self.col)
                .. num_to_le_uint(n) .. cursorIDs

    return docmd(self.conn, "KILL_CURSORS", m )
end

function colmethods:query(query, returnfields, numberToSkip, numberToReturn, options)
    numberToSkip = numberToSkip or 0

    local flags = 0
    if options then
        flags = 2^1*( options.TailableCursor and 1 or 0 )
            + 2^2*( options.SlaveOk and 1 or 0 )
            + 2^3*( options.OplogReplay and 1 or 0 )
            + 2^4*( options.NoCursorTimeout and 1 or 0 )
            + 2^5*( options.AwaitData and 1 or 0 )
            + 2^6*( options.Exhaust and 1 or 0 )
            + 2^7*( options.Partial and 1 or 0 )
    end

    query = to_bson(query)
    if returnfields then
        returnfields = to_bson(returnfields)
    else
        returnfields = ""
    end

    local m = num_to_le_uint(flags) .. full_collection_name(self, self.col)
        .. num_to_le_uint(numberToSkip) .. num_to_le_int(numberToReturn or -1 )
        .. query .. returnfields

    local req_id = docmd(self.conn, "QUERY", m)
    return handle_reply(self.conn, req_id)
end

function colmethods:getmore(cursorID, numberToReturn, offset_i)
    local m = "\0\0\0\0" .. full_collection_name(self, self.col)
                .. num_to_le_int(numberToReturn or 0) .. cursorID

    local req_id = docmd(self.conn, "GET_MORE" , m)
    return handle_reply(self.conn, req_id)
end

function colmethods:count(query)
    local r, err = self.db_obj:cmd(attachpairs_start({
            count = self.col;
            query = query or { } ;
        } , "count" ) )

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

function colmethods:find_one(query, returnfields)
    local id, results = self:query(query, returnfields, 0, 1)
    if id == "\0\0\0\0\0\0\0\0" and results[1] then
        return results[1]
    end
    return nil
end

-- see https://docs.mongodb.com/manual/reference/command/findAndModify
function colmethods:find_and_modify(options)
    assert(options.query)
    assert(options.update or options.remove)
    options.findAndModify = self.col
    local doc,err = self.db_obj:cmd(attachpairs_start(options,"findAndModify"))
    if not doc then
        return nil,err
    end
    return doc.value
end

return colmt
