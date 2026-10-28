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
