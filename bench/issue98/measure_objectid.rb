require "json"

# Run from the repository root with no other benchmark or test running.
libraries = {"master" => "/tmp/mongol-i98-baseline/lib", "candidate" => File.expand_path("lib")}
cases = %w[objectid_generate objectid_access]
3.times do |index|
  libraries.each do |label, library|
    path = "bench/issue98/objectid-nonstring-#{label}-#{index + 1}.jsonl"
    puts "#{Time.now.utc} #{path}"
    $stdout.flush
    File.open(path, "w") do |output|
      cases.each do |name|
        abort "Failed: #{path}" unless system("resty", "-I", library,
          "bench/ll_micro.lua", "callers", name, out: output)
      end
    end
  end
end

File.open("bench/issue98/objectid-nonstring-results.md", "w") do |report|
  report.puts "Baseline: d38bc7e; candidate: 7c5549f plus the string-input guard."
  report.puts "Candidate ll.lua blob: #{IO.popen(%w[git hash-object lib/resty/mongol/ll.lua], &:read).strip}."
  report.puts "Three interleaved master/candidate pairs; fresh resty process per case."
  report.puts "Native arm64 macOS, OpenResty 1.31.8.1, LuaJIT 2.1.ROLLING."
  report.puts "Samples are in run order; medians are in parentheses.\n\n"
  report.puts "| Case | Driver | CPU ns/op | Wall ops/s |"
  report.puts "| --- | --- | --- | --- |"
  cases.each do |name|
    libraries.each_key do |label|
      rows = (1..3).map do |run|
        File.readlines("bench/issue98/objectid-nonstring-#{label}-#{run}.jsonl")
          .map { |line| JSON.parse(line) }.find { |row| row.fetch("case") == name }
      end
      cells = %w[cpu_ns_per_op ops_per_s].map do |key|
        values = rows.map { |row| row.fetch(key) }
        "#{values.map { |v| format('%.2f', v) }.join(', ')} (#{format('%.2f', values.sort[1])})"
      end
      report.puts "| #{name} | #{label} | #{cells.join(' | ')} |"
    end
  end
end
