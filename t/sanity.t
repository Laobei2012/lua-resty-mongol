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
10
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
nil
puppy
nil
puppy
nil
puppy
nil
puppy
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
4
nil
5
nil
6
nil
7
nil
8
nil
9
nil
10
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
--- response_body_like chomp
^1\n(1|ns not found)\n$
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

            local ok, err = conn:connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
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
            ngx.say(r["tab1"]["0"])
            ngx.say(r["tab2"]["0"])
            ngx.say(r["tab2"]["2"])

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
            local t1 = {"a10","a11","a12"}
            local t2 = {"a22","a23","a24"}
            
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
            ngx.say(r["tab1"][3])
            ngx.say(r["tab1"][4])
            ngx.say(r["tab2"][3])
            ngx.say(r["tab2"][4])


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



=== TEST 30: insert safe returns 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            ngx.say(col:insert({{name = "dog"}}, nil, true))
        }
    }
--- request
GET /t
--- response_body
0
--- no_error_log
[error]



=== TEST 31: insert unsafe returns -1
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            ngx.say(col:insert({{name = "dog"}}))
            ngx.say(col:count({}))
        }
    }
--- request
GET /t
--- response_body
-1
1
--- no_error_log
[error]



=== TEST 32: duplicate key
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            ngx.say(col:insert({{_id = 1}}, nil, true))
            local r, err = col:insert({{_id = 1}}, nil, true)
            ngx.say(r, " ", err:find("E11000", 1, true) ~= nil)
        }
    }
--- request
GET /t
--- response_body
0
nil true
--- no_error_log
[error]



=== TEST 33: continue_on_error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local r, err = col:insert({{_id = 1}, {_id = 1}, {_id = 2}}, 1, true)
            ngx.say(r, " ", err ~= nil)
            ngx.say(col:count({}))
        }
    }
--- request
GET /t
--- response_body
nil true
2
--- no_error_log
[error]



=== TEST 34: update multi
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            col:insert({{a = 1}, {a = 2}, {a = 3}}, nil, true)
            ngx.say(col:update({}, {["$set"] = {x = 1}}, 0, 1, true))
        }
    }
--- request
GET /t
--- response_body
3
--- no_error_log
[error]



=== TEST 35: delete single
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            col:insert({{a = 1}, {a = 2}, {a = 3}}, nil, true)
            ngx.say(col:delete({}, 1, true))
        }
    }
--- request
GET /t
--- response_body
1
--- no_error_log
[error]



=== TEST 36: insert split
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local old = wire.limits.max_message_size
            wire.limits.max_message_size = 20000
            local docs = {}
            for i = 1, 50 do docs[i] = {s = string.rep("x", 1000)} end
            ngx.say(col:insert(docs, nil, true))
            wire.limits.max_message_size = old
            ngx.say(col:count({}))
        }
    }
--- request
GET /t
--- response_body
0
50
--- no_error_log
[error]



=== TEST 37: document too large
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local old = wire.limits.max_bson_size
            wire.limits.max_bson_size = 100
            ngx.say(col:insert({{s = string.rep("x", 200)}}, nil, true))
            wire.limits.max_bson_size = old
            ngx.say(col:count({}))
        }
    }
--- request
GET /t
--- response_body
nildocument too large
0
--- no_error_log
[error]



=== TEST 38: ordered stop across batches
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local old = wire.limits.max_message_size
            wire.limits.max_message_size = 20000
            local function docs()
                local d = {}
                for i = 1, 50 do d[i] = {_id = i, s = string.rep("x", 1000)} end
                d[3]._id = 1
                return d
            end
            local r, err = col:insert(docs(), nil, true)
            ngx.say(r, " ", err ~= nil, " ", col:count({}))
            col:delete({}, nil, true)
            r, err = col:insert(docs(), 1, true)
            ngx.say(r, " ", err ~= nil, " ", col:count({}))
            wire.limits.max_message_size = old
        }
    }
--- request
GET /t
--- response_body
nil true 2
nil true 49
--- no_error_log
[error]



=== TEST 39: delete with flag 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            col:insert({{a = 1}, {a = 2}, {a = 3}}, nil, true)
            ngx.say(col:delete({}, 0, true))
        }
    }
--- request
GET /t
--- response_body
3
--- no_error_log
[error]



=== TEST 40: update with flags 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            ngx.say(col:update({x = 9}, {["$set"] = {y = 1}}, 0, 0, true))
            ngx.say(col:count({}))
        }
    }
--- request
GET /t
--- response_body
0
0
--- no_error_log
[error]



=== TEST 43: insert splits by batch size
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local old_size = wire.limits.max_write_batch_size
            wire.limits.max_write_batch_size = 10
            local real = wire.command
            local sizes = {}
            wire.command = function(c, d, cmd, seq, extra)
                if seq and seq[1] then sizes[#sizes + 1] = #seq[1][2] end
                return real(c, d, cmd, seq, extra)
            end
            local docs = {}
            for i = 1, 25 do docs[i] = {n = i} end
            local r = col:insert(docs, nil, true)
            wire.command = real
            wire.limits.max_write_batch_size = old_size
            ngx.say(r, " ", table.concat(sizes, ","), " ", col:count({}))
        }
    }
--- request
GET /t
--- response_body
0 10,10,5 25
--- no_error_log
[error]



=== TEST 44: write concern error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local real = wire.command
            wire.command = function()
                return {ok = 1, n = 1, writeConcernError = {code = 64, errmsg = "waiting for replication timed out"}}
            end
            local a, ea = col:insert({{a = 1}}, nil, true)
            local b, eb = col:update({a = 1}, {["$set"] = {b = 1}}, 0, 0, true)
            local c, ec = col:delete({a = 1}, 0, true)
            wire.command = real
            ngx.say(a, " ", ea)
            ngx.say(b, " ", eb)
            ngx.say(c, " ", ec)
        }
    }
--- request
GET /t
--- response_body
nil waiting for replication timed out
nil waiting for replication timed out
nil waiting for replication timed out
--- no_error_log
[error]



=== TEST 45: unsafe writes with false and 0
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            for _, safe in ipairs({false, 0}) do
                col:delete({}, nil, true)
                local i = col:insert({{a = 1}, {a = 2}}, nil, safe)
                local u = col:update({a = 1}, {["$set"] = {b = 1}}, 0, 0, safe)
                local d = col:delete({a = 2}, 0, safe)
                ngx.say(tostring(safe), " ", i, " ", u, " ", d, " ", col:count({}), " ", col:count({b = 1}))
            end
        }
    }
--- request
GET /t
--- response_body
false -1 -1 -1 1 1
0 -1 -1 -1 1 1
--- no_error_log
[error]



=== TEST 46: oversized document late in the input
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local old = wire.limits.max_bson_size
            wire.limits.max_bson_size = 100
            local real = wire.command
            local sent = 0
            wire.command = function(...) sent = sent + 1 return real(...) end
            local docs = {}
            for i = 1, 5 do docs[i] = {a = i} end
            docs[6] = {s = string.rep("x", 200)}
            local r, err = col:insert(docs, nil, true)
            wire.command = real
            wire.limits.max_bson_size = old
            ngx.say(r, err, " ", sent, " ", col:count({}))
        }
    }
--- request
GET /t
--- response_body
nildocument too large 0 0
--- no_error_log
[error]



=== TEST 41: delete with a bad selector
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            col:insert({{a = 1}, {a = 2}}, nil, true)
            for _, bad in ipairs({"nil", "false", "string", "number"}) do
                local v = ({["nil"] = nil, ["false"] = false, string = "x", number = 1})[bad]
                local ok, err = pcall(col.delete, col, v, nil, true)
                ngx.say(bad, " ", ok, " ", (tostring(err):find("bad argument", 1, true)) and "bad argument" or err)
            end
            ngx.say(col:count({}))
        }
    }
--- request
GET /t
--- response_body
nil false bad argument
false false bad argument
string false bad argument
number false bad argument
2
--- no_error_log
[error]



=== TEST 42: update with a bad selector or document
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            col:insert({{a = 1}, {a = 2}}, nil, true)
            local upd = {["$set"] = {x = 1}}
            for _, bad in ipairs({"nil", "false", "string"}) do
                local v = ({["nil"] = nil, ["false"] = false, string = "x"})[bad]
                local ok, err = pcall(col.update, col, v, upd, false, true, true)
                ngx.say(bad, " ", ok, " ", (tostring(err):find("bad argument", 1, true)) and "bad argument" or err)
            end
            for _, bad in ipairs({"nil", "false", "string"}) do
                local v = ({["nil"] = nil, ["false"] = false, string = "x"})[bad]
                local ok, err = pcall(col.update, col, {}, v, false, true, true)
                ngx.say("doc " .. bad, " ", ok, " ", (tostring(err):find("bad argument", 1, true)) and "bad argument" or err)
            end
            ngx.say(col:count({x = 1}))
        }
    }
--- request
GET /t
--- response_body
nil false bad argument
false false bad argument
string false bad argument
doc nil false bad argument
doc false false bad argument
doc string false bad argument
0
--- no_error_log
[error]



=== TEST 47: find_one
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            col:insert({{name = "dog"}}, nil, true)
            ngx.say(col:find_one({name = "dog"}).name)
        }
    }
--- request
GET /t
--- response_body
dog
--- no_error_log
[error]



=== TEST 48: find_one miss
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            ngx.say(col:find_one({name = "nobody"}))
        }
    }
--- request
GET /t
--- response_body
nil
--- no_error_log
[error]



=== TEST 49: count
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            col:insert({{a = 1}, {a = 2}, {a = 3}, {a = 4}, {a = 5}}, nil, true)
            ngx.say(col:count({}))
        }
    }
--- request
GET /t
--- response_body
5
--- no_error_log
[error]



=== TEST 50: negative int32
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            col:insert({{v = -1}}, nil, true)
            ngx.say(col:find_one({}).v)
        }
    }
--- request
GET /t
--- response_body
-1
--- no_error_log
[error]



=== TEST 51: array round trip
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            col:insert({{v = {"a", "b"}}}, nil, true)
            ngx.say(col:count({v = {["$size"] = 2}}), " ", col:find_one({}).v[1])
        }
    }
--- request
GET /t
--- response_body
1 a
--- no_error_log
[error]



=== TEST 52: add_user roles
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            db:cmd({dropUser = "u2"})
            local r, err = db:add_user("u2", "p2")
            ngx.say(r and true or false, " ", err)
            db:cmd({dropUser = "u2"})
        }
    }
--- request
GET /t
--- response_body
true nil
--- no_error_log
[error]



=== TEST 53: $or array
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            col:insert({{x = 1}, {y = 2}, {z = 3}}, nil, true)
            ngx.say(col:count({["$or"] = {{x = 1}, {y = 2}}}))
        }
    }
--- request
GET /t
--- response_body
2
--- no_error_log
[error]



=== TEST 54: query cursor not found
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local a, b, c, d = col:getmore("\1\0\0\0\0\0\0\0")
            ngx.say(select("#", col:getmore("\1\0\0\0\0\0\0\0")), " ", c.CursorNotFound, " ", type(d))
        }
    }
--- request
GET /t
--- response_body
4 true string
--- no_error_log
[error]



=== TEST 55: query negative count
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local docs = {}
            for i = 1, 200 do docs[i] = {i = i} end
            col:insert(docs, nil, true)
            local id, r = col:query({}, nil, 0, -200)
            ngx.say(#r, " ", id == string.rep("\0", 8))
        }
    }
--- request
GET /t
--- response_body
200 true
--- no_error_log
[error]



=== TEST 56: query server error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local a, b, c, d = col:query({["$bad"] = 1})
            ngx.say(select("#", col:query({["$bad"] = 1})), " ", c.QueryFailure, " ", type(d))
        }
    }
--- request
GET /t
--- response_body
4 true string
--- no_error_log
[error]



=== TEST 57: find_and_modify
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            local r = col:find_and_modify({query = {x = 1}, update = {["$set"] = {y = 2}}, upsert = true, new = true})
            ngx.say(r.x, " ", r.y)
        }
    }
--- request
GET /t
--- response_body
1 2
--- no_error_log
[error]



=== TEST 58: find_and_modify miss
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            col:delete({}, nil, true)
            ngx.say(col:find_and_modify({query = {x = 1}, update = {["$set"] = {y = 2}}}))
            ngx.say(col:find_and_modify({query = {x = 1}, remove = true}))
            ngx.say(col:find_and_modify({query = {x = 1}, update = {["$set"] = {y = 2}}, upsert = true}))
        }
    }
--- request
GET /t
--- response_body
nil
nil
nil
--- no_error_log
[error]
