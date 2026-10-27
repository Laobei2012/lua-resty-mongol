local mod_name = (...):match ( "^(.*)%..-$" )

local setmetatable = setmetatable
local getmetatable = getmetatable
local assert = assert
local next = next
local table = table
local t_insert = table.insert
local t_concat = table.concat
local strbyte = string.byte
local strformat = string.format

local ll = require ( mod_name .. ".ll" )
local int64_to_le = ll.int64_to_le

local ZERO_ID = "\0\0\0\0\0\0\0\0"

local cursor_methods = { }
local cursor_mt = { __index = cursor_methods }

-- the documents of the current batch are in results[1 .. n_batch]; the
-- documents that next() returned are set to nil. base is the value of i
-- when the batch arrived, so results[i - base + 1] is the next document.
local function new_cursor(col, query, returnfields, num_each_query)
    return setmetatable ( {
            col = col ;
            query = query ;
            returnfields = returnfields ;

            id = false ;
            results = { } ;
            n_batch = 0 ;
            base = 0 ;

            started = false ;
            done = false ;
            i = 0;
            limit_n = 0;
            skip_n = 0;
            sort_spec = nil ;
            num_each = num_each_query;
        } , cursor_mt )
end

-- a cursor from the cursor document of a command reply (aggregate,
-- listCollections); the collection for getMore and killCursors comes
-- from the namespace of the reply
local function from_reply(col, reply_cursor, num_each, session)
    local name = reply_cursor.ns:match("^[^.]+%.(.*)$") or reply_cursor.ns
    local ncol = setmetatable({
            conn = col.conn;
            db_obj = col.db_obj;
            db = col.db;
            col = name;
        }, getmetatable(col))
    local batch = reply_cursor.firstBatch or {}
    local id = int64_to_le(reply_cursor.id)
    local c = new_cursor(ncol, nil, nil, num_each or 0)
    c.session = session
    c.started = true
    c.id = id
    c.results = batch
    c.n_batch = #batch
    c.done = id == ZERO_ID
    return c
end

cursor_mt.__tostring = function ( ob )
    local t = { }
    if ob.id then
        for i = 1 , 8 do
            t_insert(t, strformat("%02x", strbyte(ob.id, i, i)))
        end
    end
    return "CursorId(" .. t_concat ( t ) .. ")"
end

function cursor_methods:limit(n)
    assert(n)
    if self.started then return nil, "cursor already started" end
    self.limit_n = n
    return true
end

function cursor_methods:skip(n)
    assert(n)
    if self.started then return nil, "cursor already started" end
    self.skip_n = n
    return true
end

-- stores a batch that col:query or col:getmore returned
local function take_batch(self, id, results, err)
    if not id then
        self.done = true
        return nil, results
    end
    if err then
        self.done = true
        return nil, err
    end
    self.id = id
    self.results = results
    self.n_batch = #results
    self.base = self.i
    if id == ZERO_ID then
        self.done = true
    end
    return true
end

local function fetch_first(self, options)
    self.started = true
    local limit = self.limit_n > 0 and self.limit_n or nil
    if limit or options then
        options = options or {}
        options.limit = limit
    end
    local id, results, _, err = self.col:query(self.query, self.returnfields,
                                    self.skip_n, self.num_each, options)
    return take_batch(self, id, results, err)
end

function cursor_methods:sort(field, size)
    size = size or 10000
    if size < 2 then return nil, "number of object must > 1" end
    if not field then return nil, "field should not be nil" end

    local key, asc = next(field)
    if asc ~= 1 and asc ~= -1 then return nil, "order must be 1 or -1" end

    local remaining = self.n_batch - (self.i - self.base)
    if not self.started then
        -- the server sorts all documents
        self.sort_spec = field
        local ok, err = fetch_first(self, {sort = field})
        if not ok then return nil, err end
        return self.results
    elseif remaining > 0 then
        -- the rest of the current batch is sorted on the client
        local rest = { }
        for k = self.i - self.base + 1, self.n_batch do
            rest[#rest + 1] = self.results[k]
        end
        table.sort(rest, function(a, b)
            if not a and not b then return false end
            if not a then return true end
            if not b then return false end
            if not a[key] and not b[key] then return false end
            if not a[key] then return true end
            if not b[key] then return false end
            if asc == 1 then
                return a[key] < b[key]
            else
                return a[key] > b[key]
            end
        end)
        self.results = rest
        self.n_batch = #rest
        self.base = self.i
        return self.results
    end
    return nil, "sort must be an array"
end

function cursor_methods:next()
    while true do
        if self.limit_n > 0 and self.i >= self.limit_n then return nil end

        local idx = self.i - self.base + 1
        local v = self.results [ idx ]
        if idx <= self.n_batch and v ~= nil then
            self.i = self.i + 1
            self.results [ idx ] = nil
            return self.i , v
        end

        if self.done then return nil end

        local ok, err
        if not self.started then
            ok, err = fetch_first(self)
        else
            local id, results, _, merr = self.col:getmore(self.id,
                            self.num_each, self.i)
            ok, err = take_batch(self, id, results, merr)
        end
        if not ok then return nil, err end
    end
end

-- kills the cursor on the server; the finalizer cannot do this, because
-- a finalizer cannot use cosockets
function cursor_methods:close()
    local id = self.id
    self.done = true
    self.results = { }
    self.n_batch = 0
    if id and id ~= ZERO_ID then
        self.id = ZERO_ID
        local ok, err = self.col:kill_cursors({ id })
        if not ok then return nil, err end
    end
    return true
end

function cursor_methods:pairs( )
    return self.next, self
end

return setmetatable({
    new = new_cursor ;
    from_reply = from_reply ;
}, { __call = function ( _, ... ) return new_cursor ( ... ) end })
