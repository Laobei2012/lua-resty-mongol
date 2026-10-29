-- Unit harness used by runner_test.sh in place of the wrk runtime.
local report, mode = arg[1], arg[2]
dofile(report)
local thread = { get = function() return non2xx end }
setup(thread)
response(mode == "redirect" and 302 or 200)
local summary = {
    requests = mode == "empty" and 0 or 120,
    duration = 2000000,
    errors = { connect = 0, read = 0, write = 0, timeout = 0, status = 0 },
}
if mode == "socket" then summary.errors.timeout = 1 end
if mode == "status" then summary.errors.status = 1 end
local latency = { percentile = function(_, p) return p * 1000 end }
done(summary, latency, {})
