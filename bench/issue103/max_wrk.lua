-- Use the standard reporter and add the maximum latency as max_ms.
-- wrk's latency correction adds only values below the maximum, so this
-- value is the slowest real request. The approved reporter is unchanged.
-- ISSUE103_MAX_BASE_REPORT lets profile_wrk.lua load this file as its base.
dofile(assert(os.getenv("ISSUE103_MAX_BASE_REPORT")
    or os.getenv("ISSUE103_BASE_REPORT")))
local base_done = done
function done(summary, latency, requests)
    local base_print = print
    local max_ms = string.format('%.6f', latency.max / 1000)
    print = function(line)
        local out, n = line:gsub('}$', function()
            return ',"max_ms":' .. max_ms .. '}'
        end)
        assert(n == 1, "unexpected reporter output")
        base_print(out)
    end
    base_done(summary, latency, requests)
    print = base_print
end
