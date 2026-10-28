# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (3 * blocks());

no_long_string();
no_shuffle();

run_tests();

__DATA__

=== TEST 1: connect_uri replset
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?replicaSet=rs0"))
            ngx.say((conn:ismaster()))
            -- a secondary as the only seed: the connection is still the primary
            local c2 = assert(mongo.connect_uri("mongodb://" .. SH .. ":" .. SP))
            ngx.say((c2:ismaster()), " ", c2.host == H or c2.host)
        }
    }
--- request
GET /t
--- response_body
true
true true
--- no_error_log
[error]



=== TEST 2: secondary read then write
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondaryPreferred"))
            ngx.say((conn.read_conn:ismaster()))
            local db = conn:new_db_handle("test")
            local col = db:get_col("rs_t")
            db:cmd({drop = "rs_t"})
            -- the fixture is on every member before the read
            assert(db:cmd(bson.ordered{{"insert", "rs_t"}, {"documents", {{_id = 1, v = "fixture"}}},
                                       {"writeConcern", {w = 3}}}))
            local doc, err = col:find_one({_id = 1})
            ngx.say(doc and doc.v, " ", err)
            ngx.say(col:insert({{a = 1}}, nil, true))
        }
    }
--- request
GET /t
--- response_body
false
fixture nil
0
--- no_error_log
[error]



=== TEST 3: getMore on the same server
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondary"))
            local db = conn:new_db_handle("test")
            local docs = {}
            for i = 1, 25 do docs[i] = {n = i} end
            db:get_col("rs_t2"):delete({}, nil, true)
            assert(db:cmd(bson.ordered{{"insert", "rs_t2"}, {"documents", docs}, {"writeConcern", {w = 3}}}))
            local col = db:get_col("rs_t2")
            local n = 0
            local cur = col:find({}, nil, 10)
            for _ in cur:pairs() do n = n + 1 end
            ngx.say(n, " ", (conn.read_conn:ismaster()))
            local seen = 0
            for _ in col:aggregate({{["$sort"] = {n = 1}}}, {batch_size = 4}):pairs() do seen = seen + 1 end
            ngx.say(seen, " ", col:count({}))
        }
    }
--- request
GET /t
--- response_body
25 false
25 25
--- no_error_log
[error]



=== TEST 4: reads use the read connection and carry the read preference
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local wire = require "resty.mongol.wire"
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondaryPreferred"))
            local db = conn:new_db_handle("test")
            local col = db:get_col("rs_t3")
            col:delete({}, nil, true)
            assert(db:cmd(bson.ordered{{"insert", "rs_t3"}, {"documents", {{a = 1}, {a = 2}, {a = 3}}}, {"writeConcern", {w = 3}}}))
            local real = wire.command
            local seen = {}
            wire.command = function(c, dbname, cmd, seq, extra)
                local name = cmd[1] and cmd[1][1] or next(cmd)
                -- wire.command adds $readPreference for a connection with read_preference
    local pref = c.read_preference or "-"
                seen[#seen + 1] = name .. ":" .. (c == conn.read_conn and "read" or "primary") .. ":" .. pref
                return real(c, dbname, cmd, seq, extra)
            end
            col:find_one({})
            col:count({})
            for _ in col:find({}, nil, 2):pairs() do end
            col:aggregate({}):next()
            col:insert({{a = 4}}, nil, true)
            col:update({a = 4}, {["$set"] = {b = 1}}, 0, 0, true)
            col:delete({a = 4}, 0, true)
            db:cmd({ping = 1})
            wire.command = real
            -- the first command of each kind
            local uniq, order = {}, {}
            for _, s in ipairs(seen) do
                if not uniq[s] then uniq[s] = true order[#order + 1] = s end
            end
            for _, s in ipairs(order) do ngx.say(s) end
        }
    }
--- request
GET /t
--- response_body
find:read:secondaryPreferred
count:read:secondaryPreferred
getMore:read:secondaryPreferred
aggregate:read:secondaryPreferred
insert:primary:-
update:primary:-
delete:primary:-
ping:primary:-
--- no_error_log
[error]



=== TEST 5: read preference modes
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            for _, mode in ipairs({"primary", "primaryPreferred", "secondary", "secondaryPreferred"}) do
                local c = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=" .. mode))
                local rc = c.read_conn
                ngx.say(mode, " ", rc and tostring(rc:ismaster()) or "none", " ", (c:ismaster()))
            end
        }
    }
--- request
GET /t
--- response_body
primary none true
primaryPreferred none true
secondary false true
secondaryPreferred false true
--- no_error_log
[error]



=== TEST 6: raw getmore and kill_cursors follow query
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondary"))
            local db = conn:new_db_handle("test")
            local col = db:get_col("rs_fix")
            db:cmd({drop = "rs_fix"})
            local docs = {}
            for i = 1, 25 do docs[i] = {n = i} end
            -- on every member before the test reads
            assert(db:cmd(bson.ordered{{"insert", "rs_fix"}, {"documents", docs}, {"writeConcern", {w = 3}}}))
            
            local id, r, flags = col:query({}, nil, 0, 10)
            ngx.say(#r, " ", flags.QueryFailure)
            local id2, r2, flags2 = col:getmore(id, 10, 10)
            ngx.say(#r2, " ", flags2.CursorNotFound)
            local id3 = col:query({}, nil, 0, 5)
            ngx.say(col:kill_cursors({id3}))
            local _, _, flags3 = col:getmore(id3, 5)
            ngx.say(flags3.CursorNotFound)
        }
    }
--- request
GET /t
--- response_body
10 false
10 false
true
true
--- no_error_log
[error]



=== TEST 7: reconnect keeps the read connection
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondary"))
            local db = conn:new_db_handle("test")
            local col = db:get_col("rs_fix")
            db:cmd({drop = "rs_fix"})
            local docs = {}
            for i = 1, 25 do docs[i] = {n = i} end
            -- on every member before the test reads
            assert(db:cmd(bson.ordered{{"insert", "rs_fix"}, {"documents", docs}, {"writeConcern", {w = 3}}}))
            
            local mode = conn.read_conn.read_preference
            local function read_ok()
                local n = 0
                for _ in col:find({}, nil, 10):pairs() do n = n + 1 end
                return n
            end
            ngx.say(read_ok(), " ", mode)
            conn:close()
            assert(conn:connect())
            ngx.say(read_ok(), " ", conn.read_conn.read_preference == mode, " ", (conn.read_conn:ismaster()))
            ngx.say(conn:set_keepalive(10000, 5))
            assert(conn:connect())
            ngx.say(read_ok(), " ", conn.read_conn.read_preference == mode)
            -- a connect to another address drops the read connection
            conn:close()
            assert(conn:connect(H, P))
            ngx.say(conn.read_conn)
        }
    }
--- request
GET /t
--- response_body
25 secondary
25 true false
1
25 true
nil
--- no_error_log
[error]



=== TEST 8: the read preference is on the wire
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondaryPreferred"))
            local db = conn:new_db_handle("test")
            local col = db:get_col("rs_wire")
            db:cmd({drop = "rs_wire"})
            local seen = {}
            mongo.set_monitor({started = function(ev)
                local rp = ev.command["$readPreference"]
                seen[#seen + 1] = ev.command_name .. " " .. ((ev.host == conn.read_conn.host and ev.port == conn.read_conn.port) and "read" or "primary") .. " " .. (rp and rp.mode or "-")
            end})
            col:insert({{a = 1}}, nil, true)
            col:find_one({})
            col:count({})
            db:cmd({ping = 1})
            mongo.set_monitor(nil)
            for _, l in ipairs(seen) do ngx.say(l) end
        }
    }
--- request
GET /t
--- response_body
insert primary -
find read secondaryPreferred
count read secondaryPreferred
ping primary -
--- no_error_log
[error]


=== TEST 9: explicit connect clears the secondary connection read preference
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondary"))
            local read = conn.read_conn
            ngx.say(read.read_preference)
            assert(read:close())
            assert(read:connect(H, P))
            ngx.say(read.read_preference == nil, " ", read.relogin == nil, " ", read.opts == nil)
            local seen = {}
            mongo.set_monitor({started = function(ev)
                seen[#seen + 1] = ev.command["$readPreference"] == nil
            end})
            assert(read:new_db_handle("admin"):cmd({ping = 1}))
            read:close()
            assert(read:connect())
            assert(read:new_db_handle("admin"):cmd({ping = 1}))
            mongo.set_monitor(nil)
            ngx.say(#seen, " ", seen[1], " ", seen[2])
            conn:close()
        }
    }
--- request
GET /t
--- response_body
secondary
true true true
2 true true
--- no_error_log
[error]
