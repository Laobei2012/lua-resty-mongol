-- Shared helpers for the Test::Nginx blocks.
local _M = {}

function _M.connect(host, port, dbname)
    local mongo = require "resty.mongol"
    local conn = mongo:new()
    conn:set_timeout(10000)
    local ok, err = conn:connect(host, port)
    if not ok then
        ngx.say("connect failed: ", err)
        return ngx.exit(200)
    end
    return conn, conn:new_db_handle(dbname or "test")
end

-- a file handle for gridfs:insert that reads from a string
function _M.string_fh(s)
    local pos = 1
    return {
        read = function(_, n)
            if pos > #s then return nil end
            local chunk = s:sub(pos, pos + n - 1)
            pos = pos + n
            return chunk
        end,
    }
end

return _M
