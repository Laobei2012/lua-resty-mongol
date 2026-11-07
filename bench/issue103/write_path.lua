-- Diagnostic endpoints for issue 103: the same insert of 100 documents
-- through two server write paths, with the new driver's connection, login
-- and BSON encoder. The driver and the standard handlers stay unchanged.
--   msg:    the driver's OP_MSG insert command (acknowledged, ordered)
--   legacy: OP_INSERT, then getlasterror through OP_QUERY on bench.$cmd,
--           the same messages as the old driver 3eb6349
local mongol = require "resty.mongol"
local bson = require "resty.mongol.bson"
local ll = require "resty.mongol.ll"

local num_to_le_uint, num_to_le_int = ll.num_to_le_uint, ll.num_to_le_int
local le_uint_to_num = ll.le_uint_to_num
local concat = table.concat

local HOST = os.getenv("MONGO_HOST") or "127.0.0.1"
local PORT = tonumber(os.getenv("MONGO_PORT")) or 27017
local DB, COL = "bench", "write"
local USER, PASSWORD = "bench", "bench"
local BODY = string.rep("x", 200)
local OP_REPLY, OP_INSERT, OP_QUERY = 1, 2002, 2004
local GETLASTERROR = bson.to_bson({ getlasterror = 1 })

local _M = {}

local function fail(conn, what, err)
    ngx.log(ngx.ERR, what, ": ", tostring(err))
    if conn then
        conn:close()
    end
    return ngx.exit(500)
end

-- Same login rule as bench/handlers.lua: only a new socket logs in.
local function connect()
    local conn = mongol:new()
    conn:set_timeout(10000)
    local ok, err = conn:connect(HOST, PORT)
    if not ok then
        return nil, nil, "connect: " .. tostring(err)
    end
    local db = conn:new_db_handle(DB)
    if conn:get_reused_times() == 0 then
        ok, err = db:auth_scram_sha1(USER, PASSWORD)
        if not ok then
            conn:close()
            return nil, nil, "auth: " .. tostring(err)
        end
    end
    return conn, db
end

local function new_docs()
    local docs = {}
    for i = 1, 100 do
        docs[i] = { name = "user" .. i, age = i % 100, tags = "a b c", body = BODY }
    end
    return docs
end

-- Request IDs far above the driver's own counter, which starts at 1.
local request_id = 1500000000
local function send(sock, opcode, body)
    request_id = request_id + 1
    local msg = num_to_le_uint(#body + 16) .. num_to_le_uint(request_id)
        .. "\0\0\0\0" .. num_to_le_uint(opcode) .. body
    local ok, err = sock:send(msg)
    if not ok then
        return nil, err
    end
    return request_id
end

local function legacy_insert(conn, docs)
    local sock = conn.sock
    local parts = {}
    for i, d in ipairs(docs) do
        parts[i] = assert(bson.to_bson(d))
    end
    -- flags 0: stop at the first error, as the old driver does
    local ok, err = send(sock, OP_INSERT,
        "\0\0\0\0" .. DB .. "." .. COL .. "\0" .. concat(parts))
    if not ok then
        return nil, err
    end
    local id
    id, err = send(sock, OP_QUERY, "\0\0\0\0" .. DB .. ".$cmd\0" .. "\0\0\0\0"
        .. num_to_le_int(-1) .. GETLASTERROR)
    if not id then
        return nil, err
    end
    local header
    header, err = sock:receive(16)
    if not header then
        return nil, err
    end
    local len = le_uint_to_num(header, 1, 4)
    if le_uint_to_num(header, 9, 12) ~= id or le_uint_to_num(header, 13, 16) ~= OP_REPLY then
        return nil, "unexpected reply header"
    end
    local data
    data, err = sock:receive(len - 16)
    if not data then
        return nil, err
    end
    -- flags 4, cursorID 8, startingFrom 4, numberReturned 4, then one document
    if le_uint_to_num(data, 17, 20) ~= 1 then
        return nil, "getlasterror returned no document"
    end
    local reply = bson.decode(data, 21)
    if reply.ok ~= 1 then
        return nil, reply.errmsg or "getlasterror failed"
    end
    if reply.err ~= nil and reply.err ~= bson.null then
        return nil, reply.err
    end
    return true
end

local function finish(conn)
    local ok, err = conn:set_keepalive(10000, 100)
    if not ok then
        return fail(nil, "set_keepalive", err)
    end
    return ngx.exit(200)
end

function _M.msg()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "insert_100_msg", err)
    end
    local r
    r, err = db:get_col(COL):insert(new_docs(), nil, true)
    if r == nil then
        return fail(conn, "insert_100_msg", err)
    end
    return finish(conn)
end

function _M.legacy()
    local conn, _, err = connect()
    if not conn then
        return fail(nil, "insert_100_legacy", err)
    end
    local ok
    ok, err = legacy_insert(conn, new_docs())
    if not ok then
        return fail(conn, "insert_100_legacy", err)
    end
    return finish(conn)
end

return _M
