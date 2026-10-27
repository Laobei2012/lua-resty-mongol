# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (3 * blocks());

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__

=== TEST 1: col insert 
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local col = db:get_col("test")

            local r,err = col:insert({{name="dog",n=10,m=20}}, nil, true)
            if not r then ngx.say("insert failed: "..err) end

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            r, err = col:insert({{name="dog",n=10,m=20}, {name="cat"}}, 
                        nil, true)
            if not r then ngx.say("insert failed: "..err) end
            ngx.say(r)

            r = col:find_one({name="dog"})
            ngx.say(r["name"])
            conn:close()
        ';
    }
--- request
GET /t
--- response_body
0
dog
--- no_error_log
[error]

=== TEST 3: socket failed
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 
            ok, err = conn:connect("127.0.0.1", 27016)

            if not ok then
                ngx.say("connect failed: "..err)
            end
        ';
    }
--- request
GET /t
--- response_body
connect failed: connection refused
--- error_log
[error]

=== TEST 4: socket reuse
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 

            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            if not ok then
                ngx.say("connect failed: "..err)
            end
            ngx.say(conn:get_reused_times())

            ok, err = conn:set_keepalive()
            if not ok then
                ngx.say("set keepalive failed: "..err)
            end

            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            if not ok then
                ngx.say("connect failed: "..err)
            end
            ngx.say(conn:get_reused_times())
        ';
    }
--- request
GET /t
--- response_body
0
1
--- no_error_log
[error]


=== TEST 9: col count
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 

            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r
            col = db:get_col("test")

            col:delete({name="sheep"})
            col:insert({{name="sheep"}})
            local n, err = col:count({name="sheep"})
            if not n then
                ngx.say("count fail: "..err)
            end
            ngx.say(n)
        ';
    }
--- request
GET /t
--- response_body
1
--- no_error_log
[error]

=== TEST 10: col update and with $inc
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 

            local r, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            if not r then ngx.say("connect failed: "..err) end

            local db = conn:new_db_handle("test")
            local col = db:get_col("test")

            r,err = col:update({name="dog"},{name="cat"}, nil, nil, true)
            if not r then ngx.say("update failed: "..err) end

            r,err = col:delete({})
            if not r then ngx.say("delete failed: "..err) end

            r,err = col:insert({{name="dog"}})
            if not r then ngx.say("insert failed: "..err) end

            r,err = col:update({name="dog"},{name="cat"}, nil, nil, true)
            if not r then ngx.say("update failed: "..err) end
            ngx.say(r)

            r = col:find_one({name="cat"})
            ngx.say(r["name"])

            r,err = col:update({name="sheep"},{name="cat"}, 1, nil, true)
            if not r then ngx.say("update failed: "..err) end
            ngx.say(r)

            r,err = col:update({name="sheep"},{name="cat"}, nil, nil, true)
            if not r then ngx.say("update failed: "..err) end
            ngx.say(r)


            col:insert({{name="dog",n=1}})

            local update = {}
            update["$inc"] = {n=1}
            r,err = col:update({name="dog"},update, nil, nil, true)
            if not r then ngx.say("update failed: "..err) end
            ngx.say(r)

            r = col:find({name="dog"})
            for i , v in r:pairs() do
                if v["n"] then
                    ngx.say(v["n"])
                end
            end

            col:insert({{name="dog",n=10}})
            r,err = col:update({name="dog"}, update, nil, 1, true)
            if not r then ngx.say("update failed: "..err) end
            ngx.say(r)
        ';
    }
--- request
GET /t
--- response_body
1
cat
1
0
1
2
2
--- no_error_log
[error]

=== TEST 11: col find with limit(getmore)
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 

            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r

            col = db:get_col("test")
            col:delete({name="puppy"})

            for i = 1, 10 do
                col:insert({{name="puppy"}})
            end
            r = col:find({name="puppy"}, nil, 4)
            local j = 0
            for i , v in r:pairs() do
                j = j +1
            end

            ngx.say(j)
        ';
    }
--- request
GET /t
--- response_body
4
--- no_error_log
[error]

=== TEST 12: col find with field
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 

            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r

            col = db:get_col("test")
            col:delete({name="puppy"})

            for i = 1, 10 do
                col:insert({{name="puppy", n=i, m="foo"}})
            end

            r = col:find({name="puppy"}, {n=0}, 3)
            for i , v in r:pairs() do
                ngx.say(v["n"])
                ngx.say(v["name"])
            end

            r = col:find({name="puppy"}, {n=1}, 3)
            for i , v in r:pairs() do
                ngx.say(v["n"])
                ngx.say(v["name"])
            end
        ';
    }
--- request
GET /t
--- response_body
nil
puppy
nil
puppy
nil
puppy
1
nil
2
nil
3
nil
--- no_error_log
[error]

=== TEST 13: col drop
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 

            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r

            col = db:get_col("test")
            col:insert({{name="puppy", n=i, m="foo"}})
            local r,err = col:drop()

            if not r then
                ngx.say(err)
            else
                ngx.say(r)
            end

            local r ,err = col:drop()
            if not r then
                ngx.say(err)
            else
                ngx.say(r)
            end
        ';
    }
--- request
GET /t
--- response_body
1
ns not found
--- no_error_log
[error]

=== TEST 14: col find_one
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 

            local ok, err = conn:connect("127.0.0.1",27017)
            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local r

            local col = db:get_col("test")
            r,err = col:delete({})
            if not r then
                ngx.say("delete failed: "..err)
                ngx.exit(ngx.HTTP_OK)
            end

            col:insert({{name="puppy", n=1, m="foo"}})
            col:insert({{name="puppy", n=2, m="foo"}})

            r = col:find_one({name="puppy"}, {n=1})
            if not r then
                ngx.say("not found")
            end
            ngx.say(r["n"]) 

            r = col:find_one({name="puppy"}, {n=0})
            if not r then
                ngx.say("not found")
            end
            ngx.say(r["n"]) 

            r = col:find_one({name="p"})
            if not r then
                ngx.say("not found")
            end
        ';
    }
--- request
GET /t
--- response_body
1
nil
not found
--- no_error_log
[error]

=== TEST 15: col delete safe 
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

            local col = db:get_col("test")
            r,err = col:delete({}, nil, 1)
            if not r then
                ngx.say("delete failed: "..err)
            end

            local r

            r,err = col:delete({})
            col:insert({{name="puppy", n=1, m="foo"}})
            col:insert({{name="puppy", n=1, m="foo"}})
            col:insert({{name="puppy", n=2, m="foo"}})
            r = col:delete({name="puppy"}, 0, 1)

            if not r then
                ngx.say("delete failed: "..err)
                ngx.exit(ngx.HTTP_OK)
            end
            ngx.say(r)

            col:insert({{name="puppy", n=1, m="foo"}})
            col:insert({{name="puppy", n=1, m="foo"}})
            col:insert({{name="puppy", n=2, m="foo"}})
            r = col:delete({name="puppy"}, 1, true)

            if not r then
                ngx.say("delete failed: "..err)
                ngx.exit(ngx.HTTP_OK)
            end
            ngx.say(r)

            col:insert({{name="puppy", n=1, m="foo"}})
            col:insert({{name="puppy", n=1, m="foo"}})
            col:insert({{name="puppy", n=2, m="foo"}})
            r = col:delete({name="puppy"}, 1, false)

            if not r then
                ngx.say("delete failed: "..err)
                ngx.exit(ngx.HTTP_OK)
            end
            ngx.say(r)
        ';
    }
--- request
GET /t
--- response_body
3
1
-1
--- no_error_log
[error]

=== TEST 16: col insert array
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local col = db:get_col("test")

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local t = {}
            table.insert(t,{a = "aa"})
            table.insert(t,{b = "bb"})
            local t1 = {[0]="a0","a1","a2"}
            local t2 = {}
            t2[2]="a20"
            t2[3] = "a21"
            t2[4] = "a22"
            
            r, err = col:insert({{name="dog",n="10",tab=t,tab1=t1,tab2=t2}}, nil, true)
            if not r then ngx.say("insert failed: "..err) end
            ngx.say(r)

            r = col:find_one({name="dog"})
            ngx.say(r["name"])
            ngx.say(r["tab"][1].a)
            ngx.say(r["tab1"][0])
            ngx.say(r["tab2"][0])
            ngx.say(r["tab2"][2])

            --local update = {}
            --update["$push"] = {tab="a3"}
            --r,err = col:update({name="dog"},update, nil, nil, true)
            --if not r then ngx.say("update failed: "..err) end
            --ngx.say(r)

            --update["$push"] = {tab="a4"}
            --r,err = col:update({name="dog"},update, nil, nil, true)

            conn:close()
        ';
    }
--- request
GET /t
--- response_body
0
dog
aa
a0
nil
a20
--- no_error_log
[error]

=== TEST 17: col insert array and pop
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local col = db:get_col("test")

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local t = {0}
            
            r, err = col:insert({{name="dog",n="10",tab=t}}, nil, true)
            if not r then ngx.say("insert failed: "..err) end
            ngx.say(r)

            local update = {}
            update["$pop"] = {tab=1}
            r,err = col:update({name="dog"},update, nil, nil, true)
            if not r then ngx.say("update failed: "..err) end
            r,err = col:update({name="dog"},update, nil, nil, true)
            if not r then ngx.say("update failed: "..err) end

            r = col:find_one({name="dog"})
            ngx.say(r["tab"][1])

            conn:close()
        ';
    }
--- request
GET /t
--- response_body
0
nil
--- no_error_log
[error]

=== TEST 18: col insert array and push
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local col = db:get_col("test")

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local t = {}
            table.insert(t,{a = "aa"})
            table.insert(t,{b = "bb"})
            local t1 = {[0]="a10","a11","a12"}
            local t2 = {}
            t2[2] = "a22"
            t2[3] = "a23"
            t2[4] = "a24"
            
            r, err = col:insert({{name="dog",n="10",tab=t,tab1=t1,tab2=t2}}, nil, true)
            if not r then ngx.say("insert failed: "..err) end
            ngx.say(r)

            local update = {}
            update["$push"] = {tab="a3",tab1="a13",tab2="a25"}
            r,err = col:update({name="dog"},update, nil, nil, true)
            if not r then ngx.say("update failed: "..err) end
            ngx.say(r)

            r = col:find_one({name="dog"})
            if not r then ngx.say("find failed: "..err) end
            ngx.say(r["tab"][2].b)
            ngx.say(r["tab"][3])
            ngx.say(r["tab1"][2])
            ngx.say(r["tab1"][3])
            ngx.say(r["tab2"][4])
            ngx.say(r["tab2"][5])


            conn:close()
        ';
    }
--- request
GET /t
--- response_body
0
1
bb
a3
a12
a13
a24
a25
--- no_error_log
[error]

=== TEST 19: col insert table and set
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local col = db:get_col("test")

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local t = {a=1,b=2}
            
            r, err = col:insert({{name="dog",n="10",tab=t}}, nil, true)
            if not r then ngx.say("insert failed: "..err) end
            ngx.say(r)

            local update = {}
            update["$set"] = {["tab.a"] = 2}
            --update["$set"]["tab.a"] = 2
            r,err = col:update({name="dog"},update, nil, nil, true)
            if not r then ngx.say("update failed: "..err) end

            r = col:find_one({name="dog"})
            ngx.say(r.tab.a)

            conn:close()
        ';
    }
--- request
GET /t
--- response_body
0
2
--- no_error_log
[error]

=== TEST 20: access
--- http_config eval: $::HttpConfig
--- config
    location /t {
        access_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local col = db:get_col("test")

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local t = {a=1,b=2}
            
            r, err = col:insert({{name="dog",n="10"},tab=t}, nil, true)
            if not r then ngx.say("insert failed: "..err) end

            r = col:find_one({name="dog"})
            ngx.ctx.foo = r
        ';
        content_by_lua '
            local search = ngx.ctx.foo
            ngx.say(search["n"])
        ';
    }
--- request
GET /t
--- response_body
10
--- no_error_log
[error]

=== TEST 21: query by skip and retnum
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local col = db:get_col("test")

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local t = {a=1,b=2}
            
            for i = 1, 10 do
                col:insert({{name="puppy"}})
            end

            sel = {name="puppy"}
            id, results, t = col:query(sel,{_id=1},0,1)
            ngx.say(#results)

            id, results, t = col:query(sel,{_id=1},5,5)
            ngx.say(#results)

            conn:close()
        ';
    }
--- request
GET /t
--- response_body
1
5
--- no_error_log
[error]

=== TEST 22: insert array but get nil
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(10000) 
            ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)

            if not ok then
                ngx.say("connect failed: "..err)
            end

            local db = conn:new_db_handle("test")
            local col = db:get_col("test")

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            col:insert({ {photos={"1","2"} } })
            
            r = col:find_one({})
            for i , v in pairs(r["photos"]) do
                ngx.say(i)
                ngx.say(v)
            end
            ngx.say(#r["photos"])

            conn:close()
        ';
    }
--- request
GET /t
--- response_body
1
1
2
2
2
--- no_error_log
[error]

