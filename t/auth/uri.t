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

=== TEST 1: connect_uri with a user
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local base = "mongodb://admin:admin@" .. H .. ":" .. P
            local conn = assert(mongo.connect_uri(base .. "/?authSource=admin"))
            ngx.say(#conn:databases() > 0)
            conn = assert(mongo.connect_uri(base .. "/admin"))
            ngx.say(#conn:databases() > 0)
            -- the user name and password are percent-decoded
            local db = conn:new_db_handle("admin")
            db:cmd({dropUser = "a@b"})
            assert(db:cmd(bson.ordered{{"createUser", "a@b"}, {"pwd", "p:w/d"}, {"roles", {{role = "readAnyDatabase", db = "admin"}}}}))
            local c2 = assert(mongo.connect_uri("mongodb://a%40b:p%3Aw%2Fd@" .. H .. ":" .. P .. "/?authSource=admin"))
            ngx.say(c2:new_db_handle("admin"):cmd({connectionStatus = 1}).authInfo.authenticatedUsers[1].user)
            db:cmd({dropUser = "a@b"})
        }
    }
--- request
GET /t
--- response_body
true
true
a@b
--- no_error_log
[error]



=== TEST 2: connect_uri with a wrong password or no authSource
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local c, err = mongo.connect_uri("mongodb://admin:wrong@" .. H .. ":" .. P .. "/?authSource=admin")
            ngx.say(c, " ", err:find("Authentication failed", 1, true) ~= nil)
            -- the user is in admin, but the default authSource is the database of the URI
            c, err = mongo.connect_uri("mongodb://admin:admin@" .. H .. ":" .. P .. "/test")
            ngx.say(c, " ", type(err))
        }
    }
--- request
GET /t
--- response_body
nil true
nil string
--- no_error_log
[error]



=== TEST 3: a reconnect logs in again
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
            local conn = assert(mongo.connect_uri("mongodb://admin:admin@" .. H .. ":" .. P .. "/?authSource=admin"))
            ngx.say(#conn:databases() > 0)
            conn:close()
            assert(conn:connect())
            ngx.say(#conn:databases() > 0)
            conn:close()
            assert(conn:connect())
            local info = conn:new_db_handle("admin"):cmd({connectionStatus = 1}).authInfo.authenticatedUsers
            ngx.say(info[1].user)
        }
    }
--- request
GET /t
--- response_body
true
true
admin
--- no_error_log
[error]
