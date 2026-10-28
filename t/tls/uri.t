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

=== TEST 1: connect_uri with tls does a verified handshake
--- http_config eval
"$::HttpConfig" . qq{
    lua_ssl_trusted_certificate $ENV{TEST_NGINX_MONGO_CA};
}
--- config
    location /t {
        content_by_lua_block {
            -- record the arguments of sslhandshake
            local seen
            local real_tcp = ngx.socket.tcp
            ngx.socket.tcp = function()
                local sock = real_tcp()
                return setmetatable({}, {__index = function(_, k)
                    if k == "sslhandshake" then
                        return function(_, reused, name, verify)
                            seen = {name = name, verify = verify}
                            return sock:sslhandshake(reused, name, verify)
                        end
                    end
                    local v = sock[k]
                    if type(v) == "function" then
                        return function(_, ...) return v(sock, ...) end
                    end
                    return v
                end})
            end
            local mongo = require "resty.mongol"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            -- ngx_lua checks the name of the certificate against a host
            -- name, not against an IP address, so with an IP address the
            -- handshake fails; the handshake itself is what this test shows
            local c, err = mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?tls=true")
            ngx.say(seen and seen.name == H, " ", seen and seen.verify)
            ngx.say(c, " ", type(err))
            -- without tls the socket does no handshake
            seen = nil
            local plain = mongo.connect_uri("mongodb://" .. H .. ":1/?tls=false")
            ngx.say(seen)
        }
    }
--- request
GET /t
--- response_body
true true
nil string
nil
--- error_log
certificate does not match host



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
--- error_log
certificate verify error
