-- wrk uses LuaJIT without cjson. Keep the JSON encoder limited to the
-- strings and numbers in this fixed schema.
local threads = {}
non2xx = 0

function setup(thread)
    threads[#threads + 1] = thread
end

function response(status)
    if status < 200 or status >= 300 then
        non2xx = non2xx + 1
    end
end

local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
        return string.format('\\u%04x', string.byte(c))
    end) .. '"'
end

function done(summary, latency, requests)
    local bad, sockets = 0, 0
    for _, thread in ipairs(threads) do
        bad = bad + thread:get("non2xx")
    end
    for _, key in ipairs({ "connect", "read", "write", "timeout" }) do
        sockets = sockets + summary.errors[key]
    end
    -- wrk counts >=400 in errors.status; response() also catches redirects.
    bad = math.max(bad, summary.errors.status)
    if bad > 0 or sockets > 0 or summary.requests == 0 or summary.duration <= 0 then
        io.stderr:write("Invalid wrk run: non2xx=", bad,
                        ", socket_errors=", sockets, "\n")
        os.exit(1)
    end
    local function env(name)
        local value = os.getenv("BENCH_" .. name)
        assert(value, "missing BENCH_" .. name)
        return value
    end
    local rps = summary.requests / (summary.duration / 1000000)
    print(string.format(
        '{"label":%s,"driver_sha":%s,"mongo_version":%s,"api":%s,' ..
        '"run":%d,"rps":%.6f,"p50_ms":%.6f,"p90_ms":%.6f,' ..
        '"p99_ms":%.6f,"non2xx":%d,"socket_errors":%d}',
        quote(env("LABEL")), quote(env("DRIVER_SHA")),
        quote(env("MONGO_VERSION")), quote(env("API")),
        assert(tonumber(env("RUN"))), rps,
        latency:percentile(50) / 1000, latency:percentile(90) / 1000,
        latency:percentile(99) / 1000, bad, sockets))
end
