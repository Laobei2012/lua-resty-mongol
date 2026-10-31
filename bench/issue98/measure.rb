# Run from the repository root, with no other benchmark or test running.
# Each system call waits for completion; results from failures are rejected.
master = "/tmp/mongol-i98-master/lib"
candidate = File.expand_path("lib")
helpers = %w[num_to_le_uint num_to_le_int le_int_to_num num_to_be_uint_2
             be_uint_to_num_2 num_to_be_uint_3 be_uint_to_num_3 num_to_be_uint_4
             be_uint_to_num_4 to_double from_double int64_to_le le_to_int64
             is_int64 extract_bits le_bpeek be_bpeek]
callers = %w[wire_ping wire_insert encode_small encode_large decode_small
             encode_typed decode_typed objectid_generate objectid_access]
3.times do |index|
  {"master" => master, "candidate" => candidate}.each do |label, library|
    {"helpers" => helpers, "callers" => callers, "bson" => [nil]}.each do |group, cases|
      path = "bench/issue98/#{group}-#{label}-#{index + 1}.jsonl"
      puts "#{Time.now.utc} #{path}"
      $stdout.flush
      File.open(path, "w") do |output|
        cases.each do |name|
          args = name ? ["bench/ll_micro.lua", group, name] : ["bench/bson_micro.lua"]
          abort "Failed: #{path}" unless system("resty", "-I", library, *args, out: output)
        end
      end
    end
  end
end
