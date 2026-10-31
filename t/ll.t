# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (3 * blocks());

no_long_string();

run_tests();

__DATA__

=== TEST 1: four-byte unsigned and signed boundaries
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            for _, s in ipairs({
                "\0\0\0\0", "\1\0\0\0", "\4\3\2\1",
                "\255\255\255\127", "\0\0\0\128", "\255\255\255\255",
            }) do
                ngx.say(ll.le_uint_to_num(s), " ", ll.le_int_to_num(s))
            end
        }
    }
--- request
GET /t
--- response_body
0 0
1 1
16909060 16909060
2147483647 2147483647
2147483648 -2147483648
4294967295 -1
--- no_error_log
[error]



=== TEST 2: four-byte fields inside larger messages
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            local s = "prefix\255\255\255\255suffix"
            ngx.say(ll.le_uint_to_num(s, 7, 10), " ", ll.le_int_to_num(s, 7, 10))
            s = "prefix\4\3\2\1"
            ngx.say(ll.le_uint_to_num(s, 7), " ", ll.le_int_to_num(s, 7))
            local n = 94
            for _ = 1, 1000 do
                n = (1664525 * n + 1013904223) % 2^32
                local bytes = ll.num_to_le_uint(n, 4)
                local message = "prefix" .. bytes .. "suffix"
                local signed = n >= 2^31 and n - 2^32 or n
                assert(ll.le_uint_to_num(bytes) == n)
                assert(ll.le_int_to_num(bytes) == signed)
                assert(ll.le_uint_to_num(message, 7, 10) == n)
                assert(ll.le_int_to_num(message, 7, 10) == signed)
            end
            ngx.say("round trips ok")
        }
    }
--- request
GET /t
--- response_body
4294967295 -1
16909060 16909060
round trips ok
--- no_error_log
[error]



=== TEST 3: other widths retain the generic decoder
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            for _, s in ipairs({
                "", "\255", "\255\255", "\255\255\255",
                "\4\3\2\1\0", "\1\0\0\0\0\0\0\0",
            }) do
                ngx.say(ll.le_uint_to_num(s), " ", ll.le_int_to_num(s))
            end
        }
    }
--- request
GET /t
--- response_body
0 0
255 -1
65535 -1
16777215 -1
16909060 16909060
1 1
--- no_error_log
[error]



=== TEST 4: truncated ranges and unusual offsets retain existing behavior
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            for _, s in ipairs({"", "\4", "\4\3", "\4\3\2"}) do
                ngx.say(ll.le_uint_to_num(s, 1, 4), " ", ll.le_int_to_num(s, 1, 4))
            end
            local s = "\4\3\2\1"
            ngx.say(ll.le_uint_to_num(s, -4, -1), " ", ll.le_int_to_num(s, -4, -1))
            ngx.say(ll.le_uint_to_num(s, 0, 3), " ", ll.le_int_to_num(s, 0, 3))
            ngx.say(ll.le_uint_to_num(s, 5, 8), " ", ll.le_int_to_num(s, 5, 8))
        }
    }
--- request
GET /t
--- response_body
0 0
4 4
772 772
131844 131844
16909060 16909060
131844 131844
0 0
--- no_error_log
[error]



=== TEST 5: four-byte encoding has exact unsigned and signed bytes
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            local cases = {
                {0, "\0\0\0\0"}, {1, "\1\0\0\0"},
                {16909060, "\4\3\2\1"},
                {2147483647, "\255\255\255\127"},
                {2147483648, "\0\0\0\128"},
                {4294967295, "\255\255\255\255"},
            }
            for _, c in ipairs(cases) do
                assert(ll.num_to_le_uint(c[1]) == c[2])
                assert(ll.num_to_le_uint(c[1], 4) == c[2])
                local signed = c[1] >= 2^31 and c[1] - 2^32 or c[1]
                assert(ll.num_to_le_int(signed) == c[2])
                assert(ll.num_to_le_int(signed, 4) == c[2])
            end
            local n = 96
            for _ = 1, 1000 do
                n = (1664525 * n + 1013904223) % 2^32
                local bytes = ll.num_to_le_uint(n, 4)
                local signed = n >= 2^31 and n - 2^32 or n
                assert(ll.le_uint_to_num(bytes) == n)
                assert(ll.num_to_le_int(signed, 4) == bytes)
            end
            ngx.say("encoding ok")
        }
    }
--- request
GET /t
--- response_body
encoding ok
--- no_error_log
[error]



=== TEST 6: four-byte encoding rejects invalid values
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            for _, c in ipairs({
                {ll.num_to_le_uint, -1}, {ll.num_to_le_uint, 2^32},
                {ll.num_to_le_int, -2^31 - 1}, {ll.num_to_le_int, 2^31},
            }) do
                local s, err = c[1](c[2], 4)
                assert(s == nil and err == "number out of range")
            end
            for _, f in ipairs({ll.num_to_le_uint, ll.num_to_le_int}) do
                for _, n in ipairs({0.5, -0.5, math.huge, -math.huge, 0/0}) do
                    local s, err = f(n)
                    assert(s == nil and err == "number out of range")
                end
            end
            ngx.say("invalid values rejected")
        }
    }
--- request
GET /t
--- response_body
invalid values rejected
--- no_error_log
[error]



=== TEST 7: other encoding widths retain their bytes
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            for _, width in ipairs({1, 2, 3, 5, 6}) do
                assert(ll.num_to_le_uint(1, width) == "\1" .. string.rep("\0", width - 1))
                assert(ll.num_to_le_int(-1, width) == string.rep("\255", width))
            end
            assert(ll.num_to_le_uint(1, 8) == "\1" .. string.rep("\0", 7))
            assert(ll.num_to_le_int(1, 8) == "\1" .. string.rep("\0", 7))
            ngx.say("other widths ok")
        }
    }
--- request
GET /t
--- response_body
other widths ok
--- no_error_log
[error]
