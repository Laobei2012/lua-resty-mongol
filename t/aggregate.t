# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (3 * blocks());

no_long_string();
no_shuffle();

run_tests();

__DATA__

=== TEST 1: group sum
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("agg_t")
            col:delete({}, nil, true)
            col:insert({{k = "a", v = 1}, {k = "a", v = 2}, {k = "b", v = 5}}, nil, true)
            local cur, err = col:aggregate({
                {["$group"] = {_id = "$k", total = {["$sum"] = "$v"}}},
                {["$sort"] = {_id = 1}},
            })
            ngx.say(cur ~= nil, " ", err)
            for _, doc in cur:pairs() do
                ngx.say(doc._id, " ", doc.total)
            end
        }
    }
--- request
GET /t
--- response_body
true nil
a 3
b 5
--- no_error_log
[error]



=== TEST 2: batches of one document
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("agg_t")
            col:delete({}, nil, true)
            local docs = {}
            for i = 1, 25 do docs[i] = {n = i} end
            col:insert(docs, nil, true)
            local cur = col:aggregate({{["$sort"] = {n = 1}}}, {batch_size = 4})
            local seen, first, last = 0
            for _, doc in cur:pairs() do
                seen = seen + 1
                first = first or doc.n
                last = doc.n
            end
            ngx.say(seen, " ", first, " ", last)
            -- the default batch size is 100
            local all = 0
            for _ in col:aggregate({{["$match"] = {}}}):pairs() do all = all + 1 end
            ngx.say(all)
            -- close kills the rest of the cursor
            local c2 = col:aggregate({{["$sort"] = {n = 1}}}, {batch_size = 2})
            c2:next()
            ngx.say(c2:close())
        }
    }
--- request
GET /t
--- response_body
25 1 25
25
true
--- no_error_log
[error]



=== TEST 3: empty pipeline, errors and bad arguments
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("agg_t")
            col:delete({}, nil, true)
            col:insert({{a = 1}, {a = 2}}, nil, true)
            local n = 0
            for _ in col:aggregate({}):pairs() do n = n + 1 end
            ngx.say(n)
            -- a server error returns nil, err
            local cur, err = col:aggregate({{["$nosuchstage"] = {}}})
            ngx.say(cur, " ", type(err))
            -- bad arguments raise before anything is sent
            for _, bad in ipairs({"x", 5, true}) do
                local ok, e = pcall(col.aggregate, col, bad)
                ngx.say(ok, " ", tostring(e):find("bad argument", 1, true) ~= nil)
            end
            local ok, e = pcall(col.aggregate, col, {}, "x")
            ngx.say(ok, " ", tostring(e):find("bad argument", 1, true) ~= nil)
            ok, e = pcall(col.aggregate, col, {}, {batch_size = -1})
            ngx.say(ok, " ", tostring(e):find("bad argument", 1, true) ~= nil)
        }
    }
--- request
GET /t
--- response_body
2
nil string
false true
false true
false true
false true
false true
--- no_error_log
[error]



=== TEST 4: bad success reply
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("agg_t")
            local real = wire.command
            for _, reply in ipairs({{ok = 1}, {ok = 1, cursor = {id = 0, ns = "test.agg_t"}},
                                    {ok = 1, cursor = {id = 0, firstBatch = {}}}}) do
                wire.command = function() return reply end
                local cur, err = col:aggregate({})
                wire.command = real
                ngx.say(cur, " ", type(err), " ", conn:set_keepalive())
                conn:connect()
            end
        }
    }
--- request
GET /t
--- response_body
nil string nilclosed
nil string nilclosed
nil string nilclosed
--- no_error_log
[error]



=== TEST 5: a batch_size of false is not the default
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "test")
            local col = db:get_col("agg_t")
            local real = wire.command
            local sent = 0
            wire.command = function(...) sent = sent + 1 return real(...) end
            for _, bad in ipairs({false, "x", true}) do
                local ok, e = pcall(col.aggregate, col, {}, {batch_size = bad})
                ngx.say(tostring(bad), " ", ok, " ", tostring(e):find("bad argument", 1, true) ~= nil)
            end
            wire.command = real
            ngx.say(sent)
        }
    }
--- request
GET /t
--- response_body
false false true
x false true
true false true
0
--- no_error_log
[error]
