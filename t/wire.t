# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use lib "t/lib";
use Mongol;

repeat_each(1);

plan tests => repeat_each() * (3 * blocks());

no_long_string();

run_tests();

__DATA__

=== TEST 1: hello
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            ngx.say((conn:ismaster()))
        }
    }
--- request
GET /t
--- response_body
true
--- no_error_log
[error]



=== TEST 2: cmd error
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            local r, err, doc = db:cmd({nosuchcmd = 1})
            ngx.say(r, " ", err:find("no such command", 1, true) ~= nil, " ", doc.ok)
        }
    }
--- request
GET /t
--- response_body
nil true 0
--- no_error_log
[error]



=== TEST 3: truncated reply
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("127.0.0.1", 12345)
            local r, err = db:cmd({ping = 1})
            ngx.say(r, " ", err ~= nil)
            ngx.say(conn:set_keepalive())
        }
    }
--- tcp_listen: 12345
--- tcp_reply eval
"\x26\x00\x00\x00\x01\x00\x00\x00\x00\x00"
--- request
GET /t
--- response_body
nil true
nilclosed
--- no_error_log
[error]



=== TEST 4: $db does not reorder
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            local q1, q2 = {hello = 1}, {isMaster = 1}
            ngx.say(db:cmd(q1).ok, " ", db:cmd(q2).ok)
            ngx.say(q1["$db"], " ", q2["$db"])
        }
    }
--- request
GET /t
--- response_body
1 1
nil nil
--- no_error_log
[error]



=== TEST 5: bad reply, required flag bit
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("127.0.0.1", 12345)
            local r, err = db:cmd({ping = 1})
            ngx.say(r, " ", err)
            ngx.say(conn:set_keepalive())
        }
    }
--- tcp_listen: 12345
--- tcp_reply eval
Mongol::op_msg(4, "\x00" . Mongol::ok_doc())
--- request
GET /t
--- response_body
nil unsupported flag bits
nilclosed
--- no_error_log
[error]



=== TEST 6: bad reply, section kind 2
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("127.0.0.1", 12345)
            local r, err = db:cmd({ping = 1})
            ngx.say(r, " ", err)
            ngx.say(conn:set_keepalive())
        }
    }
--- tcp_listen: 12345
--- tcp_reply eval
Mongol::op_msg(0, "\x02" . Mongol::ok_doc())
--- request
GET /t
--- response_body
nil unknown section kind 2
nilclosed
--- no_error_log
[error]



=== TEST 7: bad reply, only a kind-1 section
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("127.0.0.1", 12345)
            local r, err = db:cmd({ping = 1})
            ngx.say(r, " ", err)
            ngx.say(conn:set_keepalive())
        }
    }
--- tcp_listen: 12345
--- tcp_reply eval
Mongol::op_msg(0, "\x01" . pack("V", 4 + 2 + 17) . "d\x00" . Mongol::ok_doc())
--- request
GET /t
--- response_body
nil reply has no body section
nilclosed
--- no_error_log
[error]



=== TEST 8: optional flag bit
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("127.0.0.1", 12345)
            ngx.say(db:cmd({ping = 1}).ok)
        }
    }
--- tcp_listen: 12345
--- tcp_reply eval
Mongol::op_msg(1 << 20, "\x00" . Mongol::ok_doc())
--- request
GET /t
--- response_body
1
--- no_error_log
[error]



=== TEST 9: checksum flag
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("127.0.0.1", 12345)
            ngx.say(db:cmd({ping = 1}).ok)
        }
    }
--- tcp_listen: 12345
--- tcp_reply eval
Mongol::op_msg(1, "\x00" . Mongol::ok_doc(), "\xde\xad\xbe\xef")
--- request
GET /t
--- response_body
1
--- no_error_log
[error]



=== TEST 10: unsafe write then command
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            local ok, err = wire.send_only(conn, "test", bson.ordered{
                {"insert", "wire_unsafe"},
                {"writeConcern", {w = 0}},
            }, {{"documents", {{a = 1}}}})
            ngx.say(ok, " ", err)
            ngx.say(db:cmd({ping = 1}).ok)
        }
    }
--- request
GET /t
--- response_body
true nil
1
--- no_error_log
[error]



=== TEST 11: message too large
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local wire = require "resty.mongol.wire"
            local t = require "mongol_t"
            local conn, db = t.connect("$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT)
            local old = wire.limits.max_message_size
            wire.limits.max_message_size = 100
            ngx.say(db:cmd({ping = string.rep("x", 200)}))
            wire.limits.max_message_size = old
            ngx.say(db:cmd({ping = 1}).ok)
        }
    }
--- request
GET /t
--- response_body
nilmessage too large
1
--- no_error_log
[error]



=== TEST 12: kind-1 identifier without terminator
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("127.0.0.1", 12345)
            local r, err = db:cmd({ping = 1})
            ngx.say(r, " ", err)
            ngx.say(conn:set_keepalive())
        }
    }
--- tcp_listen: 12345
--- tcp_reply eval
Mongol::op_msg(0, "\x00" . Mongol::ok_doc() . "\x01" . pack("V", 7) . "abc")
--- request
GET /t
--- response_body
nil kind-1 section has no identifier terminator
nilclosed
--- no_error_log
[error]



=== TEST 13: kind-1 bad document
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("127.0.0.1", 12345)
            local r, err = db:cmd({ping = 1})
            ngx.say(r, " ", err)
            ngx.say(conn:set_keepalive())
        }
    }
--- tcp_listen: 12345
--- tcp_reply eval
Mongol::op_msg(0, "\x00" . Mongol::ok_doc() . "\x01" . pack("V", 4 + 2 + 5) . "d\x00" . "\x09\x00\x00\x00\x00")
--- request
GET /t
--- response_body
nil bson: document length too long
nilclosed
--- no_error_log
[error]



=== TEST 14: kind-1 valid sequence
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local t = require "mongol_t"
            local conn, db = t.connect("127.0.0.1", 12345)
            ngx.say(db:cmd({ping = 1}).ok)
        }
    }
--- tcp_listen: 12345
--- tcp_reply eval
Mongol::op_msg(0, "\x00" . Mongol::ok_doc() . "\x01" . pack("V", 4 + 2 + 17) . "d\x00" . Mongol::ok_doc())
--- request
GET /t
--- response_body
1
--- no_error_log
[error]
