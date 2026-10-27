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

=== TEST 1: sha256 login
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn, db = t.connect(HOST, PORT, "admin")
            ngx.say(db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS"))
            local col = conn:new_db_handle("test"):get_col("auth_t")
            ngx.say(col:insert({{a = 1}}, nil, true))
        }
    }
--- request
GET /t
--- response_body
1
0
--- no_error_log
[error]



=== TEST 2: sha1 login
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn, db = t.connect(HOST, PORT, "admin")
            db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            db:cmd({dropUser = "u1"})
            local r, err = db:cmd(bson.ordered{
                {"createUser", "u1"}, {"pwd", "p1"}, {"roles", bson.empty_array},
                {"mechanisms", {"SCRAM-SHA-1"}},
            })
            ngx.say(r and r.ok, " ", err)
            local conn2, db2 = t.connect(HOST, PORT, "admin")
            ngx.say(db2:auth("u1", "p1"))
            ngx.say(db2:cmd({connectionStatus = 1}).authInfo.authenticatedUsers[1].user)
            db:cmd({dropUser = "u1"})
        }
    }
--- request
GET /t
--- response_body
1 nil
1
u1
--- no_error_log
[error]



=== TEST 3: wrong password
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn, db = t.connect(HOST, PORT, "admin")
            local r, err = db:auth("$TEST_NGINX_MONGO_USER", "nope")
            ngx.say(r, " ", err:find("Authentication failed", 1, true) ~= nil)
        }
    }
--- request
GET /t
--- response_body
nil true
--- no_error_log
[error]



=== TEST 4: wrong password after cached login
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn, db = t.connect(HOST, PORT, "admin")
            ngx.say(db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS"))
            local conn2, db2 = t.connect(HOST, PORT, "admin")
            local r, err = db2:auth("$TEST_NGINX_MONGO_USER", "wrong")
            ngx.say(r, " ", err:find("Authentication failed", 1, true) ~= nil)
        }
    }
--- request
GET /t
--- response_body
1
nil true
--- no_error_log
[error]



=== TEST 5: bad server nonce
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local scram = require "resty.mongol.scram"
            local real = wire.command
            local seen = {}
            local function payload_of(cmd)
                for _, kv in ipairs(cmd) do
                    if kv[1] == "payload" then return kv[2].v end
                end
            end
            local function name_of(cmd) return cmd[1][1] end
            local function bin(s) return bson.get_bin_data(s) end
            
            for _, mech in ipairs({"SCRAM-SHA-1", "SCRAM-SHA-256"}) do
                seen = {}
                wire.command = function(conn, dbname, cmd)
                    seen[#seen + 1] = name_of(cmd)
                    if name_of(cmd) == "saslStart" then
                        return {ok = 1, conversationId = 1, done = false,
                                payload = bin("r=NOTTHECLIENTNONCE,s=" .. ngx.encode_base64("saltsaltsalt") .. ",i=4096")}
                    end
                    return {ok = 1, done = true, payload = bin("v=x")}
                end
                local r, err = scram.authenticate({}, "admin", "u", "p", mech)
                wire.command = real
                ngx.say(mech, " ", r, " ", err, " ", table.concat(seen, ","))
            end
        }
    }
--- request
GET /t
--- response_body
SCRAM-SHA-1 nil server nonce mismatch saslStart
SCRAM-SHA-256 nil server nonce mismatch saslStart
--- no_error_log
[error]



=== TEST 6: bad server signature
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local scram = require "resty.mongol.scram"
            local real = wire.command
            local seen = {}
            local function payload_of(cmd)
                for _, kv in ipairs(cmd) do
                    if kv[1] == "payload" then return kv[2].v end
                end
            end
            local function name_of(cmd) return cmd[1][1] end
            local function bin(s) return bson.get_bin_data(s) end
            
            for _, mech in ipairs({"SCRAM-SHA-1", "SCRAM-SHA-256"}) do
                wire.command = function(conn, dbname, cmd)
                    if name_of(cmd) == "saslStart" then
                        local nonce = payload_of(cmd):match("r=([^,]+)")
                        return {ok = 1, conversationId = 1, done = false,
                                payload = bin("r=" .. nonce .. "SERVER,s=" .. ngx.encode_base64("saltsaltsalt") .. ",i=4096")}
                    end
                    return {ok = 1, done = true, payload = bin("v=" .. ngx.encode_base64("wrong signature"))}
                end
                local r, err = scram.authenticate({}, "admin", "u", "p", mech)
                wire.command = real
                ngx.say(mech, " ", r, " ", err)
            end
        }
    }
--- request
GET /t
--- response_body
SCRAM-SHA-1 nil server signature mismatch
SCRAM-SHA-256 nil server signature mismatch
--- no_error_log
[error]



=== TEST 7: rfc vectors
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local scram = require "resty.mongol.scram"
            -- RFC 7677 section 3, SCRAM-SHA-256
            local fb = "n=user,r=rOprNGfwEbeRWgbNEkqO"
            local sf = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
            local cf = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
            for _, pure in ipairs({false, true}) do
                scram.force_pure = pure
                local proof, sig = scram._proof("SCRAM-SHA-256", "pencil", "W22ZaJ0SNY7soEsUEjb6gQ==", 4096,
                                                fb .. "," .. sf .. "," .. cf)
                ngx.say(pure, " ", proof, " ", sig)
            end
            -- RFC 5802 section 5, SCRAM-SHA-1
            fb = "n=user,r=fyko+d2lbbFgONRv9qkxdawL"
            sf = "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096"
            cf = "c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j"
            for _, pure in ipairs({false, true}) do
                scram.force_pure = pure
                local proof, sig = scram._proof("SCRAM-SHA-1", "pencil", "QSXCR+Q6sek8bf92", 4096,
                                                fb .. "," .. sf .. "," .. cf)
                ngx.say(pure, " ", proof, " ", sig)
            end
        }
    }
--- request
GET /t
--- response_body
false dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ= 6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=
true dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ= 6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=
false v0X8v3Bz2T0CJGbJQyF0X+HI4Ts= rmF9pqV8S7suAoZWja4dJRkFsKQ=
true v0X8v3Bz2T0CJGbJQyF0X+HI4Ts= rmF9pqV8S7suAoZWja4dJRkFsKQ=
--- no_error_log
[error]



=== TEST 8: non-ascii password
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local scram = require "resty.mongol.scram"
            local r, err = scram.authenticate({}, "admin", "u", "p\xc3\xa9", "SCRAM-SHA-256")
            ngx.say(r, " ", err)
        }
    }
--- request
GET /t
--- response_body
nil non-ASCII password not supported
--- no_error_log
[error]



=== TEST 9: pooled login reuse
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local mongo = require "resty.mongol"
            local conn, db = t.connect(HOST, PORT, "admin")
            ngx.say(db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS"))
            ngx.say(conn:set_keepalive(10000, 10))
            local conn2 = mongo:new()
            conn2:set_timeout(10000)
            conn2:connect(HOST, PORT)
            ngx.say(conn2:get_reused_times() > 0)
            local doc = conn2:new_db_handle("test"):get_col("auth_t"):find_one({})
            ngx.say(doc ~= nil)
        }
    }
--- request
GET /t
--- response_body
1
1
true
true
--- no_error_log
[error]
