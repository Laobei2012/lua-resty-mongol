-- resty -I <driver>/lib bench/ll_micro.lua [helpers|callers|profile] [case]
-- Same bounded warm-up and 100-operation timing batches as bson_micro.lua.
local ll = require "resty.mongol.ll"
local bson = require "resty.mongol.bson"
local oid = require "resty.mongol.object_id"
local wire = require "resty.mongol.wire"
local cjson = require "cjson"
local profile = require "jit.profile"
local mode = arg[1] or "callers"
local sink = {}
local small = { _id = 1, name = "user1", age = 1, tags = "a b c",
    body = string.rep("x", 200) }
local large = {}
for i = 1, 1000 do large["field" .. i] = string.rep("x", 32) end
local typed = { d = bson.double(1.25), i = bson.int64(9223372036854775807LL) }
local encoded = assert(bson.to_bson(small))
local encoded_typed = assert(bson.to_bson(typed))
local ids, bytes, doubles, int64s, values = {}, {}, {}, {}, {}
for n = 1, 100 do
    bytes[n] = "prefix" .. ll.num_to_le_uint(n * 16909060) .. "suffix"
    doubles[n] = ll.to_double(n + 0.25)
    values[n] = 9223372036854775807LL - n
    int64s[n] = ll.int64_to_le(values[n])
    ids[n] = assert(oid.new(ll.num_to_be_uint(n * 16909060) .. "\5\6\7\8\9" .. ll.num_to_be_uint(n, 3)))
end
local cases = {}
local function add(name, operation) cases[#cases + 1] = {name, operation} end
if mode == "helpers" then
    add("num_to_le_uint", function(n) return ll.num_to_le_uint(n, 4) end)
    add("num_to_le_int", function(n) return ll.num_to_le_int(-n, 4) end)
    add("le_int_to_num", function(n) return ll.le_int_to_num(bytes[n], 7, 10) end)
    for _, width in ipairs({2, 3, 4}) do
        add("num_to_be_uint_" .. width, function(n) return ll.num_to_be_uint(n, width) end)
        add("be_uint_to_num_" .. width, function(n) return ll.be_uint_to_num(bytes[n], 7, 6 + width) end)
    end
    add("to_double", function(n) return ll.to_double(n + 0.25) end)
    add("from_double", function(n) return ll.from_double(doubles[n], 1) end)
    add("int64_to_le", function(n) return ll.int64_to_le(values[n]) end)
    add("le_to_int64", function(n) return ll.le_to_int64(int64s[n], 1) end)
    add("is_int64", function(n) return ll.is_int64(n % 2 == 0 and values[n] or n) end)
    add("extract_bits", function(n) return ll.extract_bits(bytes[n], 8, 19) end)
    add("le_bpeek", function(n) return ll.le_bpeek(bytes[n], n % 32) end)
    add("be_bpeek", function(n) return ll.be_bpeek(bytes[n], n % 32) end)
else
    add("wire_ping", function() return wire.encode_msg("bench", {ping = 1}, nil, 0) end)
    add("wire_insert", function()
        return wire.encode_msg("bench", {insert = "read"}, {{"documents", {small}}}, 0)
    end)
    add("encode_small", function() return bson.to_bson(small) end)
    add("encode_large", function() return bson.to_bson(large) end)
    add("decode_small", function() return bson.decode(encoded) end)
    add("encode_typed", function() return bson.to_bson(typed) end)
    add("decode_typed", function() return bson.decode(encoded_typed) end)
    add("objectid_generate", function() return oid.new() end)
    add("objectid_access", function(n)
        local id = ids[n]
        return id:get_ts() + id:get_pid() + id:get_inc()
    end)
end
if arg[2] then
    local selected = {}
    for _, case in ipairs(cases) do
        if case[1] == arg[2] then selected[1] = case end
    end
    assert(#selected == 1, "unknown case")
    cases = selected
end
for _, case in ipairs(cases) do
    local name, operation = unpack(case)
    jit.flush()
    collectgarbage("collect")
    ngx.update_time()
    local warmup_start = ngx.now()
    for _ = 1, 20 do
        for n = 1, 50 do sink[n] = operation(n) end
        ngx.update_time()
        if ngx.now() - warmup_start >= 1 then break end
    end
    local stacks = {}
    if mode == "profile" then
        profile.start("li1", function(thread, samples, vmstate)
            local stack = vmstate .. " " .. profile.dumpstack(thread, "pl", 8)
            stacks[stack] = (stacks[stack] or 0) + samples
        end)
    end
    ngx.update_time()
    local start, cpu_start = ngx.now(), os.clock()
    local count, elapsed = 0, 0
    repeat
        for n = 1, 100 do sink[n] = operation(n) end
        count = count + 100
        ngx.update_time()
        elapsed = ngx.now() - start
    until elapsed >= 2
    local cpu = os.clock() - cpu_start
    if mode == "profile" then profile.stop() end
    print(cjson.encode({case = name, count = count, wall_seconds = elapsed,
        cpu_seconds = cpu, ops_per_s = count / elapsed, cpu_ns_per_op = cpu * 1e9 / count,
        stacks = mode == "profile" and stacks or nil}))
end
assert(sink[1] ~= nil)
