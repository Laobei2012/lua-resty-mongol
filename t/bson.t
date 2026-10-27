# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (3 * blocks());

no_long_string();

run_tests();

__DATA__

=== TEST 1: ordered keys
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local s = bson.to_bson(bson.ordered{{"find", "c"}, {"filter", {}}, {"limit", bson.int32(1)}})
            local e = t.elements(s)
            ngx.say(e[1].name, " ", e[3].name, " ", e[3].type)
        }
    }
--- request
GET /t
--- response_body
find limit 16
--- no_error_log
[error]



=== TEST 2: int64 above 2^53
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local ll = require "resty.mongol.ll"
            local v = ll.le_to_int64(ll.int64_to_le(9007199254740993LL), 1)
            ngx.say(tostring(v))
            ngx.say(type(ll.le_to_int64(ll.int64_to_le(2^53), 1)))
        }
    }
--- request
GET /t
--- response_body
9007199254740993LL
number
--- no_error_log
[error]



=== TEST 3: empty table vs empty array
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local e = t.elements(bson.to_bson({f = {}}))
            ngx.say(e[1].type)
            e = t.elements(bson.to_bson({f = bson.empty_array}))
            ngx.say(e[1].type, " ", #t.elements(e[1].value))
        }
    }
--- request
GET /t
--- response_body
3
4 0
--- no_error_log
[error]



=== TEST 4: number keys
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local e = t.elements(bson.to_bson({t = {[0] = "a", "b"}}))
            local names = {}
            for _, x in ipairs(t.elements(e[1].value)) do names[#names + 1] = x.name end
            table.sort(names)
            ngx.say(e[1].type, " ", table.concat(names, ","))
            e = t.elements(bson.to_bson({m = {1, 2, x = 3}}))
            names = {}
            for _, x in ipairs(t.elements(e[1].value)) do names[#names + 1] = x.name end
            table.sort(names)
            ngx.say(e[1].type, " ", table.concat(names, ","))
            local d = bson.from_bson(t.get(bson.to_bson(bson.ordered{{"_keys", "k"}, {"_vals", "v"}})))
            ngx.say(d._keys, " ", d._vals)
            ngx.say(bson.to_bson({[true] = 1}))
        }
    }
--- request
GET /t
--- response_body
3 0,1
3 1,2,x
k v
nilinvalid key
--- no_error_log
[error]



=== TEST 5: nul in values
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local d = bson.from_bson(t.get(bson.to_bson({s = "a\0b"})))
            ngx.say(#d.s, " ", d.s == "a\0b")
            ngx.say(bson.to_bson({["a\0b"] = 1}))
        }
    }
--- request
GET /t
--- response_body
3 true
nilinvalid key
--- no_error_log
[error]



=== TEST 6: number out of range
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local ll = require "resty.mongol.ll"
            ngx.say(ll.num_to_le_uint(2^40, 4))
            ngx.say(ll.num_to_le_int(2^40, 4))
        }
    }
--- request
GET /t
--- response_body
nilnumber out of range
nilnumber out of range
--- no_error_log
[error]



=== TEST 7: number edges
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local cases = {
                {"2^31-1", 2^31 - 1}, {"2^31", 2^31}, {"-2^31-1", -2^31 - 1},
                {"0.5", 0.5}, {"-0.0", -0.0}, {"1e300", 1e300}, {"nan", 0/0},
                {"double(1)", bson.double(1)}, {"cdata", 9007199254740993LL},
                {"-2^31", -2^31}, {"2^63", 2^63}, {"int32(5)", bson.int32(5)},
                {"int64(5)", bson.int64(5)},
            }
            for _, c in ipairs(cases) do
                local s = bson.to_bson({v = c[2]})
                local e = t.elements(s)
                local v = bson.decode(s).v
                local shown
                if type(v) == "cdata" then
                    shown = "cdata " .. tostring(v)
                elseif v ~= v then
                    shown = "nan"
                elseif v == 0 then
                    shown = "zero sign " .. (1 / v < 0 and "-" or "+")
                else
                    shown = string.format("%.17g", v)
                end
                ngx.say(c[1], " ", string.format("0x%02x", e[1].type), " ", shown)
            end
        }
    }
--- request
GET /t
--- response_body
2^31-1 0x10 2147483647
2^31 0x12 2147483648
-2^31-1 0x12 -2147483649
0.5 0x01 0.5
-0.0 0x01 zero sign -
1e300 0x01 1.0000000000000001e+300
nan 0x01 nan
double(1) 0x01 1
cdata 0x12 cdata 9007199254740993LL
-2^31 0x10 -2147483648
2^63 0x01 9.2233720368547758e+18
int32(5) 0x10 5
int64(5) 0x12 5
--- no_error_log
[error]



=== TEST 8: array encode
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local e = t.elements(bson.to_bson({v = {"a", "b"}}))
            local inner = t.elements(e[1].value)
            ngx.say(e[1].type, " ", #inner, " ", inner[1].name, " ", inner[2].name)
        }
    }
--- request
GET /t
--- response_body
4 2 0 1
--- no_error_log
[error]



=== TEST 9: array decode
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            -- {v: ["a", "b"]}
            local d = bson.from_bson(t.get(t.hexbytes(
                "1F000000 04 7600 17000000 02 3000 02000000 6100 02 3100 02000000 6200 00 00")))
            ngx.say(d.v[1], " ", d.v[2], " ", tostring(d.v[0]))
        }
    }
--- request
GET /t
--- response_body
a b nil
--- no_error_log
[error]



=== TEST 10: empty array round trip
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local d = bson.from_bson(t.get(t.hexbytes("0D000000 04 6100 05000000 00 00")))
            ngx.say(getmetatable(d.a) == bson.array_mt)
            ngx.say(t.elements(bson.to_bson(d))[1].type)
        }
    }
--- request
GET /t
--- response_body
true
4
--- no_error_log
[error]



=== TEST 11: negative int32 decode
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local d = bson.from_bson(t.get(t.hexbytes("0C000000 10 6900 FFFFFFFF 00")))
            ngx.say(d.i)
        }
    }
--- request
GET /t
--- response_body
-1
--- no_error_log
[error]



=== TEST 12: null decode
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local d = bson.from_bson(t.get(t.hexbytes("08000000 0A 7800 00")))
            ngx.say(d.x == bson.null)
            ngx.say(t.elements(bson.to_bson({x = bson.null}))[1].type)
        }
    }
--- request
GET /t
--- response_body
true
10
--- no_error_log
[error]



=== TEST 13: array with null
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local d = bson.from_bson(t.get(bson.to_bson({a = {"a", bson.null, "b"}})))
            ngx.say(#d.a, " ", d.a[1], " ", d.a[2] == bson.null, " ", d.a[3])
            local inner = t.elements(t.elements(bson.to_bson(d))[1].value)
            ngx.say(#inner, " ", inner[2].type)
        }
    }
--- request
GET /t
--- response_body
3 a true b
3 10
--- no_error_log
[error]



=== TEST 14: date round trip
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local s = bson.to_bson({d = bson.get_utc_date(-1000)})
            local e = t.elements(s)
            local d = bson.from_bson(t.get(s))
            ngx.say(e[1].type, " ", d.d.v, " ", bson.to_bson(d) == s)
        }
    }
--- request
GET /t
--- response_body
9 -1000 true
--- no_error_log
[error]



=== TEST 15: binary subtype
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local s = bson.to_bson({b = bson.get_bin_data("abc", 4)})
            local e = t.elements(s)
            local d = bson.from_bson(t.get(s))
            ngx.say(e[1].type, " ", e[1].value:byte(5), " ", d.b.v, " ", d.b.st == "\4")
            s = bson.to_bson({b = bson.get_bin_data("abc", 2)})
            d = bson.from_bson(t.get(s))
            ngx.say(d.b.v, " ", bson.to_bson(d) == s)
        }
    }
--- request
GET /t
--- response_body
5 4 abc true
abc true
--- no_error_log
[error]



=== TEST 16: timestamp round trip
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local s = bson.to_bson({ts = bson.timestamp(100, 7)})
            local d = bson.from_bson(t.get(s))
            ngx.say(t.elements(s)[1].type, " ", d.ts.t, " ", d.ts.i)
        }
    }
--- request
GET /t
--- response_body
17 100 7
--- no_error_log
[error]



=== TEST 17: mongol exports
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local mongol = require "resty.mongol"
            ngx.say(t.elements(bson.to_bson({v = mongol.double(1)}))[1].type,
                    t.elements(bson.to_bson({v = mongol.int64(1)}))[1].type,
                    t.elements(bson.to_bson({v = mongol.int32(1)}))[1].type)
            ngx.say(pcall(bson.int32, "x"))
        }
    }
--- request
GET /t
--- response_body
11816
falsebad argument #1 to 'int32' (number expected)
--- no_error_log
[error]
