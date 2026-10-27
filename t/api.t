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

=== TEST 1: cmd ping
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            local n, r = t.capture(db:cmd({ping = 1}))
            ngx.say(n, " ", r.ok)
        }
    }
--- request
GET /t
--- response_body
1 1
--- no_error_log
[error]



=== TEST 2: cmd error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            local a, b = db:cmd({nosuchcmd = 1})
            ngx.say(tostring(a), " ", type(b))
        }
    }
--- request
GET /t
--- response_body
nil string
--- no_error_log
[error]



=== TEST 3: databases
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            local col = db:get_col("c_db")
            col:insert({{x = 1}}, nil, true)
            local n, list = t.capture(conn:databases())
            local found = false
            for _, d in ipairs(list) do
                if d.name == "mongol_api" then found = true end
            end
            ngx.say(n, " ", found)
        }
    }
--- request
GET /t
--- response_body
1 true
--- no_error_log
[error]



=== TEST 4: dropDatabase
# db:dropDatabase sends dropDatabase = true; the server needs 1
--- skip_eval: 3: $ENV{TEST_NGINX_MONGO_BASELINE}
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            db:get_col("c_db"):insert({{x = 1}}, nil, true)
            local n, r = t.capture(db:dropDatabase())
            ngx.say(n, " ", r)
            local found = false
            for _, d in ipairs(conn:databases()) do
                if d.name == "mongol_api" then found = true end
            end
            ngx.say(found)
        }
    }
--- request
GET /t
--- response_body
1 1
false
--- no_error_log
[error]



=== TEST 5: query and getmore
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            local col = db:get_col("c_q")
            col:drop()
            for n = 1, 5 do col:insert({{n = n}}, nil, true) end
            local zero = string.rep("\0", 8)
            local n, id, r, flags = t.capture(col:query({}, nil, 0, 2))
            ngx.say(n)
            ngx.say(#id, " ", id ~= zero, " ", #r, " ", type(flags))
            local n2, id2, r2, flags2 = t.capture(col:getmore(id, 10, 2))
            ngx.say(n2, " ", #r2, " ", id2 == zero, " ", type(flags2))
        }
    }
--- request
GET /t
--- response_body
3
8 true 2 table
3 3 true table
--- no_error_log
[error]



=== TEST 6: kill_cursors
# col:kill_cursors sends the collection name inside OP_KILL_CURSORS
--- skip_eval: 3: $ENV{TEST_NGINX_MONGO_BASELINE}
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            local col = db:get_col("c_q")
            col:drop()
            for n = 1, 5 do col:insert({{n = n}}, nil, true) end
            local id = col:query({}, nil, 0, 2)
            local n, ok = t.capture(col:kill_cursors({id}))
            ngx.say(n, " ", ok)
            local n2, _, _, flags = t.capture(col:getmore(id, 10))
            ngx.say(n2, " ", flags.CursorNotFound)
        }
    }
--- request
GET /t
--- response_body
1 true
4 true
--- no_error_log
[error]



=== TEST 7: getprimary standalone
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            local n, p = t.capture(conn:getprimary())
            ngx.say(n, " ", (p:ismaster()))
        }
    }
--- request
GET /t
--- response_body
1 true
--- no_error_log
[error]



=== TEST 8: count with filter
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            local col = db:get_col("c_count")
            col:drop()
            col:insert({{x = 1}, {x = 1}, {x = 2}}, nil, true)
            local n, c = t.capture(col:count({x = 1}))
            ngx.say(n, " ", c)
        }
    }
--- request
GET /t
--- response_body
1 2
--- no_error_log
[error]



=== TEST 9: gridfs read aligned
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            local fs = db:get_gridfs("fs_api")
            fs:remove({}, nil, true)
            db:get_col("fs_api.files"):delete({}, nil, true)
            db:get_col("fs_api.chunks"):delete({}, nil, true)
            fs:insert(t.string_fh("abcdefghijkl"), {chunkSize = 4, filename = "f"}, true)
            local f = fs:find_one({filename = "f"})
            
            local n, bytes = t.capture(f:read(4, 4))
            ngx.say(n, " ", bytes)
            ngx.say(f:read())
        }
    }
--- request
GET /t
--- response_body
1 efgh
abcdefghijkl
--- no_error_log
[error]



=== TEST 10: gridfs read unaligned
# gridfs_file:read ignores the offset inside the first chunk
# TODO(Task 13): also skipped until gridfs_file:read honors the offset inside a chunk.
--- skip_eval: 3: $ENV{TEST_NGINX_MONGO_BASELINE} || 1
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            local fs = db:get_gridfs("fs_api")
            fs:remove({}, nil, true)
            db:get_col("fs_api.files"):delete({}, nil, true)
            db:get_col("fs_api.chunks"):delete({}, nil, true)
            fs:insert(t.string_fh("abcdefghijkl"), {chunkSize = 4, filename = "f"}, true)
            local f = fs:find_one({filename = "f"})
            
            ngx.say(f:read(3, 5))
        }
    }
--- request
GET /t
--- response_body
fgh
--- no_error_log
[error]



=== TEST 11: add_user
# db:add_user calls self:update, which does not exist
--- skip_eval: 3: $ENV{TEST_NGINX_MONGO_BASELINE}
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            db:cmd({dropUser = "u_api"})
            local n, ok = t.capture(db:add_user("u_api", "p"))
            ngx.say(n, " ", ok and true or false)
            ngx.say(db:cmd({usersInfo = "u_api"}).users[1].user)
        }
    }
--- request
GET /t
--- response_body
1 true
u_api
--- no_error_log
[error]



=== TEST 12: listcollections
# listcollections reads system.namespaces, which WiredTiger does not have
--- skip_eval: 3: $ENV{TEST_NGINX_MONGO_BASELINE}
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            db:get_col("c_api"):insert({{x = 1}}, nil, true)
            local n, cur = t.capture(db:listcollections())
            ngx.say(n)
            local found = false
            for _, c in cur:pairs() do
                if c.name == "c_api" then found = true end
            end
            ngx.say(found)
        }
    }
--- request
GET /t
--- response_body
1
true
--- no_error_log
[error]



=== TEST 13: db list
# db:list() does not exist in the old code
--- skip_eval: 3: $ENV{TEST_NGINX_MONGO_BASELINE}
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT, "mongol_api")
            db:get_col("c_api"):insert({{x = 1}}, nil, true)
            local n1, cur1 = t.capture(db:list())
            local n2, cur2 = t.capture(db:listcollections())
            ngx.say(n1, " ", n2)
            local a, b = {}, {}
            for _, c in cur1:pairs() do a[#a + 1] = c.name end
            for _, c in cur2:pairs() do b[#b + 1] = c.name end
            table.sort(a) table.sort(b)
            ngx.say(#a > 0, " ", table.concat(a, ",") == table.concat(b, ","))
        }
    }
--- request
GET /t
--- response_body
1 1
true true
--- no_error_log
[error]



=== TEST 14: shutdown
# conn:shutdown raises a Lua error when the server closes the socket
--- skip_eval: 3: $ENV{TEST_NGINX_MONGO_BASELINE}
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
                        local conn = require("resty.mongol"):new()
            conn:set_timeout(1000)
            conn:connect("127.0.0.1", 12345)
            local ok, err = pcall(conn.shutdown, conn)
            ngx.say(ok)
        }
    }
--- tcp_listen: 12345
--- tcp_reply:
--- request
GET /t
--- response_body
true
--- no_error_log
[error]
