-- Run from the repository root: resty bench/t/compare_test.lua
local json = require "cjson.safe"
local old_path, new_path = "bench/t/old.jsonl", "bench/t/new.jsonl"
local temporary = {}
local checks = 0

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
assert(ok, err)
print("compare: " .. checks .. " checks passed")
