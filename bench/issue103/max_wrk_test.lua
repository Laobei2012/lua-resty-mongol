-- Test for max_wrk.lua without the wrk runtime. Run from the repository root:
-- ISSUE103_BASE_REPORT=bench/wrk_report.lua BENCH_LABEL=t BENCH_DRIVER_SHA=s \
--   BENCH_MONGO_VERSION=4.4.30 BENCH_API=insert_100 BENCH_RUN=1 \
--   lua bench/issue103/max_wrk_test.lua bench/issue103/max_wrk.lua
dofile(arg[1])
setup({ get = function() return non2xx end })
response(200)
local lines = {}
print = function(line) lines[#lines + 1] = line end
done({
    requests = 120,
    duration = 2000000,
    errors = { connect = 0, read = 0, write = 0, timeout = 0, status = 0 },
}, {
    max = 4140123,
    percentile = function(_, p) return p * 1000 end,
}, {})
assert(#lines == 1, "expected one JSON line")
local line = lines[1]
assert(line:match('^{.*"requests":120,"max_ms":4140%.123000}$'), line)
assert(line:match('"p99_ms":99%.000000,'), line)
io.stdout:write("ok - max_wrk adds max_ms\n")
