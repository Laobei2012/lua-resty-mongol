-- Model of wrk 4.1.0 stats_correct() for one pause in a closed-loop sample.
-- It is arithmetic only. It does not reconstruct any measured distribution.
--
-- Usage: resty bench/issue103/co_model.lua [requests] [rps] [connections]
-- Defaults match one original cluster insert_100 sample (30s at ~1050/s).

local requests = tonumber(arg[1]) or 31500
local rps = tonumber(arg[2]) or 1050
local conns = tonumber(arg[3]) or 16
local base_us = 13000

-- Same expected interval as wrk.c: runtime_us / (complete / connections).
local expected = math.floor((requests / rps * 1e6) / math.floor(requests / conns))

local function p99(stall_ms)
    local data = { [base_us] = requests - conns,
                   [math.floor(stall_ms * 1000)] = conns }
    local keys, count = {}, requests
    for k in pairs(data) do keys[#keys + 1] = k end
    table.sort(keys)
    -- Same loop as stats.c: each value >= 2E adds n-E, n-2E, ... while > E.
    for _, n in ipairs(keys) do
        if n >= 2 * expected then
            local m = n - expected
            while m > expected do
                data[m] = (data[m] or 0) + data[n]
                count = count + data[n]
                m = m - expected
            end
        end
    end
    keys = {}
    for k in pairs(data) do keys[#keys + 1] = k end
    table.sort(keys)
    local rank, seen = 0.99 * count, 0
    for _, v in ipairs(keys) do
        seen = seen + data[v]
        if seen >= rank then return v / 1000, count - requests end
    end
end

print(string.format("expected interval: %.3f ms", expected / 1000))
print("pause_ms  corrected_p99_ms  synthetic_samples")
for _, stall in ipairs({ 200, 300, 350, 400, 450, 500, 1000 }) do
    local value, synthetic = p99(stall)
    print(string.format("%8d  %16.3f  %17d", stall, value, synthetic))
end
