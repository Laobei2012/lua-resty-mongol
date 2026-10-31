-- Run from the repository root: resty bench/t/compare_test.lua
local json = require "cjson.safe"
local old_path, new_path = "bench/t/old.jsonl", "bench/t/new.jsonl"
local temporary = {}
local checks = 0
local cpu_dir = os.tmpname()
os.remove(cpu_dir)
assert(os.execute("mkdir " .. cpu_dir))

local function check(condition, message)
    checks = checks + 1
    assert(condition, message)
end

local function read_rows(path)
    local rows = {}
    for line in io.lines(path) do rows[#rows + 1] = assert(json.decode(line)) end
    return rows
end

local function fixture(rows)
    local path = os.tmpname()
    temporary[#temporary + 1] = path
    local file = assert(io.open(path, "w"))
    if type(rows) == "string" then
        file:write(rows)
    else
        for _, row in ipairs(rows) do file:write(assert(json.encode(row)), "\n") end
    end
    file:close()
    return path
end

local function changed(path, change)
    local rows = read_rows(path)
    for i, row in ipairs(rows) do change(row, i) end
    return fixture(rows)
end

-- Execute the real CLI entry point while capturing its output and exit code.
local function run(args)
    local saved_arg, saved_exit = arg, os.exit
    local saved_write, saved_stderr = io.write, io.stderr
    local output, errors = {}, {}
    local exit_signal = {}
    local code
    arg = args
    io.write = function(...)
        for i = 1, select("#", ...) do output[#output + 1] = tostring(select(i, ...)) end
    end
    io.stderr = { write = function(_, ...)
        for i = 1, select("#", ...) do errors[#errors + 1] = tostring(select(i, ...)) end
    end }
    os.exit = function(status) code = status; error(exit_signal) end
    local ok, err = pcall(dofile, "bench/compare.lua")
    arg, os.exit, io.write, io.stderr = saved_arg, saved_exit, saved_write, saved_stderr
    assert(not ok and err == exit_signal, "unexpected script error: " .. tostring(err))
    return code, table.concat(output), table.concat(errors)
end

local function rejected(args, expected)
    local code, output, err = run(args)
    check(code == 2, "invalid dataset must exit 2")
    check(output == "", "invalid dataset must not emit a report")
    check(err:find(expected, 1, true), "expected diagnostic: " .. expected .. "; got " .. err)
end

local function tests()
    local code, output = run({ old_path, new_path })
    check(code == 0 and output:find("| pass |", 1, true), "pass: 95% rps, 110% p99")
    check(output:find("| 0.950 |", 1, true) and output:find("| 1.100 |", 1, true), "ratios")

    local slow = changed(new_path, function(row) row.rps = 85 end)
    code, output = run({ old_path, slow })
    check(code == 1 and output:find("| fail |", 1, true), "fail on rps")
    local high = changed(new_path, function(row) row.p99_ms = 13 end)
    code, output = run({ old_path, high })
    check(code == 1 and output:find("| fail |", 1, true), "fail on p99")
    local boundary = changed(new_path, function(row) row.rps = 90; row.p99_ms = 12 end)
    code, output = run({ old_path, boundary })
    check(code == 0 and output:find("| pass |", 1, true), "inclusive thresholds")

    local median = changed(new_path, function(row, i)
        row.rps = ({ 100, 300, 200 })[i]
        row.p99_ms = ({ 9, 11, 10 })[i]
    end)
    code, output = run({ old_path, median })
    check(code == 0 and output:find("| ping | 100.00 | 200.00 | 2.000 | 10.000 | 10.000 | 1.000 | pass |", 1, true),
        "median of three, independently for rps and p99")

    local extra_rows = read_rows(new_path)
    for _, row in ipairs(read_rows(new_path)) do
        row.api = "find_100"
        extra_rows[#extra_rows + 1] = row
    end
    local extra = fixture(extra_rows)
    code, output = run({ old_path, extra })
    check(code == 0 and output:find("n/a (old)", 1, true), "missing old side does not fail")
    code, output = run({ extra, new_path })
    check(code == 1 and output:find("fail (missing new)", 1, true), "missing new cannot pass")

    local six = changed(new_path, function(row) row.mongo_version = "6.0.26" end)
    local seven = changed(new_path, function(row) row.mongo_version = "7.0.25" end)
    code, output = run({ "--trend", extra, six, seven })
    check(code == 0, "trend exits 0")
    check(output:find("4.4.29 rps | 4.4.29 p99 (ms)", 1, true)
        and output:find("6.0.26 rps | 6.0.26 p99 (ms)", 1, true)
        and output:find("7.0.25 rps | 7.0.25 p99 (ms)", 1, true), "three trend column pairs")
    local _, row_count = output:gsub("| ping |", "")
    check(row_count == 1 and output:find("| find_100 |", 1, true), "one trend row per API")
    check(output:find("n/a | n/a", 1, true) and not output:find("pass") and not output:find("fail"), "trend has no gates")
    local eight = changed(new_path, function(row) row.mongo_version = "8.0.13" end)
    local nine = changed(new_path, function(row) row.mongo_version = "9.0.0" end)
    code, output = run({ "--trend", six, seven, eight, nine })
    check(code == 0 and output:find("9.0.0 p99 (ms)", 1, true), "four-file trend without 4.4")
    code, output = run({ "--trend", new_path, six, seven, eight, nine })
    check(code == 0 and output:find("4.4.29 p99 (ms)", 1, true)
        and output:find("9.0.0 p99 (ms)", 1, true), "five-file trend including 4.4")

    code, output = run({"--cpu-dir", cpu_dir, old_path, new_path})
    check(code == 1 and output:find("| invalid |", 1, true), "empty CPU directory cannot pass")
    check(output:find("No API was gated", 1, true), "zero-gate explanation")

    for _, path in ipairs({old_path, new_path}) do
        for _, row in ipairs(read_rows(path)) do
            for _, container in ipairs({"nginx", "wrk", "mongo"}) do
                for _, phase in ipairs({"before", "after"}) do
                    local file = assert(io.open(cpu_dir .. "/" .. row.label .. "-" .. row.api .. "-" .. phase .. "-" .. container .. ".stat", "w"))
                    file:write("unavailable: cgroup v2 cpu.stat is not readable\n")
                    file:close()
                end
            end
        end
    end
    code, output = run({"--cpu-dir", cpu_dir, old_path, new_path})
    check(code == 1 and output:find("No API was gated", 1, true), "cgroup v1 counters cannot pass")
    check(output:find("counters unavailable", 1, true), "unavailable remains invalid")

    -- CPU validity applies to each label/API interval before the median gate.
    local function counters(container, usage, throttled, periods)
        for _, path in ipairs({old_path, new_path}) do
            for _, row in ipairs(read_rows(path)) do
                for _, phase in ipairs({"before", "after"}) do
                    local file = assert(io.open(cpu_dir .. "/" .. row.label .. "-" .. row.api .. "-" .. phase .. "-" .. container .. ".stat", "w"))
                    local after = phase == "after"
                    file:write(string.format("sample_time_epoch %d\ncgroup v2\nusage_usec %d\nnr_periods %d\nnr_throttled %d\nthrottled_usec 0\n",
                        after and 140 or 100, after and usage or 0, after and periods or 0, after and throttled or 0))
                    file:close()
                end
            end
        end
    end
    counters("nginx", 36000000, 0, 400)
    counters("mongo", 10000000, 3, 400)
    counters("wrk", 10000000, 3, 400)
    code, output = run({"--cpu-dir", cpu_dir, old_path, new_path})
    check(code == 0 and output:find("| pass |", 1, true), "valid CPU boundaries")
    counters("nginx", 35900000, 0, 400)
    code, output = run({"--cpu-dir", cpu_dir, old_path, slow})
    check(code == 1 and output:find("| invalid |", 1, true), "invalid is neither gate pass nor fail")
    check(output:find("nginx usage", 1, true) and output:find("0.897", 1, true), "nginx condition and value")
    counters("nginx", 36000000, 0, 400)
    for _, container in ipairs({"mongo", "wrk"}) do
        counters(container, 10000000, 4, 400)
        code, output = run({"--cpu-dir", cpu_dir, old_path, new_path})
        check(code == 1 and output:find("| invalid |", 1, true), container .. " one percent inclusive")
        check(output:find(container .. " throttled", 1, true) and output:find("1.000%", 1, true), "throttle condition and value")
        counters(container, 10000000, 3, 400)
    end
    counters("wrk", 10000000, 0, 0)
    code, output = run({"--cpu-dir", cpu_dir, old_path, new_path})
    check(code == 1 and output:find("| invalid |", 1, true), "unavailable periods cannot pass")
    counters("wrk", 10000000, 3, 400)
    local cpu_old_path = changed(old_path, function(row) row.label = row.label .. "-" .. row.run end)
    local cpu_new_path = changed(new_path, function(row) row.label = row.label .. "-" .. row.run end)
    -- Only one pass is bad: do not average it away with valid passes.
    local old_rows, new_rows = read_rows(cpu_old_path), read_rows(cpu_new_path)
    local all_cpu = {}
    for _, path in ipairs({cpu_old_path, cpu_new_path}) do
        for _, row in ipairs(read_rows(path)) do
            for _, container in ipairs({"nginx", "mongo", "wrk"}) do
                all_cpu[#all_cpu + 1] = {label=row.label, api=row.api, container=container,
                    available=true, sample_time_epoch=40, usage_usec=36000000,
                    nr_periods=400, nr_throttled=0, throttled_usec=0}
            end
        end
    end
    code, output = run({"--cpu-file", fixture(all_cpu), cpu_old_path, cpu_new_path})
    check(code == 0 and output:find("| pass |", 1, true), "public CPU delta format")
    all_cpu[1].usage_usec = 20000000
    code, output = run({"--cpu-file", fixture(all_cpu), cpu_old_path, cpu_new_path})
    check(code == 1 and output:find("| invalid |", 1, true), "one invalid pass invalidates API")
    for _, rows in ipairs({old_rows, new_rows}) do
        for _, row in ipairs(rows) do row.api = "find_one" end
    end
    for _, rows in ipairs({read_rows(cpu_old_path), read_rows(cpu_new_path)}) do
        for _, row in ipairs(rows) do
            for _, container in ipairs({"nginx", "mongo", "wrk"}) do
                all_cpu[#all_cpu + 1] = {label=row.label, api="find_one", container=container,
                    available=true, sample_time_epoch=40, usage_usec=36000000,
                    nr_periods=400, nr_throttled=0, throttled_usec=0}
            end
        end
    end
    for _, row in ipairs(read_rows(cpu_old_path)) do old_rows[#old_rows+1] = row end
    for _, row in ipairs(read_rows(cpu_new_path)) do row.rps=85; new_rows[#new_rows+1] = row end
    code, output = run({"--cpu-file", fixture(all_cpu), fixture(old_rows), fixture(new_rows)})
    check(code == 0 and output:find("| pass |", 1, true) and output:find("| invalid |", 1, true), "valid API gates independently of invalid API")
    check(not output:find("No API was gated", 1, true), "mixed valid/invalid run actually gates APIs")
    code, output = run({"--cpu-file", fixture({}), cpu_old_path, cpu_new_path})
    check(code == 1 and output:find("| invalid |", 1, true), "missing public counters invalidate")
    check(output:find("counters unavailable", 1, true), "unavailable explanation")

    local one_old, one_new = {read_rows(old_path)[1]}, {read_rows(new_path)[1]}
    code, output = run({"--single", fixture(one_old), fixture(one_new)})
    check(code == 0 and output:find("| pass |", 1, true), "calibration single sample")

    code, output = run({"--cpu-file", fixture({}), "--single", fixture(one_old), fixture(one_new)})
    check(code == 1 and output:find("No API was gated", 1, true), "calibration with zero gates cannot pass")

    rejected({"--single", old_path, new_path}, "--single")
    rejected({}, "usage")
    rejected({ "--trend" }, "usage")
    local absent = os.tmpname()
    os.remove(absent)
    rejected({ absent, new_path }, absent)
    rejected({ fixture(""), new_path }, "empty results")
    rejected({ old_path, fixture("{bad json}\n") }, "invalid JSON")
    rejected({ old_path, fixture("true\n") }, "invalid JSON object")
    rejected({ old_path, changed(new_path, function(row) row.rps = nil end) }, "rps")
    rejected({ old_path, changed(new_path, function(row) row.rps = "95" end) }, "rps")
    local overflow = assert(json.encode(read_rows(new_path)[1])):gsub('"rps":95', '"rps":1e999')
    rejected({ old_path, fixture(overflow .. "\n") }, "rps")
    rejected({ old_path, changed(new_path, function(row) row.p99_ms = 0 end) }, "latency")
    rejected({ old_path, changed(new_path, function(row) row.p50_ms = 20 end) }, "latency")
    rejected({ old_path, changed(new_path, function(row) row.non2xx = 1 end) }, "errors")
    rejected({ old_path, changed(new_path, function(row) row.socket_errors = 1 end) }, "errors")
    rejected({ old_path, changed(new_path, function(row) row.run = 1 end) }, "duplicate")
    rejected({ old_path, changed(new_path, function(row) row.run = 4 end) }, "run 1, 2 or 3")
    local partial = read_rows(new_path)
    table.remove(partial)
    rejected({ old_path, fixture(partial) }, "three complete runs")
    rejected({ old_path, changed(new_path, function(row, i) if i == 2 then row.driver_sha = "other" end end) }, "mixed driver")
    rejected({ old_path, changed(new_path, function(row, i) if i == 2 then row.mongo_version = "6.0.26" end end) }, "mixed driver")
    rejected({ old_path, six }, "same Mongo 4.4")
    rejected({ six, six }, "same Mongo 4.4")
    local forty = changed(new_path, function(row) row.mongo_version = "4.40" end)
    rejected({ forty, forty }, "same Mongo 4.4")
    rejected({ "--trend", new_path, new_path }, "duplicate trend")
    rejected({ "--trend", old_path, six }, "same driver SHA")
    rejected({ "--trend", slow, fixture("{bad json}\n") }, "invalid JSON")
end

local ok, err = pcall(tests)
for _, path in ipairs(temporary) do os.remove(path) end
os.execute("rm -rf " .. cpu_dir)
assert(ok, err)
print("compare: " .. checks .. " checks passed")
