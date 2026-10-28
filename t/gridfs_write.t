# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (3 * blocks());

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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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
            local r
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



=== TEST 17: write twice past end
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs13")
            fs:remove({}, nil, true)
            db:get_col("fs13.files"):delete({}, nil, true)
            db:get_col("fs13.chunks"):delete({}, nil, true)
            local gf = assert(fs:new({chunkSize = 4, filename = "t13"}))
            ngx.say(gf:write("abc", 0))
            ngx.say(gf:write("d", 3))
            ngx.say(gf:read(), " ", gf.file_size)
            local again = fs:find_one({filename = "t13"})
            ngx.say(again:read(), " ", again.file_size)
        }
    }
--- request
GET /t
--- response_body
3
1
abcd 4
abcd 4
--- no_error_log
[error]



=== TEST 18: md5 exact multiple
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs13")
            fs:remove({}, nil, true)
            db:get_col("fs13.files"):delete({}, nil, true)
            db:get_col("fs13.chunks"):delete({}, nil, true)
            assert(fs:insert(t.string_fh("abcdefgh"), {chunkSize = 4, filename = "m"}, true))
            local gf = fs:find_one({filename = "m"})
            ngx.say(gf:update_md5())
            local doc = db:get_col("fs13.files"):find_one({filename = "m"})
            ngx.say(doc.md5 == ngx.md5("abcdefgh"), " ", gf.file_md5 == doc.md5)
        }
    }
--- request
GET /t
--- response_body
true
true true
--- no_error_log
[error]



=== TEST 19: large file split
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs13")
            fs:remove({}, nil, true)
            db:get_col("fs13.files"):delete({}, nil, true)
            db:get_col("fs13.chunks"):delete({}, nil, true)
            local old = wire.limits.max_message_size
            wire.limits.max_message_size = 20000
            local data = string.rep("0123456789", 10000)
            local gf = assert(fs:new({chunkSize = 4096, filename = "big"}))
            ngx.say(gf:write(data, 0))
            wire.limits.max_message_size = old
            ngx.say(gf:read() == data, " ", db:get_col("fs13.chunks"):count({files_id = gf.files_id}))
        }
    }
--- request
GET /t
--- response_body
100000
true 25
--- no_error_log
[error]



=== TEST 20: stored types
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs13")
            fs:remove({}, nil, true)
            db:get_col("fs13.files"):delete({}, nil, true)
            db:get_col("fs13.chunks"):delete({}, nil, true)
            assert(fs:insert(t.string_fh("abcdefgh"), {chunkSize = 4, filename = "ty"}, true))
            local f = db:get_col("fs13.files"):find_one({filename = "ty"})
            ngx.say(db:get_col("fs13.files"):count({_id = f._id, chunkSize = {["$type"] = "int"}, length = {["$type"] = "long"}}))
            ngx.say(db:get_col("fs13.chunks"):count({files_id = f._id, n = {["$type"] = "int"}, data = {["$type"] = "binData"}}))
            local gf = assert(fs:new({chunkSize = 4, filename = "ty2"}))
            gf:write("abcdef", 0)
            local f2 = db:get_col("fs13.files"):find_one({filename = "ty2"})
            ngx.say(db:get_col("fs13.files"):count({_id = f2._id, chunkSize = {["$type"] = "int"}, length = {["$type"] = "long"}}))
            ngx.say(db:get_col("fs13.chunks"):count({files_id = f2._id, n = {["$type"] = "int"}, data = {["$type"] = "binData"}}))
        }
    }
--- request
GET /t
--- response_body
1
2
1
2
--- no_error_log
[error]



=== TEST 21: read ranges
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs13")
            fs:remove({}, nil, true)
            db:get_col("fs13.files"):delete({}, nil, true)
            db:get_col("fs13.chunks"):delete({}, nil, true)
            assert(fs:insert(t.string_fh("abcdefghijkl"), {chunkSize = 4, filename = "r"}, true))
            local gf = fs:find_one({filename = "r"})
            ngx.say(gf:read(3, 5))
            ngx.say(gf:read(6, 2))
            ngx.say(gf:read(100, 10))
            ngx.say(gf:read(2, 0))
            ngx.say(gf:read(nil, 8))
            ngx.say(gf:read(0, 3) == "")
            ngx.say(gf:read(4, 12))
            ngx.say(gf:read(-1, 0))
        }
    }
--- request
GET /t
--- response_body
fgh
cdefgh
kl
ab
ijkl
true
nilinvalid offset
nilinvalid size
--- no_error_log
[error]



=== TEST 22: get returns true
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs13")
            fs:remove({}, nil, true)
            db:get_col("fs13.files"):delete({}, nil, true)
            db:get_col("fs13.chunks"):delete({}, nil, true)
            assert(fs:insert(t.string_fh("abcdefghij"), {chunkSize = 4, filename = "g"}, true))
            local out = {}
            local fh = {write = function(self, data) out[#out + 1] = data return self end}
            ngx.say(fs:get(fh, {filename = "g"}), " ", table.concat(out))
            ngx.say(fs:get(fh, {filename = "nofile"}))
        }
    }
--- request
GET /t
--- response_body
true abcdefghij
nilfile not found
--- no_error_log
[error]



=== TEST 23: overwrite keeps the bytes around it
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs13")
            fs:remove({}, nil, true)
            db:get_col("fs13.files"):delete({}, nil, true)
            db:get_col("fs13.chunks"):delete({}, nil, true)
            assert(fs:insert(t.string_fh("abcdefghijkl"), {chunkSize = 4, filename = "o"}, true))
            local gf = fs:find_one({filename = "o"})
            ngx.say(gf:write("XYZ", 3))
            ngx.say(gf:write("12345", 6))
            ngx.say(gf:read(), " ", gf.file_size)
            ngx.say(gf:write("zz", 20))
            ngx.say(gf:write("zz", 0, 5))
        }
    }
--- request
GET /t
--- response_body
3
5
abcXYZ12345l 12
nilinvalid offset
nilinvalid size
--- no_error_log
[error]



=== TEST 24: empty file and the meta table
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs13")
            fs:remove({}, nil, true)
            local meta = {chunkSize = 4, filename = "empty"}
            assert(fs:insert(t.string_fh(""), meta, true))
            ngx.say(type(meta.chunkSize), " ", meta.length, " ", meta.md5)
            local gf = fs:find_one({filename = "empty"})
            ngx.say(string.format("%q", gf:read()), " ", gf.file_size, " ", gf:update_md5())
            local out = {}
            ngx.say(fs:get({write = function(self, d) out[#out + 1] = d return self end}, {filename = "empty"}))
        }
    }
--- request
GET /t
--- response_body
number nil nil
"" 0 true
true
--- no_error_log
[error]



=== TEST 25: a failed query is an error, not a document
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs14")
            fs:remove({}, nil, true)
            db:cmd({drop = "fs14.files"})
            db:cmd({drop = "fs14.chunks"})
            assert(fs:insert(t.string_fh("abcdefgh"), {chunkSize = 4, filename = "x"}, true))
            local gf = fs:find_one({filename = "x"})
            local real = wire.command
            wire.command = function(c, d, cmd, ...)
                if cmd[1] and cmd[1][1] == "find" then return nil, "closed" end
                return real(c, d, cmd, ...)
            end
            local r, err = gf:write("zz", 0)
            ngx.say(r, " ", err)
            r, err = fs:remove({filename = "x"})
            ngx.say(r, " ", err)
            r, err = fs:find_one({filename = "x"})
            ngx.say(r, " ", err)
            r, err = fs:get({write = function() return true end}, {filename = "x"})
            ngx.say(r, " ", err)
            wire.command = real
            -- nothing was removed or changed
            ngx.say(db:get_col("fs14.files"):count({}), " ", fs:find_one({filename = "x"}):read())
        }
    }
--- request
GET /t
--- response_body
nil closed
nil closed
nil closed
nil closed
1 abcdefgh
--- no_error_log
[error]



=== TEST 26: the chunks index is unique
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs14")
            fs:remove({}, nil, true)
            db:cmd({drop = "fs14.files"})
            db:cmd({drop = "fs14.chunks"})
            local gf = assert(fs:new({chunkSize = 4, filename = "ix"}))
            gf:write("abcd", 0)
            local found
            local cur = db:get_col("fs14.chunks"):find({})
            local idx = db:cmd({listIndexes = "fs14.chunks"})
            for _, i in ipairs(idx.cursor.firstBatch) do
                if i.key.files_id == 1 and i.key.n == 1 then found = i end
            end
            ngx.say(found and found.unique, " ", found and found.name)
            local chunks = db:get_col("fs14.chunks")
            local r, err = chunks:insert({{files_id = gf.files_id, n = 0, data = bson.get_bin_data("zzzz")}}, nil, true)
            ngx.say(r, " ", err:find("E11000", 1, true) ~= nil)
        }
    }
--- request
GET /t
--- response_body
true files_id_1_n_1
nil true
--- no_error_log
[error]



=== TEST 27: length never gets shorter
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs14")
            fs:remove({}, nil, true)
            db:cmd({drop = "fs14.files"})
            db:cmd({drop = "fs14.chunks"})
            assert(fs:insert(t.string_fh(""), {chunkSize = 4, filename = "len"}, true))
            local a = fs:find_one({filename = "len"})
            local b = fs:find_one({filename = "len"})
            ngx.say(a:write("abcdefgh", 0))
            -- b has a stale file size of 0
            ngx.say(b:write("xy", 0))
            local doc = db:get_col("fs14.files"):find_one({filename = "len"})
            ngx.say(doc.length, " ", b.file_size)
            ngx.say(fs:find_one({filename = "len"}):read())
        }
    }
--- request
GET /t
--- response_body
8
2
8 2
xycdefgh
--- no_error_log
[error]



=== TEST 28: an update that matches no chunk is an error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs14")
            fs:remove({}, nil, true)
            db:cmd({drop = "fs14.files"})
            db:cmd({drop = "fs14.chunks"})
            assert(fs:insert(t.string_fh("abcdefgh"), {chunkSize = 4, filename = "gone"}, true))
            local gf = fs:find_one({filename = "gone"})
            local real = wire.command
            local chunks = db:get_col("fs14.chunks")
            wire.command = function(c, d, cmd, ...)
                if cmd[1] and cmd[1][1] == "update" and cmd[1][2] == "fs14.chunks" then
                    wire.command = real
                    chunks:delete({files_id = gf.files_id}, nil, true)
                    wire.command = function(...) return real(...) end
                end
                return real(c, d, cmd, ...)
            end
            local r, err = gf:write("zz", 0)
            wire.command = real
            ngx.say(r, " ", type(err), " ", err and err:find("chunk", 1, true) ~= nil)
            -- the length did not change either
            ngx.say(db:get_col("fs14.files"):find_one({filename = "gone"}).length)
        }
    }
--- request
GET /t
--- response_body
nil string true
8
--- no_error_log
[error]



=== TEST 29: a bad chunk is an error on read
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs14")
            fs:remove({}, nil, true)
            db:cmd({drop = "fs14.files"})
            db:cmd({drop = "fs14.chunks"})
            local function fresh(name)
                assert(fs:insert(t.string_fh("abcdefghij"), {chunkSize = 4, filename = name}, true))
                return fs:find_one({filename = name})
            end
            local chunks = db:get_col("fs14.chunks")
            -- a short chunk in the middle
            local gf = fresh("short")
            chunks:update({files_id = gf.files_id, n = 1}, {["$set"] = {data = bson.get_bin_data("ef")}}, 0, 0, true)
            local r, err = gf:read()
            ngx.say(r, " ", type(err))
            -- a short last chunk
            gf = fresh("short_last")
            chunks:update({files_id = gf.files_id, n = 2}, {["$set"] = {data = bson.get_bin_data("i")}}, 0, 0, true)
            r, err = gf:read()
            ngx.say(r, " ", type(err))
            -- data that is not binary
            gf = fresh("text")
            chunks:update({files_id = gf.files_id, n = 0}, {["$set"] = {data = "abcd"}}, 0, 0, true)
            r, err = gf:read()
            ngx.say(r, " ", type(err))
            -- a missing chunk
            gf = fresh("missing")
            chunks:delete({files_id = gf.files_id, n = 1}, 0, true)
            r, err = gf:read()
            ngx.say(r, " ", type(err))
            ngx.say(gf:update_md5())
            -- a good file reads
            gf = fresh("good")
            ngx.say(gf:read(), " ", gf:read(3, 3), " ", gf:update_md5())
        }
    }
--- request
GET /t
--- response_body
nil string
nil string
nil string
nil string
falseread chunk failed
abcdefghij def true
--- no_error_log
[error]



=== TEST 30: chunk size and write range are checked
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs14")
            fs:remove({}, nil, true)
            db:cmd({drop = "fs14.files"})
            db:cmd({drop = "fs14.chunks"})
            for _, bad in ipairs({0, -4, 1.5, "x", true}) do
                local ok, err = pcall(fs.new, fs, {chunkSize = bad, filename = "bad" .. tostring(bad)})
                ngx.say(tostring(bad), " ", ok, " ", tostring(err):find("bad argument", 1, true) ~= nil)
            end
            local ok, err = pcall(fs.insert, fs, t.string_fh("abc"), {chunkSize = 0, filename = "badinsert"}, true)
            ngx.say(ok, " ", tostring(err):find("bad argument", 1, true) ~= nil)
            ngx.say(db:get_col("fs14.files"):count({}), " ", db:get_col("fs14.chunks"):count({}))
            local gf = assert(fs:new({chunkSize = 4, filename = "ok"}))
            ngx.say(gf:write("x", 0, -1))
            ngx.say(gf:write("x", -1))
            ngx.say(gf:write("x", 0, 2))
            for _, args in ipairs({{5, 0}, {"x", "y"}, {"x", 0.5}, {"x", 0, "z"}, {"x", 0, 0.5}}) do
                local pok, perr = pcall(gf.write, gf, args[1], args[2], args[3])
                ngx.say(pok, " ", tostring(perr):find("bad argument", 1, true) ~= nil)
            end
            ngx.say(gf:write("", 0), " ", gf.file_size)
            -- a files document with a chunk size of 0 is not used
            db:get_col("fs14.files"):insert({{_id = "zero", filename = "zero", length = 3, chunkSize = 0}}, nil, true)
            local r, err = fs:find_one({filename = "zero"})
            ngx.say(r, " ", err)
        }
    }
--- request
GET /t
--- response_body
0 false true
-4 false true
1.5 false true
x false true
true false true
false true
0 0
nilinvalid size
nilinvalid offset
nilinvalid size
false true
false true
false true
false true
false true
0 0
nil invalid chunkSize in the files document
--- no_error_log
[error]



=== TEST 31: md5 is a digest or absent
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs14")
            fs:remove({}, nil, true)
            db:cmd({drop = "fs14.files"})
            db:cmd({drop = "fs14.chunks"})
            local gf = assert(fs:new({chunkSize = 4, filename = "new"}))
            local doc = db:get_col("fs14.files"):find_one({filename = "new"})
            ngx.say(doc.md5, " ", gf.file_md5)
            assert(fs:insert(t.string_fh("abcdefgh"), {chunkSize = 4, filename = "ins"}, true))
            doc = db:get_col("fs14.files"):find_one({filename = "ins"})
            ngx.say(doc.md5 == ngx.md5("abcdefgh"))
            local g2 = fs:find_one({filename = "ins"})
            g2:write("zz", 0)
            doc = db:get_col("fs14.files"):find_one({filename = "ins"})
            ngx.say(doc.md5, " ", g2.file_md5)
            ngx.say(g2:update_md5())
            doc = db:get_col("fs14.files"):find_one({filename = "ins"})
            ngx.say(#doc.md5, " ", doc.md5 == ngx.md5("zzcdefgh"))
        }
    }
--- request
GET /t
--- response_body
nil nil
true
nil nil
true
32 true
--- no_error_log
[error]



=== TEST 32: remove deletes every file with a filter and with {}
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local fs = db:get_gridfs("fs14")
            fs:remove({}, nil, true)
            db:cmd({drop = "fs14.files"})
            db:cmd({drop = "fs14.chunks"})
            for _, name in ipairs({"a", "b", "c"}) do
                assert(fs:insert(t.string_fh("abcdefgh"), {chunkSize = 4, filename = name}, true))
            end
            ngx.say(fs:remove({filename = "a"}, nil, true))
            ngx.say(fs:remove({}, nil, true))
            ngx.say(db:get_col("fs14.files"):count({}), " ", db:get_col("fs14.chunks"):count({}))
        }
    }
--- request
GET /t
--- response_body
1
2
0 0
--- no_error_log
[error]
