package = "lua-resty-mongol"
version = "1.0.0-1"

source = {
    url = "https://github.com/Laobei2012/lua-resty-mongol/archive/refs/tags/v1.0.0.tar.gz",
    dir = "lua-resty-mongol-1.0.0",
}

description = {
    summary = "MongoDB driver for OpenResty using nonblocking cosockets",
    detailed = [[
        MongoDB 6.0 through 9.0 support with OP_MSG,
        SCRAM, TLS, aggregation, replica-set reads, GridFS and transactions.
        Requires OpenResty with LuaJIT and its bundled resty libraries;
        a standalone Lua interpreter is not a supported runtime.
    ]],
    homepage = "https://github.com/Laobei2012/lua-resty-mongol",
    license = "MIT",
}

dependencies = { "lua >= 5.1, < 5.2" }

build = {
    type = "builtin",
    modules = {
        ["resty.mongol"] = "lib/resty/mongol/init.lua",
        ["resty.mongol.bson"] = "lib/resty/mongol/bson.lua",
        ["resty.mongol.colmt"] = "lib/resty/mongol/colmt.lua",
        ["resty.mongol.cursor"] = "lib/resty/mongol/cursor.lua",
        ["resty.mongol.dbmt"] = "lib/resty/mongol/dbmt.lua",
        ["resty.mongol.decimal128"] = "lib/resty/mongol/decimal128.lua",
        ["resty.mongol.get"] = "lib/resty/mongol/get.lua",
        ["resty.mongol.gridfs"] = "lib/resty/mongol/gridfs.lua",
        ["resty.mongol.gridfs_file"] = "lib/resty/mongol/gridfs_file.lua",
        ["resty.mongol.ll"] = "lib/resty/mongol/ll.lua",
        ["resty.mongol.misc"] = "lib/resty/mongol/misc.lua",
        ["resty.mongol.monitor"] = "lib/resty/mongol/monitor.lua",
        ["resty.mongol.object_id"] = "lib/resty/mongol/object_id.lua",
        ["resty.mongol.scram"] = "lib/resty/mongol/scram.lua",
        ["resty.mongol.session"] = "lib/resty/mongol/session.lua",
        ["resty.mongol.uri"] = "lib/resty/mongol/uri.lua",
        ["resty.mongol.wire"] = "lib/resty/mongol/wire.lua",
    },
}
