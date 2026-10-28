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

=== TEST 1: cursor limit
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

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local i, j
            local t = {}
            for i = 1,10 do
                j = 100 - i
                table.insert(t, {name="dog",n=i,m=j})
            end
            r, err = col:insert(t, nil, true)
            if not r then ngx.say("insert failed: "..err) end

            r = col:find({name="dog"})
            r:limit(3)
            for i , v in r:pairs() do
                ngx.say(v["n"])
            end

            r = col:find({name="dog"}, nil, 0)
            r:limit(3)
            for i , v in r:pairs() do
                ngx.say(v["n"])
            end

            r = col:find({name="dog"}, nil, 2)
            r:limit(5)
            for i , v in r:pairs() do
                ngx.say(v["n"])
            end
            conn:close()
        ';
    }
--- request
GET /t
--- response_body
1
2
3
1
2
3
1
2
3
4
5
--- no_error_log
[error]

=== TEST 2: cursor sort
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

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local i, j
            local t = {}
            for i = 1,10 do
                j = 10 - i
                table.insert(t, {name="dog",n=i,m=j})
            end
            r, err = col:insert(t, nil, true)
            if not r then ngx.say("insert failed: "..err) end

            r = col:find({name="dog"}, nil, 5)
            local ret,err = r:sort({n=-1})
            if not ret then ngx.say("sort failed: "..err) 
                ngx.exit(ngx.HTTP_OK) end
            for i , v in pairs(ret) do
                ngx.say(v["n"])
            end

            r = col:find({name="dog"}, nil, 5)
            ret,err = r:sort({n=1})
            if not ret then ngx.say("sort failed: "..err) 
                ngx.exit(ngx.HTTP_OK) end
            for i , v in pairs(ret) do
                ngx.say(v["n"])
            end

            r = col:find({name="dog"}, nil, 5)
            r:limit(3)
            ret,err = r:sort({n=-1})
            if not ret then ngx.say("sort failed: "..err) 
                ngx.exit(ngx.HTTP_OK) end
            for i , v in pairs(ret) do
                ngx.say(v["n"])
            end

            r = col:find({name="dog"}, nil, 3)
            r:limit(5)
            ret,err = r:sort({n=1})
            if not ret then ngx.say("sort failed: "..err) 
                ngx.exit(ngx.HTTP_OK) end
            for i , v in pairs(ret) do
                ngx.say(v["n"])
            end

            conn:close()
        ';
    }
--- request
GET /t
--- response_body
10
9
8
7
6
1
2
3
4
5
10
9
8
1
2
3
--- no_error_log
[error]

=== TEST 3: cursor sort after next
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

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local i, j
            local t = {}
            for i = 1,10 do
                j = 10 - i
                --r, err = col:insert({{name="dog",n=i,m=j}}, nil, true)
                --if not r then ngx.say("insert failed: "..err) end
                table.insert(t, {name="dog",n=i,m=j})
            end
            r, err = col:insert(t, nil, true)
            if not r then ngx.say("insert failed: "..err) end

            r = col:find({name="dog"}, nil, 5)
            r:limit(5)
            for k,v in r:pairs() do
                ngx.say(v["n"])
                break
            end

            local ret,err = r:sort({n=1})
            if not ret then ngx.say("sort failed: "..err) 
                ngx.exit(ngx.HTTP_OK) end
            for i , v in pairs(ret) do
                ngx.say(v["n"])
            end

            for k,v in r:pairs() do
                ngx.say(v["n"])
            end
            local ret,err = r:sort({n=-1})
            if not ret then ngx.say("sort failed: "..err) 
                ngx.exit(ngx.HTTP_OK) end
            for i , v in pairs(ret) do
                ngx.say(v["n"])
            end
            conn:close()
        ';
    }
--- timeout: 50
--- request
GET /t
--- response_body
1
2
3
4
5
2
3
4
5
sort failed: sort must be an array
--- no_error_log
[error]

=== TEST 4: cursor next over limit
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

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            local i, j
            local t = {}
            for i = 1,10 do
                j = 100 - i
                table.insert(t, {name="dog",n=i,m=j})
            end
            r, err = col:insert(t, nil, true)
            if not r then ngx.say("insert failed: "..err) end

            r = col:find({name="dog"})
            r:limit(3)
            for i , v in r:pairs() do
                ngx.say(v["n"])
            end

            k,v = r:next()
            ngx.say(v)

            r = col:find({name="dog"})
            for i = 1, 10 do
                k,v = r:next()
                ngx.say(v["n"])
            end

            i,v = r:next()
            ngx.say(v)

            conn:close()
        ';
    }
--- request
GET /t
--- response_body
1
2
3
nil
1
2
3
4
5
6
7
8
9
10
nil
--- no_error_log
[error]



=== TEST 5: limit across batches
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("cursor_new")
            col:delete({}, nil, true)
            local function fill(list)
                local docs = {}
                for i, n in ipairs(list) do docs[i] = {n = n} end
                col:insert(docs, nil, true)
            end
            local function range(a, b)
                local l = {}
                for i = a, b do l[#l + 1] = i end
                return l
            end
            fill(range(1, 25))
            local c = col:find({}, nil, 10)
            c:limit(23)
            local n = 0
            for _ in c:pairs() do n = n + 1 end
            ngx.say(n, " ", c:next())
        }
    }
--- request
GET /t
--- response_body
23 nil
--- no_error_log
[error]



=== TEST 6: no batch size
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("cursor_new")
            col:delete({}, nil, true)
            local function fill(list)
                local docs = {}
                for i, n in ipairs(list) do docs[i] = {n = n} end
                col:insert(docs, nil, true)
            end
            local function range(a, b)
                local l = {}
                for i = a, b do l[#l + 1] = i end
                return l
            end
            fill(range(1, 150))
            local n = 0
            for _ in col:find({}, nil, 0):pairs() do n = n + 1 end
            ngx.say(n)
        }
    }
--- request
GET /t
--- response_body
150
--- no_error_log
[error]



=== TEST 7: all documents
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("cursor_new")
            col:delete({}, nil, true)
            local function fill(list)
                local docs = {}
                for i, n in ipairs(list) do docs[i] = {n = n} end
                col:insert(docs, nil, true)
            end
            local function range(a, b)
                local l = {}
                for i = a, b do l[#l + 1] = i end
                return l
            end
            fill(range(1, 2500))
            local n = 0
            for _ in col:find({}, nil, 100):pairs() do n = n + 1 end
            ngx.say(n)
        }
    }
--- request
GET /t
--- response_body
2500
--- no_error_log
[error]



=== TEST 8: skip
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("cursor_new")
            col:delete({}, nil, true)
            local function fill(list)
                local docs = {}
                for i, n in ipairs(list) do docs[i] = {n = n} end
                col:insert(docs, nil, true)
            end
            local function range(a, b)
                local l = {}
                for i = a, b do l[#l + 1] = i end
                return l
            end
            fill(range(1, 10))
            local c = col:find({}, nil, 5)
            c:skip(3)
            local first = c:sort({n = 1})
            ngx.say(first[1].n)
        }
    }
--- request
GET /t
--- response_body
4
--- no_error_log
[error]



=== TEST 9: skip after fetch
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("cursor_new")
            col:delete({}, nil, true)
            local function fill(list)
                local docs = {}
                for i, n in ipairs(list) do docs[i] = {n = n} end
                col:insert(docs, nil, true)
            end
            local function range(a, b)
                local l = {}
                for i = a, b do l[#l + 1] = i end
                return l
            end
            fill(range(1, 10))
            local c = col:find({}, nil, 5)
            c:next()
            ngx.say(c:skip(1))
            ngx.say(c:limit(1))
        }
    }
--- request
GET /t
--- response_body
nilcursor already started
nilcursor already started
--- no_error_log
[error]



=== TEST 10: server sort
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("cursor_new")
            col:delete({}, nil, true)
            local function fill(list)
                local docs = {}
                for i, n in ipairs(list) do docs[i] = {n = n} end
                col:insert(docs, nil, true)
            end
            local function range(a, b)
                local l = {}
                for i = a, b do l[#l + 1] = i end
                return l
            end
            fill({5, 2, 7, 1, 6, 3, 4})
            local c = col:find({}, nil, 2)
            c:skip(1)
            c:limit(4)
            local b = c:sort({n = -1})
            ngx.say(b[1].n, " ", b[2].n, " ", b[3])
            c = col:find({}, nil, 2)
            c:skip(1)
            c:limit(4)
            c:sort({n = -1})
            local out = {}
            for _, v in c:pairs() do out[#out + 1] = v.n end
            ngx.say(table.concat(out, " "))
        }
    }
--- request
GET /t
--- response_body
6 5 nil
6 5 4 3
--- no_error_log
[error]



=== TEST 11: close
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("cursor_new")
            col:delete({}, nil, true)
            local function fill(list)
                local docs = {}
                for i, n in ipairs(list) do docs[i] = {n = n} end
                col:insert(docs, nil, true)
            end
            local function range(a, b)
                local l = {}
                for i = a, b do l[#l + 1] = i end
                return l
            end
            fill(range(1, 10))
            local c = col:find({}, nil, 2)
            c:next()
            ngx.say(c:close())
            ngx.say(c:next())
        }
    }
--- request
GET /t
--- response_body
true
nil
--- no_error_log
[error]



=== TEST 12: listcollections
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("cursor_new")
            col:delete({}, nil, true)
            local function fill(list)
                local docs = {}
                for i, n in ipairs(list) do docs[i] = {n = n} end
                col:insert(docs, nil, true)
            end
            local function range(a, b)
                local l = {}
                for i = a, b do l[#l + 1] = i end
                return l
            end
            for _, name in ipairs({"lc_a", "lc_b", "lc_c"}) do
                local x = db:get_col(name)
                x:drop()
                x:insert({{a = 1}}, nil, true)
            end
            local seen = {}
            for _, c in db:listcollections(2):pairs() do
                if c.name:sub(1, 3) == "lc_" then seen[#seen + 1] = c.name end
            end
            table.sort(seen)
            ngx.say(table.concat(seen, ","))
        }
    }
--- request
GET /t
--- response_body
lc_a,lc_b,lc_c
--- no_error_log
[error]



=== TEST 13: fetch error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("cursor_new")
            col:delete({}, nil, true)
            local function fill(list)
                local docs = {}
                for i, n in ipairs(list) do docs[i] = {n = n} end
                col:insert(docs, nil, true)
            end
            local function range(a, b)
                local l = {}
                for i = a, b do l[#l + 1] = i end
                return l
            end
            fill(range(1, 10))
            local c = col:find({}, nil, 2)
            c:next()
            c:next()
            col:drop()
            local a, b = c:next()
            ngx.say(select("#", c:next()) >= 0, " ", a, " ", type(b))
        }
    }
--- request
GET /t
--- response_body
true nil string
--- no_error_log
[error]



=== TEST 14: listcollections with a bad success reply
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local wire = require "resty.mongol.wire"
            local bson = require "resty.mongol.bson"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("sanity_new")
            local replies = {
                {"no cursor", {ok = 1}},
                {"no ns", {ok = 1, cursor = {id = 0, firstBatch = {}}}},
                {"ns is a number", {ok = 1, cursor = {id = 0, ns = 5, firstBatch = {}}}},
                {"id is a string", {ok = 1, cursor = {id = "x", ns = "test.$cmd.listCollections", firstBatch = {}}}},
                {"no batch", {ok = 1, cursor = {id = 0, ns = "test.$cmd.listCollections"}}},
            }
            local real = wire.command
            for _, name in ipairs({"listcollections", "list"}) do
                for _, r in ipairs(replies) do
                    local reply = r[2]
                    wire.command = function() return reply end
                    local ok, a, b = pcall(db[name], db)
                    wire.command = real
                    ngx.say(name, " ", r[1], " ", ok, " ", a, " ", type(b) == "string", " ", conn:set_keepalive())
                    conn:connect()
                end
            end
        }
    }
--- request
GET /t
--- response_body
listcollections no cursor true nil true nilclosed
listcollections no ns true nil true nilclosed
listcollections ns is a number true nil true nilclosed
listcollections id is a string true nil true nilclosed
listcollections no batch true nil true nilclosed
list no cursor true nil true nilclosed
list no ns true nil true nilclosed
list ns is a number true nil true nilclosed
list id is a string true nil true nilclosed
list no batch true nil true nilclosed
--- no_error_log
[error]
