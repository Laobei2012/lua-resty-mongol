-- Use the standard reporter, with optional diagnostic pacing.
dofile(assert(os.getenv("ISSUE103_BASE_REPORT")))
-- Optional diagnostic pacing: one shared send schedule per wrk thread.
local rate = tonumber(os.getenv("ISSUE103_RATE_PER_THREAD"))
if rate then
    assert(rate > 0)
    local ffi = require "ffi"
    ffi.cdef[[
        struct issue103_wrk_timespec { long tv_sec; long tv_nsec; };
        int clock_gettime(int clockid, struct issue103_wrk_timespec *tp);
    ]]
    local stamp = ffi.new("struct issue103_wrk_timespec[1]")
    local next_slot = 0
    function delay()
        assert(ffi.C.clock_gettime(1, stamp) == 0)
        local now = tonumber(stamp[0].tv_sec) * 1000 + tonumber(stamp[0].tv_nsec) / 1e6
        next_slot = math.max(next_slot, now) + 1000 / rate
        return math.floor(next_slot - now)
    end
end
