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

-- a get function over a string, for bson.from_bson
function _M.get(s)
    return require("resty.mongol.get").get_from_string(s)
end

-- list the top elements of an encoded document: {type, name, value}
-- value is the raw bytes of a sub document or array
function _M.elements(s)
    local ll = require "resty.mongol.ll"
    local out = {}
    local p = 5
    while p < #s do
        local ty = s:byte(p)
        local z = s:find("\0", p + 1, true)
        local name = s:sub(p + 1, z - 1)
        p = z + 1
        local len
        if ty == 3 or ty == 4 then
            len = ll.le_uint_to_num(s, p, p + 3)
        elseif ty == 2 then
            len = 4 + ll.le_uint_to_num(s, p, p + 3)
        elseif ty == 5 then
            len = 5 + ll.le_uint_to_num(s, p, p + 3)
        elseif ty == 16 then
            len = 4
        elseif ty == 1 or ty == 9 or ty == 17 or ty == 18 then
            len = 8
        elseif ty == 7 then
            len = 12
        elseif ty == 8 then
            len = 1
        else
            len = 0
        end
        out[#out + 1] = {type = ty, name = name, value = s:sub(p, p + len - 1)}
        p = p + len
    end
    return out
end

-- bytes from a hex string; spaces are ignored
function _M.hexbytes(h)
    h = h:gsub("%s", "")
    return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end))
end

return _M
