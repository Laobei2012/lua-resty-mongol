-- One function for each location of nginx.conf.in. Each one does one
-- driver call, checks the result and ends the request with 200 or 500.
-- Only the API forms that both the old driver (3eb6349) and the new one
-- accept are used; see docs/superpowers/plans/2026-10-27-performance-test.md.

local mongol = require "resty.mongol"

local ngx = ngx
local tostring = tostring
local tonumber = tonumber
local random = math.random

local HOST = os.getenv("MONGO_HOST") or "127.0.0.1"
local PORT = tonumber(os.getenv("MONGO_PORT")) or 27017
local DB = "bench"
local USER, PASSWORD = "bench", "bench"
local NDOCS = 1000
local FILE_SIZE = 1048576
local BODY = string.rep("x", 200)

local _M = {}

-- APIs that the old driver cannot run, with the reason. Under the old
-- driver their handlers return 501 with the reason as the body, so the
-- runner can skip them and the report shows n/a (old).
_M.old_unsupported = {
    -- 3eb6349 colmt.lua handle_reply numbers the documents of every reply
    -- from 1 and ignores offset_i, and cursor:next looks for the document
    -- at i + 1, so it ends after the first batch: 50 of 100 documents,
    -- after a getMore for every other batch of the collection
    find_100 = "the old cursor drops every batch after the first",
}

-- the new driver has a version; the module() table of the old one has not
-- (rawget: package.seeall would find _G._VERSION)
local OLD = rawget(mongol, "_VERSION") == nil

local function unsupported(name)
    local reason = OLD and _M.old_unsupported[name]
    if not reason then
        return false
    end
    ngx.status = 501
    ngx.print(reason)
    ngx.exit(501)
    return true
end

local function fail(conn, what, err)
    ngx.log(ngx.ERR, what, ": ", tostring(err))
    if conn then
        conn:close()
    end
    return ngx.exit(500)
end

-- Connects and, on a new socket, logs in: auth is per connection and all
-- locations share one pool, so a socket must never go back to the pool
-- without a login.
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

local function done(conn)
    local ok, err = conn:set_keepalive(10000, 100)
    if not ok then
        return fail(nil, "set_keepalive", err)
    end
    return ngx.exit(200)
end

-- a new document for the write collection; the server sets _id
local function new_doc(i)
    return { name = "user" .. i, age = i % 100, tags = "a b c", body = BODY }
end

-- _id of /delete_insert: unique because worker_processes is 1 and the
-- collection is re-seeded before each API
local last_id = 1000000

local function next_id()
    last_id = last_id + 1
    return last_id
end

function _M.ping()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "ping", err)
    end
    local r
    r, err = db:cmd({ ping = 1 })
    if not r then
        return fail(conn, "ping", err)
    end
    return done(conn)
end

function _M.find_one()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "find_one", err)
    end
    local doc
    doc, err = db:get_col("read"):find_one({ _id = random(1, NDOCS) })
    if not doc then
        return fail(conn, "find_one", err or "no document")
    end
    return done(conn)
end

function _M.find_100()
    if unsupported("find_100") then
        return
    end
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "find_100", err)
    end
    local cursor
    cursor, err = db:get_col("read"):find({}, nil, 50)
    if not cursor then
        return fail(conn, "find_100", err)
    end
    cursor:limit(100)
    local n = 0
    while true do
        local i, v = cursor:next()
        if not i then
            if v then
                return fail(conn, "find_100", v)
            end
            break
        end
        n = n + 1
    end
    if n ~= 100 then
        return fail(conn, "find_100", "got " .. n .. " documents")
    end
    return done(conn)
end

function _M.count()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "count", err)
    end
    local n
    n, err = db:get_col("read"):count({ age = 7 })
    if n ~= NDOCS / 100 then
        return fail(conn, "count", err or ("got " .. tostring(n)))
    end
    return done(conn)
end

-- The old insert returns getlasterror.n, which is 0 for inserts, so the
-- insert handlers check only for nil.
function _M.insert_1()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "insert_1", err)
    end
    local r
    r, err = db:get_col("write"):insert({ new_doc(1) }, nil, true)
    if r == nil then
        return fail(conn, "insert_1", err)
    end
    return done(conn)
end

function _M.insert_100()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "insert_100", err)
    end
    local docs = {}
    for i = 1, 100 do
        docs[i] = new_doc(i)
    end
    local r
    r, err = db:get_col("write"):insert(docs, nil, true)
    if r == nil then
        return fail(conn, "insert_100", err)
    end
    return done(conn)
end

function _M.update()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "update", err)
    end
    local n
    n, err = db:get_col("write"):update({ _id = random(1, NDOCS) },
                                        { ["$inc"] = { age = 1 } },
                                        nil, nil, true)
    if n ~= 1 then
        return fail(conn, "update", err or ("updated " .. tostring(n)))
    end
    return done(conn)
end

function _M.delete_insert()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "delete_insert", err)
    end
    local col = db:get_col("write")
    local id = next_id()
    local doc = new_doc(id)
    doc._id = id
    local r
    r, err = col:insert({ doc }, nil, true)
    if r == nil then
        return fail(conn, "delete_insert: insert", err)
    end
    r, err = col:delete({ _id = id }, 1, true)
    if r ~= 1 then
        return fail(conn, "delete_insert: delete",
                    err or ("deleted " .. tostring(r)))
    end
    return done(conn)
end

function _M.find_and_modify()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "find_and_modify", err)
    end
    -- a new table for each request: the old driver sets
    -- options.findAndModify
    local doc
    doc, err = db:get_col("write"):find_and_modify({
        query = { _id = random(1, NDOCS) },
        update = { ["$inc"] = { age = 1 } },
    })
    if type(doc) ~= "table" then
        return fail(conn, "find_and_modify", err or "no document")
    end
    return done(conn)
end

function _M.gridfs_read()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "gridfs_read", err)
    end
    local f
    f, err = db:get_gridfs("fs"):find_one({ filename = "f1m" })
    if not f then
        return fail(conn, "gridfs_read", err or "no file")
    end
    local data
    data, err = f:read(FILE_SIZE, 0)
    if not data or #data ~= FILE_SIZE then
        return fail(conn, "gridfs_read",
                    err or ("read " .. tostring(data and #data) .. " bytes"))
    end
    return done(conn)
end

-- SCRAM-SHA-1 on a pooled socket, in both drivers
function _M.auth()
    local conn, db, err = connect()
    if not conn then
        return fail(nil, "auth", err)
    end
    local ok
    ok, err = db:auth_scram_sha1(USER, PASSWORD)
    if not ok then
        return fail(conn, "auth", err)
    end
    return done(conn)
end

-- The cost of a new socket: no login, since the socket is closed. Sockets
-- that other locations left in the pool are used up in the warm-up.
function _M.connect_nopool()
    local conn = mongol:new()
    conn:set_timeout(10000)
    local ok, err = conn:connect(HOST, PORT)
    if not ok then
        return fail(nil, "connect_nopool: connect", err)
    end
    local r
    r, err = conn:new_db_handle(DB):cmd({ ping = 1 })
    if not r then
        return fail(conn, "connect_nopool: ping", err)
    end
    conn:close()
    return ngx.exit(200)
end

-- not benchmarked: the body is the reused count of the socket
function _M.reuse()
    local conn, _, err = connect()
    if not conn then
        return fail(nil, "reuse", err)
    end
    ngx.print(conn:get_reused_times())
    return done(conn)
end

return _M
