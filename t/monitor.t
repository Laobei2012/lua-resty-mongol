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

=== TEST 1: started and succeeded
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            mongo.set_monitor(all)
            col:find_one({})
            mongo.set_monitor(nil)
            local s, d = events[1][2], events[2][2]
            ngx.say(#events, " ", events[1][1], " ", s.command_name, " ", events[2][1], " ", d.command_name)
            ngx.say(s.request_id == d.request_id, " ", type(d.duration_ms), " ", d.duration_ms >= 0, " ", s.db, " ", s.host == H, " ", s.port == P)
            ngx.say(type(s.command), " ", s.command.find, " ", type(d.reply), " ", d.reply.ok)
        }
    }
--- request
GET /t
--- response_body
2 started find succeeded find
true number true test true true
table monitor_t table 1
--- no_error_log
[error]



=== TEST 2: failed
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            mongo.set_monitor(all)
            db:cmd({nosuchcmd = 1})
            mongo.set_monitor(nil)
            ngx.say(#events, " ", events[1][1], " ", events[2][1], " ", events[2][2].command_name)
            ngx.say(events[2][2].error:find("no such command", 1, true) ~= nil, " ", type(events[2][2].duration_ms), " ", events[2][2].reply)
        }
    }
--- request
GET /t
--- response_body
2 started failed nosuchcmd
true number nil
--- no_error_log
[error]



=== TEST 3: hook error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            col:insert({{a = 1}}, nil, true)
            mongo.set_monitor({started = function() error("boom hook") end, succeeded = rec("succeeded")})
            local doc = col:find_one({a = 1})
            mongo.set_monitor(nil)
            ngx.say(doc.a, " ", #events)
        }
    }
--- request
GET /t
--- response_body
1 1
--- error_log
boom hook



=== TEST 4: redaction
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            db:cmd({dropUser = "u3"})
            mongo.set_monitor(all)
            local r = db:cmd(bson.ordered{{"createUser", "u3"}, {"pwd", "secret"}, {"roles", bson.empty_array}})
            mongo.set_monitor(nil)
            db:cmd({dropUser = "u3"})
            ngx.say(r ~= nil, " ", #events, " ", events[1][1], " ", events[1][2].command_name, " ", next(events[1][2].command) == nil)
            ngx.say(events[2][1], " ", next(events[2][2].reply) == nil)
            ngx.say(text():find("secret", 1, true) == nil)
        }
    }
--- request
GET /t
--- response_body
true 2 started createUser true
succeeded true
true
--- no_error_log
[error]



=== TEST 5: failed sensitive command
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            db:cmd({dropUser = "u3"})
            mongo.set_monitor(all)
            local mk = function() return bson.ordered{{"createUser", "u3"}, {"pwd", "secret"}, {"roles", bson.empty_array}} end
            db:cmd(mk())
            local r, err = db:cmd(mk())
            mongo.set_monitor(nil)
            db:cmd({dropUser = "u3"})
            ngx.say(r, " ", type(err), " ", #events, " ", events[4][1], " ", events[4][2].error)
            local txt = text()
            ngx.say(txt:find("secret", 1, true) == nil, " ", txt:find("u3", 1, true) == nil)
        }
    }
--- request
GET /t
--- response_body
nil string 4 failed redacted
true true
--- no_error_log
[error]



=== TEST 6: speculative hello
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            mongo.set_monitor(all)
            for _, name in ipairs({"hello", "isMaster", "ismaster"}) do
                db:cmd(bson.ordered{{name, 1}, {"speculativeAuthenticate", {saslStart = 1, secretfield = "secret"}}})
            end
            mongo.set_monitor(nil)
            local ok = true
            for _, e in ipairs(events) do
                if e[1] == "started" and next(e[2].command) ~= nil then ok = false end
                if e[1] == "succeeded" and next(e[2].reply) ~= nil then ok = false end
                if e[1] == "failed" and e[2].error ~= "redacted" then ok = false end
            end
            ngx.say(#events, " ", ok, " ", text():find("secret", 1, true) == nil)
        }
    }
--- request
GET /t
--- response_body
6 true true
--- no_error_log
[error]



=== TEST 7: insert event
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            mongo.set_monitor(all)
            col:insert({{a = 1}, {a = 2}}, nil, true)
            mongo.set_monitor(nil)
            local c = events[1][2].command
            ngx.say(events[1][2].command_name, " ", c.insert, " ", #c.documents, " ", c.documents[2].a, " ", events[2][2].reply.n)
        }
    }
--- request
GET /t
--- response_body
insert monitor_t 2 2 2
--- no_error_log
[error]



=== TEST 8: hook mutation
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            col:insert({{a = 1}}, nil, true)
            local query = {a = 1}
            mongo.set_monitor({
                started = function(ev) ev.command.filter.a = 99 error("mutating hook") end,
                succeeded = function(ev) for k in pairs(ev.reply) do ev.reply[k] = nil end end,
            })
            local doc = col:find_one(query)
            mongo.set_monitor(nil)
            ngx.say(doc and doc.a, " ", query.a)
        }
    }
--- request
GET /t
--- response_body
1 1
--- error_log
mutating hook



=== TEST 9: monitor removed in flight
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            mongo.set_monitor({
                started = function(ev) events[#events + 1] = {"started", ev} mongo.set_monitor(nil) end,
                succeeded = rec("succeeded"),
            })
            col:find_one({})
            col:find_one({})
            ngx.say(#events, " ", events[1][1], " ", events[2][1])
        }
    }
--- request
GET /t
--- response_body
2 started succeeded
--- no_error_log
[error]



=== TEST 10: failure on a closed socket
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn2, db2 = t.connect("127.0.0.1", 12345, "test")
            mongo.set_monitor(all)
            local r, err = db2:cmd({ping = 1})
            mongo.set_monitor(nil)
            ngx.say(r, " ", #events, " ", events[1][1], " ", events[2][1], " ", type(events[2][2].error))
        }
    }
--- tcp_listen: 12345
--- tcp_reply:
--- request
GET /t
--- response_body
nil 2 started failed string
--- no_error_log
[error]



=== TEST 11: remove monitor
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            mongo.set_monitor(all)
            mongo.set_monitor(nil)
            col:find_one({})
            ngx.say(#events)
        }
    }
--- request
GET /t
--- response_body
0
--- no_error_log
[error]



=== TEST 12: bad arguments
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            for _, bad in ipairs({"x", 5, true}) do
                local ok, err = pcall(mongo.set_monitor, bad)
                ngx.say(ok, " ", tostring(err):find("bad argument", 1, true) ~= nil)
            end
            local ok, err = pcall(mongo.set_monitor, {started = "x"})
            ngx.say(ok, " ", tostring(err):find("bad argument", 1, true) ~= nil)
            ngx.say(mongo.set_monitor({}), " ", mongo.set_monitor(nil))
        }
    }
--- request
GET /t
--- response_body
false true
false true
false true
false true
true true
--- no_error_log
[error]



=== TEST 13: unsafe write
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            mongo.set_monitor(all)
            local r = col:insert({{a = 1}})
            mongo.set_monitor(nil)
            ngx.say(r, " ", #events, " ", events[1][1], " ", events[1][2].command.writeConcern.w, " ", events[2][1], " ", events[2][2].reply.ok)
        }
    }
--- request
GET /t
--- response_body
-1 2 started 0 succeeded 1
--- no_error_log
[error]



=== TEST 14: write errors are a succeeded command
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            mongo.set_monitor(all)
            col:insert({{_id = 1}}, nil, true)
            local r, err = col:insert({{_id = 1}}, nil, true)
            mongo.set_monitor(nil)
            ngx.say(r, " ", #events, " ", events[4][1], " ", events[4][2].reply.writeErrors ~= nil)
        }
    }
--- request
GET /t
--- response_body
nil 4 succeeded true
--- no_error_log
[error]


=== TEST 15: redaction follows the iterator of the encoder
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            db:cmd({dropUser = "u4"})
            local state = {
    order = {"createUser", "pwd", "roles"}, pos = {createUser = 1, pwd = 2, roles = 3},
    vals = {createUser = "u4", pwd = "secret", roles = bson.empty_array},
}
-- an iterator that works on its own state, not on the table
local cmd = setmetatable({}, {__pairs = function(t)
    return function(s, k)
        local name = s.order[k == nil and 1 or s.pos[k] + 1]
        if name then return name, s.vals[name] end
    end, state, nil
end})
mongo.set_monitor(all)
            local r = db:cmd(cmd)
            mongo.set_monitor(nil)
            db:cmd({dropUser = "u4"})
            ngx.say(r ~= nil, " ", #events, " ", events[1][2].command_name, " ", next(events[1][2].command) == nil, " ", next(events[2][2].reply) == nil)
            ngx.say(text():find("secret", 1, true) == nil)
        }
    }
--- request
GET /t
--- response_body
true 2 createUser true true
true
--- no_error_log
[error]


=== TEST 16: a protected metatable does not change the command
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            local comment = setmetatable({a = 1}, {__metatable = "locked"})
            local r = db:cmd(bson.ordered{{"ping", 1}, {"comment", comment}})
            ngx.say(r and r.ok)
            mongo.set_monitor(all)
            r = db:cmd(bson.ordered{{"ping", 1}, {"comment", comment}})
            mongo.set_monitor(nil)
            ngx.say(r and r.ok, " ", #events, " ", events[1][2].command_name, " ", events[1][2].command.comment.a)
        }
    }
--- request
GET /t
--- response_body
1
1 2 ping 1
--- no_error_log
[error]


=== TEST 17: null and empty arrays stay what they are in events
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            col:insert({{n = bson.null, list = bson.empty_array}}, nil, true)
            mongo.set_monitor(all)
            local doc = col:find_one({n = bson.null})
            local cur = col:aggregate({})
            mongo.set_monitor(nil)
            local find_cmd = events[1][2].command
            ngx.say(find_cmd.filter.n == bson.null, " ", doc ~= nil)
            local reply_doc = events[2][2].reply.cursor.firstBatch[1]
            ngx.say(reply_doc.n == bson.null, " ", getmetatable(reply_doc.list) == bson.array_mt)
            local agg
            for _, e in ipairs(events) do
                if e[1] == "started" and e[2].command_name == "aggregate" then agg = e[2] end
            end
            local json = cjson.encode(bson.to_json_safe(agg.command))
            ngx.say(json:find('"pipeline":[]', 1, true) ~= nil)
            ngx.say(cjson.encode(bson.to_json_safe(reply_doc)):find('"n":null', 1, true) ~= nil)
        }
    }
--- request
GET /t
--- response_body
true true
true true
true
true
--- no_error_log
[error]



=== TEST 18: a handler that is not set costs nothing
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local cjson = require "cjson"
            local t = require "mongol_t"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local events = {}
            local function rec(kind)
                return function(ev) events[#events + 1] = {kind, ev} end
            end
            local all = {started = rec("started"), succeeded = rec("succeeded"), failed = rec("failed")}
            local function text() return cjson.encode(bson.to_json_safe(events)) end
            local conn, db = t.connect(H, P, "test")
            local col = db:get_col("monitor_t")
            col:delete({}, nil, true)
            local real_decode = bson.decode
            local calls = 0
            bson.decode = function(...) calls = calls + 1 return real_decode(...) end
            local docs = {}
            for i = 1, 50 do docs[i] = {n = i} end
            local function run(handlers)
                calls = 0
                mongo.set_monitor(handlers)
                col:insert(docs, nil, true)
                mongo.set_monitor(nil)
                return calls
            end
            local only_succeeded = run({succeeded = function() end})
            local only_failed = run({failed = function() end})
            local with_started = run({started = function(ev) events[#events + 1] = ev end})
            bson.decode = real_decode
            ngx.say(only_succeeded, " ", only_failed, " ", with_started >= 51, " ", #events[1].command.documents)
            -- the duration still works with only a succeeded handler
            local got
            mongo.set_monitor({succeeded = function(ev) got = ev end})
            col:find_one({})
            mongo.set_monitor(nil)
            ngx.say(type(got.duration_ms), " ", got.request_id ~= nil, " ", got.command_name)
        }
    }
--- request
GET /t
--- response_body
0 0 true 50
number true find
--- no_error_log
[error]
