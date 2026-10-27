# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

no_shuffle();
master_on();
workers(2);

plan tests => repeat_each() * (3 * blocks());

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__

=== TEST 1: object id
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
            local col = db:get_col("test")

            r, err = col:delete({}, nil, true)
            if not r then ngx.say("delete failed: "..err) end

            r, err = col:insert({{name="dog",n=10,m=20}, {name="cat"}}, 
                        nil, true)
            if not r then ngx.say("insert failed: "..err) end
            ngx.say(r)

            r = col:find_one({name="dog"})

            ngx.say(r["_id"].id)
            ngx.say(r["_id"]:tostring())
            ngx.say(r["_id"]:get_ts())
            ngx.say(r["_id"]:get_hostname())
            ngx.say(r["_id"]:get_pid())
            ngx.say(r["_id"]:get_inc())
            ngx.say(r["name"])

            r = col:find_one({_id=r["id"]})
            ngx.say(r["name"])

            conn:close()
        ';
    }
--- request
GET /t
--- response_body_like
dog
dog
--- no_error_log
[error]




=== TEST 2: id in timer
--- http_config eval
"$::HttpConfig" . q{
    lua_shared_dict ids 1m;
}
--- config
    location /t {
        content_by_lua_block {
            local ok, err = ngx.timer.at(0, function()
                local object_id = require "resty.mongol.object_id"
                ngx.shared.ids:set("timer", object_id.new():tostring())
            end)
            if not ok then ngx.say(err) return end
            ngx.sleep(0.1)
            local hex = ngx.shared.ids:get("timer")
            ngx.say(#hex, " ", hex:match("^%x+$") ~= nil)
        }
    }
--- request
GET /t
--- response_body
24 true
--- no_error_log
[error]



=== TEST 3: hex round trip
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local object_id = require "resty.mongol.object_id"
            local id = object_id.new()
            local back = object_id.new_from_hex(id:tostring())
            ngx.say(back:tostring() == id:tostring())
            ngx.say(back == id)
            ngx.say(object_id.new_from_hex("xyz"))
        }
    }
--- request
GET /t
--- response_body
true
true
nilinvalid hex string
--- no_error_log
[error]



=== TEST 4: unique across workers
--- http_config eval
"$::HttpConfig" . q{
    lua_shared_dict ids 1m;
    init_worker_by_lua_block {
        local object_id = require "resty.mongol.object_id"
        ngx.shared.ids:set(ngx.worker.id(), object_id.new():tostring())
    }
}
--- config
    location /t {
        content_by_lua_block {
            local a = ngx.shared.ids:get(0)
            local b = ngx.shared.ids:get(1)
            -- bytes 5 to 9 are hex characters 9 to 18
            ngx.say(a:sub(9, 18) ~= b:sub(9, 18))
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
[error]
