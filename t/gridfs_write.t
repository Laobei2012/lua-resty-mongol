# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (4 * blocks()) - 1;

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_NGINX_TIMEOUT} = 10000;

no_long_string();
#no_diff();

run_tests();

__DATA__


=== TEST 1: write chunk < 1, offset = 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abc", 0)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
12345678901234567890
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile 
abc45678901234567890
--- no_error_log
[error]

=== TEST 2: write chunk < 1, offset > 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abc", 2)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
12345678901234567890
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile 
12abc678901234567890
--- no_error_log
[error]

=== TEST 4: write chunk = 2, offset = 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abcabcdefdef", 0)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
12345678901234567890
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile 
abcabcdefdef34567890
--- no_error_log
[error]

=== TEST 5: write chunk > 1, offset = 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abcabcdef", 0)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
12345678901234567890
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile 
abcabcdef01234567890
--- no_error_log
[error]

=== TEST 6: write chunk > 1, offset > 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abcabcdef", 3)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
12345678901234567890
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile 
123abcabcdef34567890
--- no_error_log
[error]

=== TEST 7: write chunk > 2, offset > 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abcdefghijkl", 5)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
12345678901234567890
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile 
12345abcdefghijkl890
--- no_error_log
[error]

=== TEST 8: write chunk > 2, offset > 0, size > file_size
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abcdefghijklmnopq", 5)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
12345678901234567890
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile chop
12345abcdefghijklmnopq
--- no_error_log
[error]

=== TEST 9: write chunk > 2, offset = 0, size > file_size
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abcdefghijklmnopqrstuvw", 0)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
12345678901234567890
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile chop
abcdefghijklmnopqrstuvw
--- no_error_log
[error]

=== TEST 10: write chunk > old chunk, offset = 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abcdefghijklmnopqrstuvw", 0)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
1234567890
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile chop
abcdefghijklmnopqrstuvw
--- no_error_log
[error]

=== TEST 11: write chunk > old chunk, offset > 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abcdefghijklmnopqrstuvw", 8)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
1234567890
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile chop
12345678abcdefghijklmnopqrstuvw
--- no_error_log
[error]

=== TEST 12: write chunk = 1, offset > 0, size > file size
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abcdefgh", 2)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

        ';
    }
--- user_files
>>> test.txt
12345
--- request
GET /t
--- response_body
0
--- no_error_log
--- output_files
>>> /tmp/testfile chop
12abcdefgh
--- no_error_log
[error]

=== TEST 13: write and update md5
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local f,err = io.open("t/servroot/html/test.txt", "rb")
            if not f then ngx.say("fs open failed: "..err) ngx.exit(ngx.HTTP_OK) end

            r, err = fs:insert(f, {chunkSize = 6, filename="testfile"}, true)
            if not r then ngx.say("fs insert failed: "..err) end
            ngx.say(r)
            io.close(f)

            local gf = fs:find_one({filename="testfile"})
            gf:write("abc", 2)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

            r, err = gf:update_md5()
            if not r then ngx.say("update md5 failed: "..err) end
            ngx.say(gf.file_md5)
        ';
    }
--- user_files
>>> test.txt
123
--- request
GET /t
--- response_body
0
42c56c61ee49c16375960c809c6a3eb0
--- no_error_log
--- output_files
>>> /tmp/testfile chop
12abc
--- no_error_log
[error]


=== TEST 14: new and write and update md5
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local gf = fs:new({chunkSize = 6, filename = "testfile"})

            r,err = gf:write("abc", 0)
            if not r then ngx.say("write failed: "..err) end
            ngx.say(r)

            f = io.open("/tmp/testfile", "wb")
            r,err = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)

            r, err = gf:update_md5()
            if not r then ngx.say("update md5 failed: "..err) end
            ngx.say(gf.file_md5)
        ';
    }
--- user_files
--- request
GET /t
--- response_body
3
900150983cd24fb0d6963f7d28e17f72
--- no_error_log
--- output_files
>>> /tmp/testfile chop
abc
--- no_error_log
[error]

=== TEST 15: write chunk = 1, offset = 0, size = chunk size
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000)
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local gridfs = fs:new({chunkSize = 20, filename = "testfile"})
            local r, err = gridfs:write("ABCDEFGHIJKLMNOPQRST", 0) --gridfs.file_size)
            ngx.say(r)

            f = io.open("/tmp/testfile", "wb")
            r = fs:get(f, {filename="testfile"})
            if not r then ngx.say("get file failed: "..err) end
            io.close(f)
        ';
    }
--- request
GET /t
--- response_body
20
--- output_files
>>> /tmp/testfile chop
ABCDEFGHIJKLMNOPQRST
--- no_error_log
[error]

=== TEST 16: write chunk = 2, offset = chunk size, size = 2*chunk size
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000)
            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r = db:auth("$TEST_NGINX_MONGO_USER", "$TEST_NGINX_MONGO_PASS")
            if not r then ngx.say("auth failed") end
            local fs = db:get_gridfs("fs")

            r, err = fs:remove({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local gridfs = fs:new({chunkSize = 10, filename = "testfile"})
            local r, err = gridfs:write("ABCDEFGHIJKLMNOPQRST", 10) --gridfs.file_size)
            ngx.say(r)
            ngx.say(err)

            --f = io.open("/tmp/testfile", "wb")
            --r = fs:get(f, {filename="testfile"})
            --if not r then ngx.say("get file failed: "..err) end
            --io.close(f)
        ';
    }
--- request
GET /t
--- response_body
nil
invalid offset
--- no_error_log
[error]
