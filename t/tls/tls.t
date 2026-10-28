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
            local ok = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT,
                                    {ssl = true, ssl_server_name = "localhost"})
            ngx.say(ok)
            local db = conn:new_db_handle("admin")
            ngx.say(db:cmd({ping = 1}).ok)
        }
    }
--- request
GET /t
--- response_body
1
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
            ngx.say(ok, " ", err:find("certificate", 1, true) ~= nil)
            ngx.say(conn:set_keepalive())
        }
    }
--- request
GET /t
--- response_body
nil true
nilclosed
--- no_error_log
[crit]



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
            local ok = conn:connect()
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



=== TEST 5: tls socket is not reused by a plain connect
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = mongo:new()
            conn:set_timeout(5000)
            assert(conn:connect(H, P, {ssl = true, ssl_verify = false}))
            ngx.say(conn:new_db_handle("admin"):cmd({ping = 1}).ok)
            ngx.say(conn:set_keepalive(10000, 5))
            local plain = mongo:new()
            plain:set_timeout(5000)
            assert(plain:connect(H, P))
            ngx.say(plain:get_reused_times())
            local r, err = plain:new_db_handle("admin"):cmd({ping = 1})
            ngx.say(r, " ", type(err))
        }
    }
--- request
GET /t
--- response_body
1
1
0
nil string
--- no_error_log
[crit]



=== TEST 6: unverified tls socket is not reused by a verified connect
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = mongo:new()
            conn:set_timeout(5000)
            assert(conn:connect(H, P, {ssl = true, ssl_verify = false}))
            ngx.say(conn:set_keepalive(10000, 5))
            -- no lua_ssl_trusted_certificate: a fresh socket must fail
            local c2 = mongo:new()
            c2:set_timeout(5000)
            local ok, err = c2:connect(H, P, {ssl = true, ssl_verify = true, ssl_server_name = "localhost"})
            ngx.say(ok, " ", err ~= nil)
        }
    }
--- request
GET /t
--- response_body
1
nil true
--- no_error_log
[crit]



=== TEST 7: tls socket is reused with the same settings
--- http_config eval
"$::HttpConfig" . qq{
    lua_ssl_trusted_certificate $ENV{TEST_NGINX_MONGO_CA};
}
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local opts = {ssl = true, ssl_server_name = "localhost"}
            local conn = mongo:new()
            conn:set_timeout(5000)
            assert(conn:connect(H, P, opts))
            ngx.say(conn:set_keepalive(10000, 5))
            local c2 = mongo:new()
            c2:set_timeout(5000)
            assert(c2:connect(H, P, opts))
            ngx.say(c2:get_reused_times())
            ngx.say(c2:new_db_handle("admin"):cmd({ping = 1}).ok)
        }
    }
--- request
GET /t
--- response_body
1
1
1
--- no_error_log
[crit]



=== TEST 8: getprimary keeps the tls options of the seed
--- http_config eval
"$::HttpConfig" . qq{
    lua_ssl_trusted_certificate $ENV{TEST_NGINX_MONGO_CA};
}
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local seed = mongo:new()
            seed:set_timeout(5000)
            assert(seed:connect(H, P, {ssl = true, ssl_server_name = "localhost", pool = "seedpool"}))
            -- the first hello (the seed) says: not primary, ask H:P
            local real = wire.command
            local calls = 0
            wire.command = function(...)
                calls = calls + 1
                if calls == 1 then
                    return {ok = 1, isWritablePrimary = false, hosts = {H .. ":" .. P}}
                end
                return real(...)
            end
            local found, err = seed:getprimary({})
            wire.command = real
            ngx.say(found ~= nil, " ", err)
            if found then
                ngx.say(found ~= seed, " ", found.opts.ssl, " ", found.opts.ssl_server_name, " ", found.opts.pool)
                ngx.say(found:new_db_handle("admin"):cmd({ping = 1}).ok)
            end
        }
    }
--- request
GET /t
--- response_body
true nil
true true localhost nil
1
--- no_error_log
[crit]



=== TEST 9: a caller pool name cannot collide with a generated one
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local conn = mongo:new()
            conn:set_timeout(5000)
            assert(conn:connect(H, P, {ssl = true, ssl_verify = false}))
            ngx.say(conn:set_keepalive(10000, 5))
            -- the pool name that the first version generated for this socket
            local plain = mongo:new()
            plain:set_timeout(5000)
            assert(plain:connect(H, P, {pool = H .. ":" .. P .. ":tls:noverify:" .. H}))
            ngx.say(plain:get_reused_times())
            local r, err = plain:new_db_handle("admin"):cmd({ping = 1})
            ngx.say(r, " ", type(err))
        }
    }
--- request
GET /t
--- response_body
1
0
nil string
--- no_error_log
[crit]



=== TEST 10: plain, tls and caller pool names are always apart
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            -- record the pool name that the driver gives to each connect
            local seen = {}
            local real_tcp = ngx.socket.tcp
            ngx.socket.tcp = function()
                local sock = real_tcp()
                return setmetatable({}, {__index = function(_, k)
                    if k == "connect" then
                        return function(_, h, p, o)
                            seen[#seen + 1] = o and o.pool or "default"
                            return sock:connect(h, p, o)
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

            local tls = mongo:new()
            tls:set_timeout(5000)
            assert(tls:connect(H, P, {ssl = true, ssl_verify = false, pool = tostring(P)}))
            local plain = mongo:new()
            plain:set_timeout(5000)
            assert(plain:connect(H, P))
            ngx.say(seen[1])
            ngx.say(seen[2])
            ngx.say(seen[1] ~= seen[2])
        }
    }
--- request
GET /t
--- response_body eval
"user:$ENV{TEST_NGINX_MONGO_PORT}\nplain:" . length($ENV{TEST_NGINX_MONGO_HOST}) . ":$ENV{TEST_NGINX_MONGO_HOST}" . length($ENV{TEST_NGINX_MONGO_PORT}) . ":$ENV{TEST_NGINX_MONGO_PORT}\ntrue\n"
--- no_error_log
[crit]
