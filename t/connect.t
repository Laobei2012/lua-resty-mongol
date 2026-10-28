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

=== TEST 1: pool option
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = mongo:new()
            conn:set_timeout(2000)
            assert(conn:connect(HOST, PORT, {pool = "a"}))
            ngx.say(conn:get_reused_times())
            ngx.say(conn:set_keepalive(10000, 5))
            assert(conn:connect(HOST, PORT, {pool = "other"}))
            ngx.say(conn:get_reused_times())
            assert(conn:connect(HOST, PORT, {pool = "a"}))
            ngx.say(conn:get_reused_times())
        }
    }
--- request
GET /t
--- response_body
0
1
0
1
--- no_error_log
[error]



=== TEST 2: pool_size and backlog
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = mongo:new()
            conn:set_timeout(2000)
            ngx.say(conn:connect(HOST, PORT, {pool = "b", pool_size = 1, backlog = 2}))
        }
    }
--- request
GET /t
--- response_body
1
--- no_error_log
[error]



=== TEST 3: reconnect keeps options
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = mongo:new()
            conn:set_timeout(2000)
            assert(conn:connect(HOST, PORT, {pool = "r"}))
            ngx.say(conn:set_keepalive(10000, 5))
            local other = mongo:new()
            other:set_timeout(2000)
            assert(other:connect(HOST, PORT))
            ngx.say(other:get_reused_times())
            assert(conn:connect())
            ngx.say(conn:get_reused_times())
            conn:close()
            ngx.say(conn:connect())
            ngx.say(conn.host == HOST, " ", conn.port == PORT)
        }
    }
--- request
GET /t
--- response_body
1
0
1
1
true true
--- no_error_log
[error]



=== TEST 4: tls to a plain server
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = mongo:new()
            conn:set_timeout(2000)
            local ok, err = conn:connect(HOST, PORT, {ssl = true})
            ngx.say(ok, " ", type(err))
            ngx.say(conn:set_keepalive())
        }
    }
--- request
GET /t
--- response_body
nil string
nilclosed
--- error_log
peer closed connection in SSL handshake



=== TEST 5: bad options
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local HOST, PORT = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = mongo:new()
            for _, bad in ipairs({"x", 5, true}) do
                local ok, err = pcall(conn.connect, conn, HOST, PORT, bad)
                ngx.say(ok, " ", tostring(err):find("bad argument", 1, true) ~= nil)
            end
        }
    }
--- request
GET /t
--- response_body
false true
false true
false true
--- no_error_log
[error]
