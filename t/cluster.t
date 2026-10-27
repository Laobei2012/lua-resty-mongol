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

=== TEST 5: is master
# TODO(Task 12): skipped until the replica set CI job starts the members on ports 27017 and 27018. Task 12 removes this skip.
--- skip_eval: 3: 1
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

            r, h = conn:ismaster()
            if not r then
                ngx.say("query master failed: "..h)
            end

            ngx.say(r)
            for i,v in pairs(h) do
                ngx.say(v)
            end
            conn:close()
        ';
    }
--- request
GET /t
--- response_body_like
true
--- no_error_log
[error]

=== TEST 6: is not master
# TODO(Task 12): skipped until the replica set CI job starts the members on ports 27017 and 27018. Task 12 removes this skip.
--- skip_eval: 3: 1
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 

            ok, err = conn:connect("127.0.0.1", 27018)
            if not ok then
                ngx.say("connect failed: "..err)
            end

            r, h = conn:ismaster()
            if r == nil then
                ngx.say("query master failed: "..h)
            end

            ngx.say(r)
            for i,v in pairs(h) do
                ngx.say(v)
            end
            conn:close()
        ';
    }
--- request
GET /t
--- response_body_like
false
--- no_error_log
[error]

=== TEST 7: get primary
# TODO(Task 12): skipped until the replica set CI job starts the members on ports 27017 and 27018. Task 12 removes this skip.
--- skip_eval: 3: 1
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua '
            local mongo = require "resty.mongol"
            conn = mongo:new()
            conn:set_timeout(1000) 

            ok, err = conn:connect("127.0.0.1", 27018)
            if not ok then
                ngx.say("connect failed: "..err)
            end

            r, h = conn:ismaster()
            if r == nil then
                ngx.say("query master failed: "..h)
            end

            if r then ngx.say("already master") return end

            newconn,err = conn:getprimary()
            if not newconn then
                ngx.say("get primary failed: "..err)
            end
            r, h = newconn:ismaster()
            if not r then
                ngx.say("get master failed")
            end

            ngx.say("get primary")
            conn:close()
        ';
    }
--- request
GET /t
--- response_body
get primary
--- no_error_log
[error]

