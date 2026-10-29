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
    for _ = 1, 100000 do operation(value) end
    ngx.update_time()
    local start = ngx.now()
    local count, elapsed = 0, 0
    repeat
        operation(value)
        count = count + 1
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
