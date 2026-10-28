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

=== TEST 1: tls verified
--- http_config eval
"$::HttpConfig" . qq{
    lua_ssl_trusted_certificate $ENV{TEST_NGINX_MONGO_CA};
}
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local conn = mongo:new()
            conn:set_timeout(5000)
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT,
                                         {ssl = true, ssl_server_name = "localhost"})
            ngx.say(ok, " ", err)
            local db = conn:new_db_handle("admin")
            ngx.say(db:cmd({ping = 1}).ok)
        }
    }
--- request
GET /t
--- response_body
1 nil
1
--- no_error_log
[error]



=== TEST 2: tls untrusted
--- http_config eval
"$::HttpConfig" . qq{
    lua_ssl_trusted_certificate $ENV{TEST_NGINX_MONGO_OTHER_CA};
}
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local conn = mongo:new()
            conn:set_timeout(5000)
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT,
                                         {ssl = true, ssl_server_name = "localhost"})
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
certificate verify failed



=== TEST 3: tls without verification
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local conn = mongo:new()
            conn:set_timeout(5000)
            local ok = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT,
                                    {ssl = true, ssl_verify = false})
            ngx.say(ok)
            ngx.say(conn:new_db_handle("admin"):cmd({ping = 1}).ok)
        }
    }
--- request
GET /t
--- response_body
1
1
--- no_error_log
[error]



=== TEST 4: tls reconnect
--- http_config eval
"$::HttpConfig" . qq{
    lua_ssl_trusted_certificate $ENV{TEST_NGINX_MONGO_CA};
}
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local conn = mongo:new()
            conn:set_timeout(5000)
            assert(conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT,
                                {ssl = true, ssl_server_name = "localhost"}))
            conn:close()
            ngx.say(conn:connect())
            ngx.say(conn:new_db_handle("admin"):cmd({ping = 1}).ok)
        }
    }
--- request
GET /t
--- response_body
1
1
--- no_error_log
[error]
