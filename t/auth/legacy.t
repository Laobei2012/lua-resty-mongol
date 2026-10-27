# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (3 * blocks());

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__

=== TEST 2: db auth failed
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 

            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("admin")
            local r,err = db:auth("admin", "pass")
            if not r then ngx.say(err) 
            else
                ngx.say(r)
            end
        ';
    }
--- request
GET /t
--- response_body
Authentication failed.
--- no_error_log
[error]

=== TEST 8: db auth
--- http_config eval: $::HttpConfig
--- config
    lua_code_cache off;
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 

            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("admin")
            local r,err = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            ngx.say(r)
        ';
    }
--- request
GET /t
--- response_body
1
--- no_error_log
[error]


