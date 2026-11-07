-- Diagnostic endpoint only. The driver and the standard bench handler stay unchanged.
local mongol = require "resty.mongol"
local json = require "cjson.safe"
local ffi = require "ffi"
ffi.cdef[[
    struct issue103_timespec { long tv_sec; long tv_nsec; };
    int clock_gettime(int clockid, struct issue103_timespec *tp);
]]
local stamp = ffi.new("struct issue103_timespec[1]")
local function now()
    assert(ffi.C.clock_gettime(1, stamp) == 0) -- Linux CLOCK_MONOTONIC
    return tonumber(stamp[0].tv_sec) * 1000 + tonumber(stamp[0].tv_nsec) / 1e6
end

local body = string.rep("x", 200)
local host = os.getenv("MONGO_HOST")
local fields = {"total_ms", "socket_ms", "local_ms", "encode_ms", "build_ms"}
local histograms, count, slow, slow_socket_ms, slow_local_ms
local function reset()
    histograms, count, slow, slow_socket_ms, slow_local_ms = {}, 0, 0, 0, 0
    for _, field in ipairs(fields) do histograms[field] = {} end
end
reset()

local function record(row)
    count = count + 1
    for _, field in ipairs(fields) do
        local bin = math.floor(row[field] * 100) -- 10 microsecond bins
        local histogram = histograms[field]
        histogram[bin] = (histogram[bin] or 0) + 1
    end
    if row.total_ms >= 20 then
        slow = slow + 1
        slow_socket_ms = slow_socket_ms + row.socket_ms
        slow_local_ms = slow_local_ms + row.local_ms
    end
end

local function summary()
    if ngx.var.arg_reset == "1" then reset() end
    local out = {count = count, slow_count = slow,
        slow_socket_ms = slow_socket_ms, slow_local_ms = slow_local_ms}
    for _, field in ipairs(fields) do
        local bins, cumulative = {}, 0
        for bin in pairs(histograms[field]) do bins[#bins + 1] = bin end
        table.sort(bins)
        for _, bin in ipairs(bins) do
            cumulative = cumulative + histograms[field][bin]
            if cumulative >= math.ceil(count * 0.99) then
                out[field .. "_p99_upper_ms"] = (bin + 1) / 100
                break
            end
        end
        out[field .. "_max_upper_ms"] = #bins > 0 and (bins[#bins] + 1) / 100 or 0
    end
    ngx.say(assert(json.encode(out)))
end

local function run()
    local conn = mongol:new()
    conn:set_timeout(10000)
    assert(conn:connect(host, 27017))
    local db = conn:new_db_handle("bench")
    if conn:get_reused_times() == 0 then
        assert(db:auth_scram_sha1("bench", "bench"))
    end

    local build_start = now()
    local docs = {}
    for i = 1, 100 do
        docs[i] = {name = "user" .. i, age = i % 100, tags = "a b c", body = body}
    end
    local build_ms = now() - build_start
    local raw = conn.sock
    local socket_ms, first_send, sends, receives = 0, nil, 0, 0
    conn.sock = {
        close = function() return raw:close() end,
        send = function(_, ...)
            local start = now()
            first_send = first_send or start
            sends = sends + 1
            local a, b, c = raw:send(...)
            socket_ms = socket_ms + now() - start
            return a, b, c
        end,
        receive = function(_, ...)
            local start = now()
            receives = receives + 1
            local a, b, c = raw:receive(...)
            socket_ms = socket_ms + now() - start
            return a, b, c
        end,
    }
    local start = now()
    local result, err = db:get_col("write"):insert(docs, nil, true)
    local total_ms = now() - start
    conn.sock = raw
    assert(result ~= nil, err)
    assert(conn:set_keepalive(10000, 100))
    record({total_ms = total_ms, socket_ms = socket_ms,
        local_ms = math.max(0, total_ms - socket_ms),
        encode_ms = first_send - start, build_ms = build_ms,
        sends = sends, receives = receives})
    return ngx.exit(200)
end

return {run = run, summary = summary}
