local mod_name = (...):match ( "^(.*)%..-$" )

local misc = require ( mod_name .. ".misc" )

local assert = assert
local ipairs = ipairs
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

function colmethods:insert(docs, continue_on_error, safe)
    if #docs < 1 then
        return nil, "docs needed"
    end

    safe = safe or 0
    continue_on_error = continue_on_error or 0
    local flags = 2^0*continue_on_error

    local t = { }
    for i , v in ipairs(docs) do
        t[i] = to_bson(v)
    end

    local m = num_to_le_uint(flags)..full_collection_name(self, self.col)
                ..t_concat(t)
    local _, send = docmd(self.conn, "INSERT", m)
    if send == 0 then
        return nil, "send message failed"
    end

    if safe ~= 0 then
        local r, err = self.db_obj:cmd({getlasterror=1})
        if not r then
            return nil, err
        end

        if r["err"] then
            return nil, r["err"]
        else
            return r["n"]
        end
    else
        return -1 end
end

function colmethods:update(selector, update, upsert, multiupdate, safe)
    safe = safe or 0
    upsert = upsert or 0
    multiupdate = multiupdate or 0
    local flags = 2^0*upsert + 2^1*multiupdate

    selector = to_bson(selector)
    update = to_bson(update)

    local m = "\0\0\0\0" .. full_collection_name(self, self.col)
                .. num_to_le_uint ( flags ) .. selector .. update
    local _, send = docmd(self.conn, "UPDATE", m)
    if send == 0 then
        return nil, "send message failed"
    end

    if safe ~= 0 then
        local r, err = self.db_obj:cmd({getlasterror=1})
        if not r then
            return nil, err
        end

        if r["err"] then
            return nil, r["err"]
        else
            return r["n"]
        end
    else return -1 end
end

function colmethods:delete(selector, single_remove, safe)
    safe = safe or 0
    single_remove = single_remove or 0
    local flags = 2^0*single_remove

    selector = to_bson(selector)

    local m = "\0\0\0\0" .. full_collection_name(self, self.col)
                .. num_to_le_uint(flags) .. selector

    local _, sent = docmd(self.conn, "DELETE", m)
    if sent == 0 then
        return nil, "send message failed"
    end

    if safe ~= 0 then
        local r, err = self.db_obj:cmd({getlasterror=1})
        if not r then
            return nil, err
        end

        if r["err"] then
            return nil, r["err"]
        else
            return r["n"]
        end
    else return -1 end
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
