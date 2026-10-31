-- Run with resty -I <driver>/lib bench/bson_micro.lua.
local bson = require "resty.mongol.bson"
local cjson = require "cjson"
local decode = bson.decode
if not decode then
    local get = require "resty.mongol.get"
    decode = function(value)
        return bson.from_bson(get.get_from_string(value))
    end
end
local small = { _id = 1, name = "user1", age = 1, tags = "a b c",
    body = string.rep("x", 200) }
local large = {}
for i = 1, 1000 do
    large["field" .. i] = string.rep("x", 32)
end
local function measure(name, operation, value)
    collectgarbage("collect")
    ngx.update_time()
    local warmup_start = ngx.now()
    for _ = 1, 20 do
        for _ = 1, 50 do operation(value) end
        ngx.update_time()
        if ngx.now() - warmup_start >= 1 then break end
    end
    ngx.update_time()
    local start = ngx.now()
    local count, elapsed = 0, 0
    repeat
        for _ = 1, 100 do operation(value) end
        count = count + 100
        ngx.update_time()
        elapsed = ngx.now() - start
    until elapsed >= 2
    print(cjson.encode({case = name, ops_per_s = count / elapsed}))
end
for _, fixture in ipairs({{ "small", small }, { "large", large }}) do
    local name, value = fixture[1], fixture[2]
    local encoded = assert(bson.to_bson(value))
    assert(type(decode(encoded)) == "table", "BSON decode failed")
    measure("encode_" .. name, bson.to_bson, value)
    measure("decode_" .. name, decode, encoded)
end

-- Build the envelope directly so the old driver needs neither int64
-- wrappers nor its different array-encoding convention.
local uint32 = require("resty.mongol.ll").num_to_le_uint
local function document(elements)
    return uint32(#elements + 5) .. elements .. "\0"
end
local batch = document("\3" .. "0\0" .. assert(bson.to_bson(small)))
local ns = "bench.read"
local cursor = document("\4firstBatch\0" .. batch
    .. "\18id\0" .. string.rep("\0", 8)
    .. "\2ns\0" .. uint32(#ns + 1) .. ns .. "\0")
local reply = document("\3cursor\0" .. cursor .. "\16ok\0\1\0\0\0")
local decoded = decode(reply)
assert(decoded.ok == 1 and decoded.cursor.id == 0
    and decoded.cursor.ns == ns
    and decoded.cursor.firstBatch[bson.decode and 1 or 0].name == small.name,
    "BSON reply decode failed")
measure("decode_reply", decode, reply)
