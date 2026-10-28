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

=== TEST 1: connect_uri replset
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?replicaSet=rs0"))
            ngx.say((conn:ismaster()))
            -- a secondary as the only seed: the connection is still the primary
            local c2 = assert(mongo.connect_uri("mongodb://" .. SH .. ":" .. SP))
            ngx.say((c2:ismaster()), " ", c2.host == H or c2.host)
        }
    }
--- request
GET /t
--- response_body
true
true true
--- no_error_log
[error]



=== TEST 2: secondary read then write
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondaryPreferred"))
            ngx.say((conn.read_conn:ismaster()))
            local col = conn:new_db_handle("test"):get_col("rs_t")
            -- the read goes to the secondary; it may not see a document yet
            local _, err = col:find_one({})
            ngx.say(err)
            ngx.say(col:insert({{a = 1}}, nil, true))
        }
    }
--- request
GET /t
--- response_body
false
nil
0
--- no_error_log
[error]



=== TEST 3: getMore on the same server
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondary"))
            local db = conn:new_db_handle("test")
            local docs = {}
            for i = 1, 25 do docs[i] = {n = i} end
            db:get_col("rs_t2"):delete({}, nil, true)
            assert(db:cmd(bson.ordered{{"insert", "rs_t2"}, {"documents", docs}, {"writeConcern", {w = 3}}}))
            local col = db:get_col("rs_t2")
            local n = 0
            local cur = col:find({}, nil, 10)
            for _ in cur:pairs() do n = n + 1 end
            ngx.say(n, " ", (conn.read_conn:ismaster()))
            local seen = 0
            for _ in col:aggregate({{["$sort"] = {n = 1}}}, {batch_size = 4}):pairs() do seen = seen + 1 end
            ngx.say(seen, " ", col:count({}))
        }
    }
--- request
GET /t
--- response_body
25 false
25 25
--- no_error_log
[error]



=== TEST 4: reads use the read connection and carry the read preference
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local wire = require "resty.mongol.wire"
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondaryPreferred"))
            local db = conn:new_db_handle("test")
            local col = db:get_col("rs_t3")
            col:delete({}, nil, true)
            assert(db:cmd(bson.ordered{{"insert", "rs_t3"}, {"documents", {{a = 1}, {a = 2}, {a = 3}}}, {"writeConcern", {w = 3}}}))
            local real = wire.command
            local seen = {}
            wire.command = function(c, dbname, cmd, seq, extra)
                local name = cmd[1] and cmd[1][1] or next(cmd)
                -- wire.command adds $readPreference for a connection with read_preference
    local pref = c.read_preference or "-"
                seen[#seen + 1] = name .. ":" .. (c == conn.read_conn and "read" or "primary") .. ":" .. pref
                return real(c, dbname, cmd, seq, extra)
            end
            col:find_one({})
            col:count({})
            for _ in col:find({}, nil, 2):pairs() do end
            col:aggregate({}):next()
            col:insert({{a = 4}}, nil, true)
            col:update({a = 4}, {["$set"] = {b = 1}}, 0, 0, true)
            col:delete({a = 4}, 0, true)
            db:cmd({ping = 1})
            wire.command = real
            -- the first command of each kind
            local uniq, order = {}, {}
            for _, s in ipairs(seen) do
                if not uniq[s] then uniq[s] = true order[#order + 1] = s end
            end
            for _, s in ipairs(order) do ngx.say(s) end
        }
    }
--- request
GET /t
--- response_body
find:read:secondaryPreferred
count:read:secondaryPreferred
getMore:read:secondaryPreferred
aggregate:read:secondaryPreferred
insert:primary:-
update:primary:-
delete:primary:-
ping:primary:-
--- no_error_log
[error]



=== TEST 5: read preference modes
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            for _, mode in ipairs({"primary", "primaryPreferred", "secondary", "secondaryPreferred"}) do
                local c = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=" .. mode))
                local rc = c.read_conn
                ngx.say(mode, " ", rc and tostring(rc:ismaster()) or "none", " ", (c:ismaster()))
            end
        }
    }
--- request
GET /t
--- response_body
primary none true
primaryPreferred none true
secondary false true
secondaryPreferred false true
--- no_error_log
[error]
