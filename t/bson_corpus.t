# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (3 * blocks());

no_long_string();

run_tests();

__DATA__

=== TEST 1: bson corpus
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local cjson = require "cjson.safe"
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"

            local dir = "$TEST_NGINX_ROOT/t/spec/bson-corpus/"
            local files = {
                "array", "binary", "boolean", "datetime", "document",
                "double", "int32", "int64", "null", "oid", "string",
                "timestamp", "top",
                "decimal128-1", "decimal128-2", "decimal128-3", "decimal128-4",
                "decimal128-5", "decimal128-6", "decimal128-7",
                "regex", "minkey", "maxkey",
            }
            -- "file: description" = task that fixes it
            local known_failures = {
            }

            -- a Lua value cannot keep the BSON type of a whole double,
            -- an int64 inside the int32 range, the key order of a
            -- document with more than one key, or a NaN payload
            local wrappers = {
                bson.binary_mt, bson.utc_date_mt, bson.timestamp_mt,
                bson.int32_mt, bson.int64_mt, bson.double_mt,
                bson.decimal128_mt, bson.regex_mt, bson.minkey_mt,
                bson.maxkey_mt,
                require("resty.mongol.object_id").metatable,
            }
            local function is_wrapper(v)
                local mt = getmetatable(v)
                for _, w in ipairs(wrappers) do
                    if mt == w then return true end
                end
                return v == bson.null
            end
            -- a wrapper counts as one value, not as its fields
            local function count_keys(v)
                if type(v) ~= "table" or is_wrapper(v) then return 0 end
                local n, max = 0, 0
                for _, x in pairs(v) do
                    n = n + 1
                    local c = count_keys(x)
                    if c > max then max = c end
                end
                if getmetatable(v) == bson.array_mt then n = 0 end
                return n > max and n or max
            end
            local function skip_encode(file, doc)
                if count_keys(doc) > 1 then return true end
                local _, v = next(doc)
                if type(v) == "table" then _, v = next(v) end
                if type(v) ~= "number" then return false end
                if v ~= v then return true end
                if file == "double" and v == math.floor(v)
                    and v > -math.huge and v < math.huge then
                    return true
                end
                if file == "int64" and v >= -2^31 and v < 2^31 then
                    return true
                end
                return false
            end

            for _, name in ipairs(files) do
                local f = assert(io.open(dir .. name .. ".json"))
                local spec = cjson.decode(f:read("*a"))
                f:close()
                local bad = {}
                for _, c in ipairs(spec.valid or {}) do
                    local key = name .. ": " .. c.description
                    local raw = t.hexbytes(c.canonical_bson)
                    local ok, doc = pcall(bson.decode, raw)
                    if not ok then
                        if not known_failures[key] then
                            bad[#bad + 1] = key .. " (decode: " .. tostring(doc) .. ")"
                        end
                    elseif name:find("^decimal128") then
                        -- the string of the value, and the bytes that the
                        -- string makes (the canonical one and the degenerate one)
                        local want = cjson.decode(c.canonical_extjson).d["$numberDecimal"]
                        if tostring(doc.d) ~= want then
                            bad[#bad + 1] = key .. " (string " .. tostring(doc.d) .. " ~= " .. want .. ")"
                        end
                        local strings = {}
                        if not c.lossy then strings[#strings + 1] = want end
                        if c.degenerate_extjson then
                            strings[#strings + 1] = cjson.decode(c.degenerate_extjson).d["$numberDecimal"]
                        end
                        for _, str in ipairs(strings) do
                            local d, err = bson.decimal128(str)
                            if not d or d.v ~= doc.d.v then
                                bad[#bad + 1] = key .. " (parse " .. str .. ": " .. tostring(err) .. ")"
                            end
                        end
                        if bson.to_bson(doc) ~= raw then
                            bad[#bad + 1] = key .. " (encode)"
                        end
                    elseif not skip_encode(name, doc) then
                        local out = bson.to_bson(doc)
                        if out ~= raw and not known_failures[key] then
                            bad[#bad + 1] = key .. " (encode)"
                        end
                    end
                end
                for _, c in ipairs(spec.decodeErrors or {}) do
                    local key = name .. ": " .. c.description
                    local ok, doc = pcall(bson.decode, t.hexbytes(c.bson))
                    if ok and doc and not known_failures[key] then
                        bad[#bad + 1] = key .. " (no decode error)"
                    end
                end
                for _, c in ipairs(spec.parseErrors or {}) do
                    local key = name .. ": " .. c.description
                    local d = bson.decimal128(c.string)
                    if d then
                        bad[#bad + 1] = key .. " (parsed " .. c.string .. ")"
                    end
                end
                if #bad == 0 then
                    ngx.say(name, " ok")
                else
                    ngx.say(name, " FAIL: ", table.concat(bad, "; "))
                end
            end
        }
    }
--- request
GET /t
--- response_body
array ok
binary ok
boolean ok
datetime ok
document ok
double ok
int32 ok
int64 ok
null ok
oid ok
string ok
timestamp ok
top ok
decimal128-1 ok
decimal128-2 ok
decimal128-3 ok
decimal128-4 ok
decimal128-5 ok
decimal128-6 ok
decimal128-7 ok
regex ok
minkey ok
maxkey ok
--- no_error_log
[error]
