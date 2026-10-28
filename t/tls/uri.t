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

=== TEST 1: connect_uri with tls
--- http_config eval
"$::HttpConfig" . qq{
    lua_ssl_trusted_certificate $ENV{TEST_NGINX_MONGO_CA};
}
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?tls=true"))
            ngx.say(conn:new_db_handle("admin"):cmd({ping = 1}).ok)
        }
    }
--- request
GET /t
--- response_body
1
--- no_error_log
[error]



=== TEST 2: connect_uri with tls and an untrusted server
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local c, err = mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?tls=true")
            ngx.say(c, " ", type(err))
        }
    }
--- request
GET /t
--- response_body
nil string
--- no_error_log
[error]
