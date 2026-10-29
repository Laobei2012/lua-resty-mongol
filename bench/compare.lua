-- Usage: resty bench/compare.lua <old.jsonl> <new.jsonl>
--        resty bench/compare.lua --trend <new-4.4.jsonl> <new-6.0.jsonl> ...
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
        if row.run % 1 ~= 0 or row.run < 1 or row.run > 3 then
            die(where .. ": expected run 1, 2 or 3")
        end
        if data.driver_sha and (data.driver_sha ~= row.driver_sha or data.mongo_version ~= row.mongo_version) then
            die(where .. ": mixed driver SHAs or Mongo versions")
        end
        data.driver_sha, data.mongo_version = row.driver_sha, row.mongo_version
        local runs = data.apis[row.api] or {}
        if runs[row.run] then die(where .. ": duplicate API/run") end
        runs[row.run] = row
        data.apis[row.api] = runs
    end
    file:close()
    if count == 0 then die(path .. ": empty results") end
    for api, runs in pairs(data.apis) do
        if not (runs[1] and runs[2] and runs[3]) then
            die(path .. ": " .. api .. ": expected three complete runs")
        end
        local rps, p99 = {}, {}
        for i = 1, 3 do
            rps[i], p99[i] = runs[i].rps, runs[i].p99_ms
        end
        table.sort(rps)
        table.sort(p99)
        data.apis[api] = { rps = rps[2], p99 = p99[2] }
    end
    return data
end

local trend = arg[1] == "--trend"
local first = trend and 2 or 1
if (not trend and #arg ~= 2) or (trend and #arg < 2) then
    die("usage: resty bench/compare.lua [--trend] <results.jsonl> ...")
end

local datasets, names, seen, versions = {}, {}, {}, {}
for i = first, #arg do
    local data = read_results(arg[i])
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
            io.write(row and string.format(" %.2f | %.3f |", row.rps, row.p99) or " n/a | n/a |")
        end
        io.write("\n")
    end
    os.exit(0)
end

local old, new = datasets[1], datasets[2]
if old.mongo_version ~= new.mongo_version
    or not (old.mongo_version == "4.4" or old.mongo_version:match("^4%.4[%.%-]")) then
    die("A/B requires the same Mongo 4.4 version on both sides")
end
io.write("| API | Old rps | New rps | Rps ratio | Old p99 (ms) | New p99 (ms) | P99 ratio | Result |\n",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n")
local failed = false
for _, api in ipairs(names) do
    local a, b = old.apis[api], new.apis[api]
    if a and b then
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
os.exit(failed and 1 or 0)
