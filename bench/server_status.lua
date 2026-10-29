-- Prints serverStatus().connections.current. Exits non-zero when Mongo is
-- not reachable or the admin login fails, so it is also the "Mongo is up"
-- check. Run it with the new driver: resty -I <new>/lib bench/server_status.lua

local mongol = require "resty.mongol"

local HOST = os.getenv("MONGO_HOST") or "127.0.0.1"
local PORT = tonumber(os.getenv("MONGO_PORT")) or 27017
local ADMIN_USER = os.getenv("MONGO_ADMIN_USER") or "admin"
local ADMIN_PASSWORD = os.getenv("MONGO_ADMIN_PASSWORD") or "admin"

local function die(what, err)
    io.stderr:write("server_status: ", what, ": ", tostring(err), "\n")
    os.exit(1)
end

local conn = mongol:new()
conn:set_timeout(5000)
local ok, err = conn:connect(HOST, PORT)
if not ok then
    die("connect", err)
end
local db = conn:new_db_handle("admin")
ok, err = db:auth(ADMIN_USER, ADMIN_PASSWORD)
if not ok then
    die("admin login", err)
end
local r
r, err = db:cmd({ serverStatus = 1 })
if not r then
    die("serverStatus", err)
end
conn:close()
print(r.connections.current)
