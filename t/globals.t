# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (3 * blocks());

no_long_string();

run_tests();

__DATA__

=== TEST 1: no global writes
--- http_config eval
"$::HttpConfig" . q{
    lua_code_cache on;
    init_by_lua_block {
        package.loaded.saved_pairs = pairs
        setmetatable(_G, {__newindex = function(_, k) error("global " .. k) end})
    }
}
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local conn = mongo:new()
            if pairs == package.loaded.saved_pairs then
                ngx.say("ok")
            else
                ngx.say("changed")
            end
        }
    }
--- request
GET /t
--- response_body
ok
--- no_error_log
[error]



=== TEST 2: require and new in init_by_lua
--- http_config eval
"$::HttpConfig" . q{
    init_by_lua_block {
        local conn = require("resty.mongol"):new()
        conn:set_timeout(1000)
        package.loaded.init_conn_ok = conn ~= nil
    }
}
--- config
    location /t {
        content_by_lua_block {
            ngx.say(package.loaded.init_conn_ok)
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
[error]
