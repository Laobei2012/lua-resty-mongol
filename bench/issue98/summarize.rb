require "json"

def median(values)
  values.sort[values.length / 2]
end

def samples(values, scale = 1)
  scaled = values.map { |v| v * scale }
  "#{scaled.map { |v| format('%.2f', v) }.join(', ')} (#{format('%.2f', median(scaled))})"
end

puts "Samples are in run order; medians are in parentheses. CPU: ns/op; wall: ops/s."
puts
%w[helpers callers bson].each do |group|
  data = {}
  %w[master candidate].each do |label|
    data[label] = (1..3).map do |run|
      File.readlines("bench/issue98/#{group}-#{label}-#{run}.jsonl").map { |l| JSON.parse(l) }.to_h { |r| [r.fetch("case"), r] }
    end
  end
  puts "### #{group}"
  puts
  puts "| Case | Master CPU | Candidate CPU | Master wall | Candidate wall | Median wall change |"
  puts "| --- | --- | --- | --- | --- | --- |"
  data["master"][0].keys.each do |name|
    old = data["master"].map { |d| d.fetch(name) }
    new = data["candidate"].map { |d| d.fetch(name) }
    old_cpu = old[0]["cpu_ns_per_op"] ? samples(old.map { |d| d.fetch("cpu_ns_per_op") }) : "not collected"
    new_cpu = new[0]["cpu_ns_per_op"] ? samples(new.map { |d| d.fetch("cpu_ns_per_op") }) : "not collected"
    old_wall = old.map { |d| d.fetch("ops_per_s") }
    new_wall = new.map { |d| d.fetch("ops_per_s") }
    change = 100 * (median(new_wall).to_f / median(old_wall) - 1)
    puts "| #{name} | #{old_cpu} | #{new_cpu} | #{samples(old_wall)} | #{samples(new_wall)} | #{format('%+.1f%%', change)} |"
  end
  puts
end

puts "### Baseline sampling profile"
puts
puts "Inclusive samples containing ll.lua frames, grouped by original line ranges; JIT attribution is approximate."
puts
puts "| Caller | Total samples | LE writer | Signed LE writer | Signed LE reader | BE writer | BE reader | FFI helpers |"
puts "| --- | --- | --- | --- | --- | --- | --- | --- |"
File.foreach("bench/issue98/profile-master.jsonl") do |line|
  row = JSON.parse(line)
  groups = [35..48, 49..58, 25..33, 70..80, 60..69, 114..156]
  counts = groups.map do |range|
    row.fetch("stacks").sum do |stack, count|
      stack.scan(/ll\.lua:(\d+)/).any? { |m| range.include?(m[0].to_i) } ? count : 0
    end
  end
  puts "| #{row.fetch('case')} | #{row.fetch('stacks').values.sum} | #{counts.join(' | ')} |"
end
