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

=== TEST 1: commit visible
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local s = conn:start_session()
            assert(s:start_transaction())
            ngx.say(col:insert({{a = 1}}, nil, nil, {session = s}))
            -- count reads the metadata of the collection and can include an open
            -- transaction; a find outside the transaction shows what is committed
            ngx.say(col:find_one({}) == nil)
            ngx.say(s:commit_transaction())
            ngx.say(col:count({}))
        }
    }
--- request
GET /t
--- response_body
0
true
true
1
--- no_error_log
[error]



=== TEST 2: abort invisible
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local s = conn:start_session()
            assert(s:start_transaction())
            col:insert({{a = 1}}, nil, true, {session = s})
            ngx.say(s:abort_transaction())
            ngx.say(col:count({}))
            -- the session works after the abort
            assert(s:start_transaction())
            col:insert({{a = 2}}, nil, true, {session = s})
            ngx.say(s:commit_transaction(), " ", col:count({}))
        }
    }
--- request
GET /t
--- response_body
true
0
true 1
--- no_error_log
[error]



=== TEST 3: keepalive in a transaction
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local s = conn:start_session()
            assert(s:start_transaction())
            col:insert({{a = 1}}, nil, true, {session = s})
            ngx.say(conn:set_keepalive())
            s:abort_transaction()
            ngx.say(conn:set_keepalive(10000, 5))
        }
    }
--- request
GET /t
--- response_body
niltransaction in progress
1
--- no_error_log
[error]



=== TEST 4: two transactions
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local real = wire.command
            local numbers = {}
            wire.command = function(c, d, cmd, seq, extra, session)
                if session and session.txn_number and cmd[1] and cmd[1][1] == "insert" then
                    numbers[#numbers + 1] = session.txn_number
                end
                return real(c, d, cmd, seq, extra, session)
            end
            local s = conn:start_session()
            for i = 1, 2 do
                assert(s:start_transaction())
                col:insert({{a = i}}, nil, true, {session = s})
                assert(s:commit_transaction())
            end
            wire.command = real
            ngx.say(col:count({}), " ", numbers[2] > numbers[1])
        }
    }
--- request
GET /t
--- response_body
2 true
--- no_error_log
[error]



=== TEST 5: transaction ignores read_conn
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondaryPreferred"))
            local db = conn:new_db_handle("test")
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            local servers = {}
            mongo.set_monitor({started = function(ev)
                local key = ev.host .. ":" .. ev.port
                servers[key] = (servers[key] or 0) + 1
            end})
            local s = conn:start_session()
            assert(s:start_transaction())
            col:insert({{a = 1}}, nil, true, {session = s})
            local doc = col:find_one({a = 1}, nil, {session = s})
            ngx.say(doc and doc.a)
            local seen = 0
            for _ in col:find({}, nil, 2, {session = s}):pairs() do seen = seen + 1 end
            for _ in col:aggregate({}, {session = s}):pairs() do seen = seen + 1 end
            assert(s:commit_transaction())
            mongo.set_monitor(nil)
            local read_key = conn.read_conn.host .. ":" .. conn.read_conn.port
            local primary_key = conn.host .. ":" .. conn.port
            ngx.say(seen, " ", servers[read_key] == nil, " ", servers[primary_key] > 0)
        }
    }
--- request
GET /t
--- response_body
1
2 true true
--- no_error_log
[error]



=== TEST 6: mixed operations
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local s = conn:start_session()
            assert(s:start_transaction())
            col:insert({{a = 1}}, nil, true, {session = s})
            col:insert({{a = 2}}, nil, true)
            ngx.say(s:abort_transaction())
            ngx.say(col:count({}), " ", col:find_one({}).a)
        }
    }
--- request
GET /t
--- response_body
true
1 2
--- no_error_log
[error]



=== TEST 7: txn read across batches
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local s = conn:start_session()
            assert(s:start_transaction())
            local docs = {}
            for i = 1, 25 do docs[i] = {n = i} end
            ngx.say(col:insert(docs, nil, true, {session = s}))
            local n = 0
            for _ in col:find({}, nil, 10, {session = s}):pairs() do n = n + 1 end
            -- outside the transaction nothing is committed yet (count would include it)
            ngx.say(n, " ", col:find_one({}) == nil)
            assert(s:commit_transaction())
            ngx.say(col:count({}))
        }
    }
--- request
GET /t
--- response_body
0
25 true
25
--- no_error_log
[error]



=== TEST 8: write concern in a transaction
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local real = wire.command
            local cmds = {}
            wire.command = function(c, d, cmd, seq, extra, session)
                local copy = {}
                for _, kv in ipairs(cmd) do copy[kv[1]] = kv[2] end
                cmds[#cmds + 1] = {name = cmd[1][1], wc = copy.writeConcern, db = d}
                return real(c, d, cmd, seq, extra, session)
            end
            local s = conn:start_session()
            assert(s:start_transaction())
            col:insert({{a = 1}}, nil, true, {session = s})
            col:update({a = 1}, {["$set"] = {b = 1}}, 0, 0, true, {session = s})
            col:delete({a = 1}, 0, true, {session = s})
            s:commit_transaction()
            wire.command = real
            for _, c in ipairs(cmds) do ngx.say(c.name, " ", c.db, " ", c.wc and "wc" or "-") end
        }
    }
--- request
GET /t
--- response_body
insert test -
update test -
delete test -
commitTransaction admin -
--- no_error_log
[error]



=== TEST 9: any write in a transaction is acknowledged
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local s = conn:start_session()
            assert(s:start_transaction())
            ngx.say(col:insert({{a = 1}}, nil, nil, {session = s}))
            ngx.say(col:update({a = 1}, {["$set"] = {b = 1}}, 0, 0, false, {session = s}))
            ngx.say(col:delete({a = 1}, 0, 0, {session = s}))
            s:abort_transaction()
        }
    }
--- request
GET /t
--- response_body
0
1
1
--- no_error_log
[error]



=== TEST 10: commit write concern error
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local s = conn:start_session()
            assert(s:start_transaction())
            col:insert({{a = 1}}, nil, true, {session = s})
            local real = wire.command
            local function commit_with(reply)
                -- like wire.command: a reply with ok 0 is nil, errmsg, reply
    wire.command = function()
        if reply.ok ~= 1 then return nil, reply.errmsg, reply end
        return reply
    end
                local r, err, doc = s:commit_transaction()
                wire.command = real
                return r, err, doc
            end
            local function has(doc, label)
                for _, l in ipairs(doc.errorLabels or {}) do if l == label then return true end end
                return false
            end
            local L = "UnknownTransactionCommitResult"
            
            local r, err, doc = commit_with({ok = 1, writeConcernError = {code = 64, errmsg = "waiting for replication timed out"},
                                             errorLabels = {L}})
            ngx.say(r, " ", err, " ", has(doc, L), " ", #doc.errorLabels)
            -- the real transaction is still open on the server, and it holds
            -- the lock of the collection until it ends
            s:abort_transaction()
        }
    }
--- request
GET /t
--- response_body
nil waiting for replication timed out true 1
--- no_error_log
[error]



=== TEST 11: commit labels
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local s = conn:start_session()
            assert(s:start_transaction())
            col:insert({{a = 1}}, nil, true, {session = s})
            local real = wire.command
            local function commit_with(reply)
                -- like wire.command: a reply with ok 0 is nil, errmsg, reply
                wire.command = function()
                    if reply.ok ~= 1 then return nil, reply.errmsg, reply end
                    return reply
                end
                local r, err, doc = s:commit_transaction()
                wire.command = real
                return r, err, doc
            end
            local function has(doc, label)
                for _, l in ipairs(doc.errorLabels or {}) do if l == label then return true end end
                return false
            end
            local L = "UnknownTransactionCommitResult"
            
            local cases = {
                {"wce 64", {ok = 1, writeConcernError = {code = 64, errmsg = "x"}}},
                {"wce 11602", {ok = 1, writeConcernError = {code = 11602, errmsg = "x"}}},
                {"retryable", {ok = 0, code = 91, errmsg = "shutting down", errorLabels = {"RetryableWriteError"}}},
                {"code 50", {ok = 0, code = 50, errmsg = "time limit"}},
                {"wce 100", {ok = 1, writeConcernError = {code = 100, errmsg = "x"}}},
                {"wce 79", {ok = 1, writeConcernError = {code = 79, errmsg = "x"}}},
                {"plain error", {ok = 0, code = 251, errmsg = "no such transaction", errorLabels = {"TransientTransactionError"}}},
            }
            for _, c in ipairs(cases) do
                local r, err, doc = commit_with(c[2])
                ngx.say(c[1], " ", r, " ", has(doc, L), " ", has(doc, "RetryableWriteError"), " ", has(doc, "TransientTransactionError"))
            end
            s:abort_transaction()
        }
    }
--- request
GET /t
--- response_body
wce 64 nil true false false
wce 11602 nil true false false
retryable nil true true false
code 50 nil true false false
wce 100 nil false false false
wce 79 nil false false false
plain error nil false false true
--- no_error_log
[error]



=== TEST 12: lost commit reply
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local s = conn:start_session()
            assert(s:start_transaction())
            col:insert({{a = 1}}, nil, true, {session = s})
            local real = wire.command
            local sent = {}
            local first = true
            wire.command = function(c, d, cmd, seq, extra, session)
                if cmd[1][1] == "commitTransaction" then
                    local copy = {}
                    for _, kv in ipairs(cmd) do copy[kv[1]] = kv[2] end
                    sent[#sent + 1] = {txn = tostring(session.txn_number), wc = copy.writeConcern}
                    if first then
                        first = false
                        -- the server commits, but the reply is lost
                        real(c, d, cmd, seq, extra, session)
                        c.sock:close()
                        c.broken = true
                        return nil, "closed"
                    end
                end
                return real(c, d, cmd, seq, extra, session)
            end
            local r, err, doc = s:commit_transaction()
            local labelled = false
            for _, l in ipairs(doc.errorLabels or {}) do if l == "UnknownTransactionCommitResult" then labelled = true end end
            ngx.say(r, " ", err, " ", labelled, " ", doc.ok)
            ngx.say(conn:set_keepalive())
            assert(conn:connect())
            ngx.say(s:commit_transaction())
            wire.command = real
            ngx.say(col:count({}))
            ngx.say(sent[1].txn == sent[2].txn, " ", sent[1].wc, " ", sent[2].wc.w, " ", sent[2].wc.wtimeout)
        }
    }
--- request
GET /t
--- response_body
nil closed true 0
nilclosed
true
1
true nil majority 10000
--- no_error_log
[error]



=== TEST 13: abort after a socket error leaves a usable session
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
            local col = db:get_col("txn_t")
            db:cmd({drop = "txn_t"})
            db:cmd(bson.ordered{{"create", "txn_t"}})
            
            local s = conn:start_session()
            assert(s:start_transaction())
            col:insert({{a = 1}}, nil, true, {session = s})
            conn.sock:close()
            conn.broken = true
            local r, err = col:insert({{a = 2}}, nil, true, {session = s})
            ngx.say(r, " ", err)
            assert(conn:connect())
            local ok, aerr = s:abort_transaction()
            ngx.say(ok, " ", aerr ~= nil)
            assert(s:start_transaction())
            col:insert({{a = 3}}, nil, true, {session = s})
            ngx.say(s:commit_transaction(), " ", col:count({}), " ", col:find_one({}).a)
        }
    }
--- request
GET /t
--- response_body
nil closed
true false
true 1 3
--- no_error_log
[error]
