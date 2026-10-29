-- Seeds the bench fixtures. Run it with the new driver, whatever MONGOL_LIB
-- the server uses: resty -I <new>/lib bench/seed.lua
--
-- Drops only the fixture collections, never the database, so the user
-- bench and the sockets that nginx holds logged in as it stay valid. Safe
-- to run any number of times while nginx is up.

local mongol = require "resty.mongol"
local bson = require "resty.mongol.bson"

local HOST = os.getenv("MONGO_HOST") or "127.0.0.1"
local PORT = tonumber(os.getenv("MONGO_PORT")) or 27017
local ADMIN_USER = os.getenv("MONGO_ADMIN_USER") or "admin"
local ADMIN_PASSWORD = os.getenv("MONGO_ADMIN_PASSWORD") or "admin"
local DB = "bench"
local NDOCS = 1000
local FILE_SIZE = 1048576
local COLLECTIONS = { "read", "write", "fs.files", "fs.chunks" }

local function die(what, err)
    io.stderr:write("seed: ", what, ": ", tostring(err), "\n")
    os.exit(1)
end

local conn = mongol:new()
conn:set_timeout(30000)
local ok, err = conn:connect(HOST, PORT)
if not ok then
    die("connect", err)
end
ok, err = conn:new_db_handle("admin"):auth(ADMIN_USER, ADMIN_PASSWORD)
if not ok then
    die("admin login", err)
end

local db = conn:new_db_handle(DB)

-- code 26 (NamespaceNotFound): the collection does not exist yet
for _, name in ipairs(COLLECTIONS) do
    local r, derr, reply = db:cmd({ drop = name })
    if not r and not (reply and reply.code == 26) then
        die("drop " .. name, derr)
    end
end

local body = string.rep("x", 200)
for _, name in ipairs({ "read", "write" }) do
    local docs = {}
    for i = 1, NDOCS do
        docs[i] = { _id = i, name = "user" .. i, age = i % 100,
                    tags = "a b c", body = body }
    end
    local r, ierr = db:get_col(name):insert(docs, nil, true)
    if not r then
        die("insert " .. name, ierr)
    end
    r, ierr = db:cmd(bson.ordered({
        { "createIndexes", name },
        { "indexes", { { key = { age = 1 }, name = "age_1" } } },
    }))
    if not r then
        die("index " .. name, ierr)
    end
end

-- one file of FILE_SIZE bytes; gridfs:insert reads it like a file handle
local data = string.rep("0123456789abcdef", FILE_SIZE / 16)
local pos = 1
local fh = {
    read = function(_, n)
        if pos > #data then
            return nil
        end
        local s = data:sub(pos, pos + n - 1)
        pos = pos + n
        return s
    end,
}
local r
r, err = db:get_gridfs("fs"):insert(fh, { filename = "f1m" }, true)
if not r then
    die("gridfs insert", err)
end

-- The user survives the drops above. Creating it again would fail with
-- code 51003, and recreating it would break the pooled sockets of nginx.
r, err = db:cmd({ usersInfo = "bench" })
if not r then
    die("usersInfo", err)
end
if #r.users == 0 then
    r, err = db:cmd(bson.ordered({
        { "createUser", "bench" },
        { "pwd", "bench" },
        { "roles", { { role = "readWrite", db = DB } } },
        { "mechanisms", { "SCRAM-SHA-1" } },
    }))
    if not r then
        die("createUser", err)
    end
end

conn:close()
