-- Usage: resty bench/compare.lua <old.jsonl> <new.jsonl>
--        resty bench/compare.lua --trend <new-4.4.jsonl> <new-6.0.jsonl> ...
-- Options: --cpu-dir <snapshots> or --cpu-file <deltas.jsonl>; --single for calibration
local MIN_RPS_RATIO = 0.90
local MAX_P99_RATIO = 1.20

local json = require "cjson.safe"

local function die(message)
    io.stderr:write("compare: ", message, "\n")
    os.exit(2)
end

local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

-- CPU validation is opt-in for legacy standalone JSONL; the Kubernetes runner
-- and report exporter always supply diagnostics. Missing counters then invalidate.
local cpu_dir, cpu_file, single, trend
local paths = {}
local i = 1
while i <= #arg do
    if arg[i] == "--cpu-dir" or arg[i] == "--cpu-file" then
        local option = arg[i]
        i = i + 1
        if not arg[i] then die("usage: missing CPU diagnostics path") end
        if option == "--cpu-dir" then cpu_dir = arg[i] else cpu_file = arg[i] end
    elseif arg[i] == "--single" then single = true
    elseif arg[i] == "--trend" then trend = true
    else paths[#paths + 1] = arg[i] end
    i = i + 1
end
if (not trend and #paths ~= 2) or (trend and #paths < 1) or (single and trend) then
    die("usage: resty bench/compare.lua [--trend|--single] [--cpu-dir path|--cpu-file path] <results.jsonl> ...")
end
local cpu_data, diagnostics, diagnosed = {}, {}, {}
if cpu_file then
    local file, err = io.open(cpu_file, "r")
    if not file then die("cannot read CPU diagnostics: " .. err) end
    for line in file:lines() do
        local row = json.decode(line)
        if type(row) ~= "table" or type(row.label) ~= "string" or type(row.api) ~= "string"
            or type(row.container) ~= "string" then die("invalid CPU diagnostic row") end
        cpu_data[row.label .. ":" .. row.api .. ":" .. row.container] = row
    end
    file:close()
end
local function cpu_delta(row, container)
    if cpu_file then return cpu_data[row.label .. ":" .. row.api .. ":" .. container] end
    local snapshots = {}
    for _, phase in ipairs({"before", "after"}) do
        local file = io.open(cpu_dir .. "/" .. row.label .. "-" .. row.api .. "-" .. phase .. "-" .. container .. ".stat", "r")
        if not file then return end
        local content = file:read("*a")
        file:close()
        if content:find("unavailable:", 1, true) or not content:find("cgroup v2\n", 1, true) then return end
        local values = {}
        for key, value in content:gmatch("([%w_]+) (%d+)\n") do values[key] = tonumber(value) end
        snapshots[#snapshots + 1] = values
    end
    local delta = {available = true}
    for _, key in ipairs({"sample_time_epoch", "usage_usec", "nr_periods", "nr_throttled", "throttled_usec"}) do
        if not snapshots[1][key] or not snapshots[2][key] then return end
        delta[key] = snapshots[2][key] - snapshots[1][key]
    end
    return delta
end
local function cpu_validity(row)
    row.cpu_usage = nil
    if not cpu_dir and not cpu_file then return false end
    local conditions = {}
    local key = row.label .. ":" .. row.api
    local cpu_per_request
    for _, container in ipairs({"nginx", "mongo", "wrk"}) do
        local delta = cpu_delta(row, container)
        local available = delta and delta.available == true
        for _, key in ipairs({"sample_time_epoch", "usage_usec", "nr_periods", "nr_throttled", "throttled_usec"}) do
            if not delta or not finite(delta[key]) or delta[key] < 0 then available = false end
        end
        if not available or delta.sample_time_epoch <= 0 or delta.nr_throttled > delta.nr_periods
            or delta.nr_periods == 0 then
            conditions[#conditions + 1] = container .. " counters unavailable"
        else
            if container == "nginx" and row.interval_requests then
                cpu_per_request = delta.usage_usec / row.interval_requests
                row.cpu_usage = delta.usage_usec
            end
            local fraction = delta.nr_throttled / delta.nr_periods
            conditions[#conditions + 1] = string.format("%s throttled %.3f%% (%d/%d periods; requires < 1%%)%s",
                container, fraction * 100, delta.nr_throttled, delta.nr_periods, fraction >= 0.01 and " INVALID" or "")
        end
    end
    local detail = table.concat(conditions, "; ")
    local invalid = detail:find("INVALID", 1, true) or detail:find("unavailable", 1, true)
    if not diagnosed[key] then
        diagnosed[key] = true
        diagnostics[#diagnostics + 1] = "| " .. row.label .. " | " .. row.api .. " | " .. (invalid and "invalid" or "valid") .. " | "
            .. (cpu_per_request and string.format("%.3f", cpu_per_request) or "unavailable") .. " | " .. detail .. " |\n"
    end
    return not not invalid
end
local function write_diagnostics()
    if #diagnostics == 0 then return end
    io.write("\nCPU validity per pass/API (warm-up, measurement and snapshot overhead):\n\n",
        "| Pass | API | Validity | nginx CPU/request (us) | Conditions |\n| --- | --- | --- | ---: | --- |\n", table.concat(diagnostics))
end

local function read_results(path)
    local file, err = io.open(path, "r")
    if not file then die(path .. ": " .. err) end
    local data = { apis = {} }
    local count = 0
    for line in file:lines() do
        count = count + 1
        local row = json.decode(line)
        local where = path .. ":" .. count
        if type(row) ~= "table" then die(where .. ": invalid JSON object") end
        for _, key in ipairs({ "label", "driver_sha", "mongo_version", "api" }) do
            if type(row[key]) ~= "string" or row[key] == "" then
                die(where .. ": missing or invalid " .. key)
            end
        end
        if not row.api:match("^[%w_]+$") then die(where .. ": invalid api") end
        if not row.mongo_version:match("^%d+%.%d+[%d.%-]*$") then
            die(where .. ": invalid mongo_version")
        end
        for _, key in ipairs({ "rps", "p50_ms", "p90_ms", "p99_ms", "run", "non2xx", "socket_errors" }) do
            if not finite(row[key]) or row[key] < 0 then
                die(where .. ": missing or invalid " .. key)
            end
        end
        if row.rps <= 0 or row.p99_ms <= 0 or row.p50_ms > row.p90_ms or row.p90_ms > row.p99_ms then
            die(where .. ": invalid throughput or latency")
        end
        if row.non2xx ~= 0 or row.socket_errors ~= 0 then
            die(where .. ": run contains HTTP or socket errors")
        end
        if row.interval_requests ~= nil and (not finite(row.interval_requests)
            or row.interval_requests <= 0 or row.interval_requests % 1 ~= 0) then
            die(where .. ": invalid interval_requests")
        end
        if single and row.run ~= 1 then die(where .. ": --single requires exactly run 1") end
        if row.run % 1 ~= 0 or row.run < 1 or row.run > 3 then
            die(where .. ": expected run 1, 2 or 3")
        end
        if data.driver_sha and (data.driver_sha ~= row.driver_sha or data.mongo_version ~= row.mongo_version) then
            die(where .. ": mixed driver SHAs or Mongo versions")
        end
        data.driver_sha, data.mongo_version = row.driver_sha, row.mongo_version
        local runs = data.apis[row.api] or {}
        if runs[row.run] then die(where .. ": duplicate API/run") end
        row.invalid = cpu_validity(row)
        runs[row.run] = row
        data.apis[row.api] = runs
    end
    file:close()
    if count == 0 then die(path .. ": empty results") end
    for api, runs in pairs(data.apis) do
        if not (runs[1] and (single or (runs[2] and runs[3]))) then
            die(path .. ": " .. api .. ": expected three complete runs")
        end
        local rps, p99, invalid = {}, {}, false
        local intervals, usage, requests, complete = {}, 0, 0, true
        for i = 1, single and 1 or 3 do
            invalid = invalid or runs[i].invalid
            rps[i], p99[i] = runs[i].rps, runs[i].p99_ms
            local key = runs[i].label .. ":" .. api
            if intervals[key] then
                if intervals[key].interval_requests ~= runs[i].interval_requests then
                    die(path .. ": " .. api .. ": inconsistent interval_requests")
                end
            else
                intervals[key] = runs[i]
                if runs[i].cpu_usage and runs[i].interval_requests then
                    usage, requests = usage + runs[i].cpu_usage, requests + runs[i].interval_requests
                else complete = false end
            end
        end
        table.sort(rps)
        table.sort(p99)
        data.apis[api] = { rps = rps[single and 1 or 2], p99 = p99[single and 1 or 2], invalid = invalid,
            cpu_per_request = complete and requests > 0 and usage / requests or nil }
    end
    return data
end

local datasets, names, seen, versions = {}, {}, {}, {}
for _, path in ipairs(paths) do
    local data = read_results(path)
    if trend then
        if datasets[1] and data.driver_sha ~= datasets[1].driver_sha then
            die("trend files must use the same driver SHA")
        end
        if versions[data.mongo_version] then die("duplicate trend Mongo version") end
        versions[data.mongo_version] = true
    end
    datasets[#datasets + 1] = data
    for api in pairs(data.apis) do
        if not seen[api] then names[#names + 1], seen[api] = api, true end
    end
end
table.sort(names)

if trend then
    local header, separator = "| API |", "| --- |"
    for _, data in ipairs(datasets) do
        header = header .. " " .. data.mongo_version .. " rps | " .. data.mongo_version .. " p99 (ms) |"
        separator = separator .. " ---: | ---: |"
    end
    io.write(header, "\n", separator, "\n")
    for _, api in ipairs(names) do
        io.write("| ", api, " |")
        for _, data in ipairs(datasets) do
            local row = data.apis[api]
            io.write(row and row.invalid and " invalid | invalid |" or row and string.format(" %.2f | %.3f |", row.rps, row.p99) or " n/a | n/a |")
        end
        io.write("\n")
    end
    write_diagnostics()
    os.exit(0)
end

local old, new = datasets[1], datasets[2]
if old.mongo_version ~= new.mongo_version
    or not (old.mongo_version == "4.4" or old.mongo_version:match("^4%.4[%.%-]")) then
    die("A/B requires the same Mongo 4.4 version on both sides")
end
io.write("| API | Old rps | New rps | Rps ratio | Old p99 (ms) | New p99 (ms) | P99 ratio | Result |\n",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n")
local failed, gated = false, 0
for _, api in ipairs(names) do
    local a, b = old.apis[api], new.apis[api]
    if (a and a.invalid) or (b and b.invalid) then
        io.write("| ", api, " | n/a | n/a | n/a | n/a | n/a | n/a | invalid |\n")
    elseif a and b then
        gated = gated + 1
        local rps_ratio, p99_ratio = b.rps / a.rps, b.p99 / a.p99
        local pass = rps_ratio >= MIN_RPS_RATIO and p99_ratio <= MAX_P99_RATIO
        failed = failed or not pass
        io.write(string.format("| %s | %.2f | %.2f | %.3f | %.3f | %.3f | %.3f | %s |\n",
            api, a.rps, b.rps, rps_ratio, a.p99, b.p99, p99_ratio, pass and "pass" or "fail"))
    elseif b then
        io.write(string.format("| %s | n/a | %.2f | n/a | n/a | %.3f | n/a | n/a (old) |\n", api, b.rps, b.p99))
    else
        failed = true
        io.write(string.format("| %s | %.2f | n/a | n/a | %.3f | n/a | n/a | fail (missing new) |\n", api, a.rps, a.p99))
    end
end
write_diagnostics()
if cpu_dir or cpu_file then
    io.write("\nnginx CPU per request (informational; does not gate):\n\n",
        "| API | Old CPU/request (us) | New CPU/request (us) |\n| --- | ---: | ---: |\n")
    for _, api in ipairs(names) do
        local a, b = old.apis[api], new.apis[api]
        io.write("| ", api, " | ", a and a.cpu_per_request and string.format("%.3f", a.cpu_per_request) or "unavailable",
            " | ", b and b.cpu_per_request and string.format("%.3f", b.cpu_per_request) or "unavailable", " |\n")
    end
end
if gated == 0 then io.write("\nNo API was gated.\n") end
os.exit((failed or gated == 0) and 1 or 0)
