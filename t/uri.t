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

=== TEST 1: uri parse
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local r = uri.parse("mongodb://u%40x:p@h1:1,h2/db?authSource=admin&tls=true&replicaSet=rs0")
            ngx.say(r.user, " ", r.password, " ", r.db, " ", #r.hosts)
            ngx.say(r.hosts[1].host, " ", r.hosts[1].port, " ", r.hosts[2].host, " ", r.hosts[2].port)
            ngx.say(r.options.authSource, " ", r.options.tls, " ", r.options.replicaSet, " ", r.options.readPreference)
        }
    }
--- request
GET /t
--- response_body
u@x p db 2
h1 1 h2 27017
admin true rs0 nil
--- no_error_log
[error]



=== TEST 2: uri parse: forms
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local function show(str)
                local r, err = uri.parse(str)
                if not r then ngx.say(str, " -> ", err) return end
                local hosts = {}
                for _, h in ipairs(r.hosts) do hosts[#hosts + 1] = h.host .. ":" .. h.port end
                ngx.say(str, " -> ", table.concat(hosts, ","), " ", tostring(r.db), " ", tostring(r.user), " ", tostring(r.password))
            end
            show("mongodb://h")
            show("mongodb://h:27018,h2:27019/db")
            show("mongodb://u@h")
            show("mongodb://u:p%3Aq%40r%2F@h/")
            show("mongodb://[::1]:27018/x")
            show("mongodb://h/db?authsource=a&READPREFERENCE=secondary&tls=false")
        }
    }
--- request
GET /t
--- response_body
mongodb://h -> h:27017 nil nil nil
mongodb://h:27018,h2:27019/db -> h:27018,h2:27019 db nil nil
mongodb://u@h -> h:27017 nil u nil
mongodb://u:p%3Aq%40r%2F@h/ -> h:27017 nil u p:q@r/
mongodb://[::1]:27018/x -> ::1:27018 x nil nil
mongodb://h/db?authsource=a&READPREFERENCE=secondary&tls=false -> h:27017 db nil nil
--- no_error_log
[error]



=== TEST 3: uri parse: options
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local r = uri.parse("mongodb://h/?authSource=a&readPreference=secondaryPreferred&tls=false&replicaSet=r&unknown=1")
            ngx.say(r.options.authSource, " ", r.options.readPreference, " ", tostring(r.options.tls), " ", r.options.replicaSet, " ", r.options.unknown)
        }
    }
--- request
GET /t
--- response_body
a secondaryPreferred false r nil
--- no_error_log
[error]



=== TEST 4: uri parse: bad uris
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            for _, str in ipairs({"", "http://h", "mongodb://", "mongodb:///db", "mongodb://h:abc", "mongodb://h:70000",
                    "mongodb://h:0", "mongodb://u%zz@h", "mongodb://h/db?tls=maybe", "mongodb+srv://h", "mongodb://u:p@",
                    "mongodb://u:p@ss@h", "mongodb://h1,,h2", "mongodb://u:p:q@h", "mongodb://h/db?authSource", "mongodb://[::1"}) do
                local r, err = uri.parse(str)
                ngx.say(string.format("%q", str), " ", tostring(r), " ", type(err))
            end
            ngx.say(pcall(uri.parse, 5))
        }
    }
--- request
GET /t
--- response_body
"" nil string
"http://h" nil string
"mongodb://" nil string
"mongodb:///db" nil string
"mongodb://h:abc" nil string
"mongodb://h:70000" nil string
"mongodb://h:0" nil string
"mongodb://u%zz@h" nil string
"mongodb://h/db?tls=maybe" nil string
"mongodb+srv://h" nil string
"mongodb://u:p@" nil string
"mongodb://u:p@ss@h" nil string
"mongodb://h1,,h2" nil string
"mongodb://u:p:q@h" nil string
"mongodb://h/db?authSource" nil string
"mongodb://[::1" nil string
falsebad argument #1 to 'parse' (string expected)
--- no_error_log
[error]



=== TEST 5: connect_uri on a standalone server
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local conn = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P))
            ngx.say((conn:ismaster()), " ", conn.read_conn)
            for _, mode in ipairs({"primary", "primaryPreferred", "secondaryPreferred"}) do
                local c = assert(mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=" .. mode))
                ngx.say(mode, " ", c.read_conn, " ", c:new_db_handle("test"):cmd({ping = 1}).ok)
            end
            local c, err = mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=secondary")
            ngx.say(c, " ", type(err))
            c, err = mongo.connect_uri("mongodb://" .. H .. ":" .. P .. "/?readPreference=nearest")
            ngx.say(c, " ", type(err))
        }
    }
--- request
GET /t
--- response_body
true nil
primary nil 1
primaryPreferred nil 1
secondaryPreferred nil 1
nil string
nil string
--- no_error_log
[error]



=== TEST 6: connect_uri errors
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            local c, err = mongo.connect_uri("mongodb://127.0.0.1:1")
            ngx.say(c, " ", type(err))
            c, err = mongo.connect_uri("mongodb://127.0.0.1:1,127.0.0.1:2")
            ngx.say(c, " ", type(err))
            c, err = mongo.connect_uri("nonsense")
            ngx.say(c, " ", type(err))
            ngx.say(pcall(mongo.connect_uri, 5))
            -- the second host answers
            c = assert(mongo.connect_uri("mongodb://127.0.0.1:1," .. H .. ":" .. P))
            ngx.say((c:ismaster()))
        }
    }
--- request
GET /t
--- response_body
nil string
nil string
nil string
falsebad argument #1 to 'connect_uri' (string expected)
true
--- error_log
connect() failed



=== TEST 7: uri pool names do not collide
--- http_config eval: $::HttpConfig
--- config
    location /t {
        content_by_lua_block {
            local mongo = require "resty.mongol"
            local uri = require "resty.mongol.uri"
            local bson = require "resty.mongol.bson"
            local wire = require "resty.mongol.wire"
            local H, P = "$TEST_NGINX_MONGO_HOST", $TEST_NGINX_MONGO_PORT
            local SH, SP = "$TEST_NGINX_MONGO_SECONDARY_HOST", $TEST_NGINX_MONGO_SECONDARY_PORT
            -- record the pool name that the driver passes to each connect
            local pools = {}
            local real_tcp = ngx.socket.tcp
            ngx.socket.tcp = function()
                local sock = real_tcp()
                return setmetatable({}, {__index = function(_, k)
                    if k == "connect" then
                        return function(_, h, p, o)
                            pools[#pools + 1] = o and o.pool or "default"
                            return sock:connect(h, p, o)
                        end
                    end
                    local v = sock[k]
                    if type(v) == "function" then
                        return function(_, ...) return v(sock, ...) end
                    end
                    return v
                end})
            end
            
            local function pool_of(u)
                pools = {}
                mongo.connect_uri(u)
                return pools[1]
            end
            local base = "@" .. H .. ":" .. P
            local names = {
                pool_of("mongodb://a%40b:x" .. base .. "/?authSource=c"),
                pool_of("mongodb://a:x" .. base .. "/?authSource=b%40c"),
                pool_of("mongodb://a:x" .. base .. "/?authSource=c"),
                pool_of("mongodb://a:y" .. base .. "/?authSource=c&tls=true"),
                pool_of("mongodb://" .. H .. ":" .. P),
                pool_of("mongodb://" .. H .. ":" .. P .. "/?tls=true"),
            }
            local distinct, all_user = {}, true
            for _, n in ipairs(names) do
                distinct[n] = true
                if not n:find("^user:") and not n:find("^plain:") and not n:find("^tls:") then all_user = false end
            end
            local count = 0
            for _ in pairs(distinct) do count = count + 1 end
            ngx.say(count, " ", all_user)
            ngx.say(names[1]:find("^user:") ~= nil, " ", names[3]:find("^user:") ~= nil, " ", names[4]:find("^user:") ~= nil)
            ngx.say(names[5]:find("^plain:") ~= nil, " ", names[6]:find("^tls:") ~= nil)
            -- a name from the caller never equals one of the driver
            local c = mongo:new()
            pools = {}
            c:connect(H, P, {pool = names[5]})
            ngx.say(pools[1] ~= names[5])
        }
    }
--- request
GET /t
--- response_body
6 true
true true true
true true
true
--- no_error_log
[error]
