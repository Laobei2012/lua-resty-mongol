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

=== TEST 1: start_session
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P))
            local db = conn:new_db_handle("test")
            local col = db:get_col("sess_t")
            col:delete({}, nil, true)
            
            local s = conn:start_session()
            ngx.say(type(s), " ", #s.lsid.id.v, " ", s.lsid.id.st == "\4")
            local s2 = conn:start_session()
            ngx.say(s.lsid.id.v ~= s2.lsid.id.v)
        }
    }
--- request
GET /t
--- response_body
table 16 true
true
--- no_error_log
[error]



=== TEST 2: a session outside a transaction
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P))
            local db = conn:new_db_handle("test")
            local col = db:get_col("sess_t")
            col:delete({}, nil, true)
            
            local s = conn:start_session()
            ngx.say(col:insert({{a = 1}, {a = 2}}, nil, true, {session = s}))
            ngx.say(col:update({a = 1}, {["$set"] = {b = 1}}, 0, 0, true, {session = s}))
            local n = 0
            for _ in col:find({}, nil, 2, {session = s}):pairs() do n = n + 1 end
            ngx.say(n, " ", col:find_one({a = 2}, nil, {session = s}).a)
            local c = 0
            for _ in col:aggregate({}, {session = s}):pairs() do c = c + 1 end
            ngx.say(c, " ", col:delete({a = 1}, 0, true, {session = s}))
        }
    }
--- request
GET /t
--- response_body
0
1
2 2
2 1
--- no_error_log
[error]



=== TEST 3: a session with an unsafe write
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P))
            local db = conn:new_db_handle("test")
            local col = db:get_col("sess_t")
            col:delete({}, nil, true)
            
            local s = conn:start_session()
            local real = wire.command
            local real_send = wire.send_only
            local sent = 0
            wire.command = function(...) sent = sent + 1 return real(...) end
            wire.send_only = function(...) sent = sent + 1 return real_send(...) end
            for _, safe in ipairs({"nil", "false", "zero"}) do
                local v = ({["nil"] = nil, ["false"] = false, zero = 0})[safe]
                ngx.say(col:insert({{a = 1}}, nil, v, {session = s}))
                ngx.say(col:update({}, {["$set"] = {a = 2}}, 0, 0, v, {session = s}))
                ngx.say(col:delete({}, 0, v, {session = s}))
            end
            wire.command = real
            wire.send_only = real_send
            ngx.say(sent, " ", col:count({}))
        }
    }
--- request
GET /t
--- response_body
nilunacknowledged write with a session
nilunacknowledged write with a session
nilunacknowledged write with a session
nilunacknowledged write with a session
nilunacknowledged write with a session
nilunacknowledged write with a session
nilunacknowledged write with a session
nilunacknowledged write with a session
nilunacknowledged write with a session
0 0
--- no_error_log
[error]



=== TEST 4: bad session arguments
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P))
            local db = conn:new_db_handle("test")
            local col = db:get_col("sess_t")
            col:delete({}, nil, true)
            
            for _, bad in ipairs({"x", 5, true, {}}) do
                local ok, err = pcall(col.insert, col, {{a = 1}}, nil, true, {session = bad})
                ngx.say(ok, " ", tostring(err):find("bad argument", 1, true) ~= nil)
            end
            local other = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P))
            local s = other:start_session()
            local ok, err = pcall(col.find_one, col, {}, nil, {session = s})
            ngx.say(ok, " ", tostring(err):find("bad argument", 1, true) ~= nil)
            ok, err = pcall(conn.start_session, conn, 5)
            ngx.say(ok, " ", conn.start_session ~= nil)
        }
    }
--- request
GET /t
--- response_body
false true
false true
false true
false true
false true
true true
--- no_error_log
[error]


=== TEST 6: non-table session options raise bad argument before I/O
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sess_opts")
            local sent = 0
            mongo.set_monitor({started = function() sent = sent + 1 end})
            local calls = {
                insert = function(o) return col:insert({{a = 1}}, nil, true, o) end,
                update = function(o) return col:update({}, {a = 1}, false, false, true, o) end,
                delete = function(o) return col:delete({}, false, true, o) end,
                query = function(o) return col:query({}, nil, 0, 1, o) end,
                find = function(o) return col:find({}, nil, 1, o) end,
                find_one = function(o) return col:find_one({}, nil, o) end,
                aggregate = function(o) return col:aggregate({}, o) end,
                getmore = function(o) return col:getmore(string.rep("\0", 8), 1, 0, o) end,
                kill_cursors = function(o) return col:kill_cursors({string.rep("\0", 8)}, o) end,
            }
            for _, name in ipairs({"insert", "update", "delete", "query", "find", "find_one", "aggregate", "getmore", "kill_cursors"}) do
                local valid = true
                for _, opts in ipairs({true, false, 1, "invalid", function() end}) do
                    local ok, err = pcall(calls[name], opts)
                    if ok or not tostring(err):find("bad argument", 1, true) then valid = false end
                end
                ngx.say(name, " ", valid)
            end
            mongo.set_monitor(nil)
            ngx.say("sent ", sent)
            conn:close()
        }
    }
--- request
GET /t
--- response_body
insert true
update true
delete true
query true
find true
find_one true
aggregate true
getmore true
kill_cursors true
sent 0
--- no_error_log
[error]



=== TEST 5: transaction state without a server
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P))
            local db = conn:new_db_handle("test")
            local col = db:get_col("sess_t")
            col:delete({}, nil, true)
            
            local s = conn:start_session()
            ngx.say(s:commit_transaction())
            ngx.say(s:abort_transaction())
            ngx.say(s:start_transaction())
            ngx.say(s:start_transaction())
            ngx.say(conn:set_keepalive())
            ngx.say(s:commit_transaction())
            ngx.say(s:abort_transaction())
            ngx.say(s:start_transaction(), " ", s:abort_transaction())
        }
    }
--- request
GET /t
--- response_body
nilno transaction in progress
nilno transaction in progress
true
niltransaction already in progress
niltransaction in progress
true
nilno transaction in progress
true true
--- no_error_log
[error]
