# vim:set ft= ts=4 sw=4 et:
use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);
plan tests => repeat_each() * (3 * blocks());
no_long_string();
run_tests();

__DATA__

=== TEST 1: big-endian widths, byte order, boundaries and validation
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            for _, width in ipairs({1, 2, 3, 4, 5, 6}) do
                local max = 2^(8 * width) - 1
                assert(ll.num_to_be_uint(0, width) == string.rep("\0", width))
                assert(ll.num_to_be_uint(1, width) == string.rep("\0", width - 1) .. "\1")
                assert(ll.num_to_be_uint(max, width) == string.rep("\255", width))
                for _, n in ipairs({-1, max + 1, 0.5, -0.5, math.huge, -math.huge, 0/0}) do
                    local value, err = ll.num_to_be_uint(n, width)
                    assert(value == nil and err == "number out of range")
                end
                local n = 98
                for _ = 1, 1000 do
                    n = (1664525 * n + 1013904223) % 2^32
                    local value = n % (max + 1)
                    local s = assert(ll.num_to_be_uint(value, width))
                    local reference = ll.num_to_le_uint(value, width):reverse()
                    assert(s == reference)
                    assert(ll.be_uint_to_num(s) == value)
                    assert(ll.be_uint_to_num("prefix" .. s .. "suffix", 7, 6 + width) == value)
                end
            end
            assert(ll.num_to_be_uint(16909060) == "\1\2\3\4")
            assert(ll.num_to_be_uint(1, 8) == string.rep("\0", 7) .. "\1")
            for _, width in ipairs({-1, 0}) do
                assert(ll.num_to_be_uint(0, width) == "")
            end
            assert(not pcall(ll.num_to_be_uint, {}))
            assert(not pcall(ll.num_to_be_uint, 1, {}))
            for _, width in ipairs({2LL, 3LL, 4LL}) do
                local ok, err = pcall(ll.num_to_be_uint, 1, width)
                assert(not ok and err:find("'for' initial value must be a number", 1, true))
            end
            assert(ll.num_to_be_uint(1, "3") == "\0\0\1")
            ngx.say("big-endian bytes and validation ok")
        }
    }
--- request
GET /t
--- response_body
big-endian bytes and validation ok
--- no_error_log
[error]

=== TEST 2: incomplete and unusual big-endian ranges retain generic behavior
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            local function reference(s, i, j)
                i, j = i or 1, j or #s
                local bytes = {string.byte(s, i, j)}
                local n = 0
                for k = 1, #bytes do n = n * 256 + bytes[k] end
                return n
            end
            for _, s in ipairs({"", "\1", "\1\2", "\1\2\3", "\1\2\3\4", "\1\2\3\4\5"}) do
                assert(ll.be_uint_to_num(s) == reference(s))
                for i = -7, 8 do
                    for j = -7, 8 do
                        assert(ll.be_uint_to_num(s, i, j) == reference(s, i, j))
                    end
                end
                assert(ll.be_uint_to_num(s, 1.5, 3.5) == reference(s, 1.5, 3.5))
            end
            assert(ll.be_uint_to_num("prefix\1\2\3\4", 7) == 16909060)
            assert(ll.be_uint_to_num("\1\2\3\4", "1", "4") == 16909060)
            assert(not pcall(ll.be_uint_to_num, {}))
            ngx.say("ranges ok")
        }
    }
--- request
GET /t
--- response_body
ranges ok
--- no_error_log
[error]

=== TEST 3: ObjectID fields and generated timestamp/counter bytes
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local random = require "resty.random"
            package.loaded["resty.random"] = {bytes = function(n)
                if n == 5 then return "\5\6\7\8\9" end
                return "\255\255\254"
            end}
            package.loaded["resty.mongol.object_id"] = nil
            local oid = require "resty.mongol.object_id"
            local ll = require "resty.mongol.ll"
            local id = assert(oid.new_from_hex("0102030405060708090a0b0c"))
            assert(id:get_ts() == 16909060 and id:get_pid() == 2057 and id:get_inc() == 658188)
            assert(id:get_hostname() == "050607")
            assert(id:tostring() == "0102030405060708090a0b0c")
            local a, b = assert(oid.new()), assert(oid.new())
            assert(a.id:sub(1, 4) == ll.num_to_le_uint(ngx.time()):reverse())
            assert(a.id:sub(5, 12) == "\5\6\7\8\9\255\255\255")
            assert(b.id:sub(10, 12) == "\0\0\0" and b:get_inc() == 0)
            local value, err = oid.new("short")
            assert(value == nil and err == "invalid object id")
            local bson = require "resty.mongol.bson"
            assert(bson.decode(assert(bson.to_bson({id = id}))).id.id == id.id)
            package.loaded["resty.random"] = random
            ngx.say("ObjectID seam ok")
        }
    }
--- request
GET /t
--- response_body
ObjectID seam ok
--- no_error_log
[error]

=== TEST 4: exact 64-bit representations and signed little-endian boundaries
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            local bson = require "resty.mongol.bson"
            for _, v in ipairs({-9223372036854775807LL - 1LL, 9223372036854775807LL,
                               -9007199254740993LL, 9007199254740993LL}) do
                local back = ll.le_to_int64("prefix" .. ll.int64_to_le(v), 7)
                assert(ll.is_int64(back) and back == v)
                local doc = bson.decode(assert(bson.to_bson({v = bson.int64(v)})))
                assert(ll.is_int64(doc.v) and doc.v == v)
            end
            for _, v in ipairs({-9007199254740992, 0, 9007199254740992}) do
                local back = ll.le_to_int64(ll.int64_to_le(v))
                assert(type(back) == "number" and back == v)
            end
            for _, v in ipairs({-2147483648, -1, 0, 2147483647}) do
                assert(ll.le_int_to_num(ll.num_to_le_int(v)) == v)
            end
            assert(ll.from_double(ll.to_double(1.25)) == 1.25)
            ngx.say("exact representations ok")
        }
    }
--- request
GET /t
--- response_body
exact representations ok
--- no_error_log
[error]

=== TEST 5: non-string big-endian inputs retain coercion and errors
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local ll = require "resty.mongol.ll"
            assert(ll.be_uint_to_num(12345678, 1, 4) == 825373492)
            for _, case in ipairs({
                {kind = "nil"},
                {value = true, kind = "boolean"},
                {value = 5LL, kind = "cdata"},
            }) do
                local ok, err = pcall(ll.be_uint_to_num, case.value, 1, 4)
                assert(not ok)
                -- Source paths and line numbers vary across checkouts.
                assert(err:match(":%d+: (.*)$") ==
                    "bad argument #1 to 'strbyte' (string expected, got " .. case.kind .. ")")
            end
            ngx.say("non-string compatibility ok")
        }
    }
--- request
GET /t
--- response_body
non-string compatibility ok
--- no_error_log
[error]
