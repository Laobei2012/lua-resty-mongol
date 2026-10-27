local mod_name = (...):match ( "^(.*)%..-$" )

local setmetatable = setmetatable
local strbyte = string.byte
local strchar = string.char
local strformat = string.format
local tonumber = tonumber
local type = type
local t_concat = table.concat
local floor = math.floor
local ngx_time = ngx.time
local ngx_worker_pid = ngx.worker.pid

local resty_random = require "resty.random"

local ll = require ( mod_name .. ".ll" )
local num_to_be_uint = ll.num_to_be_uint

local function _tostring(ob)
    local t = {}
    for i = 1 , 12 do
        t[i] = strformat("%02x", strbyte(ob.id, i, i))
    end
    return t_concat(t)
end

local function _get_ts(ob)
    return ll.be_uint_to_num(ob.id, 1, 4)
end

-- bytes 5 to 9 are random per process; these two getters keep the old
-- names and read the old byte ranges
local function _get_hostname(ob)
    local t = {}
    for i = 5, 7 do
        t[#t + 1] = strformat("%02x", strbyte(ob.id, i, i))
    end
    return t_concat(t)
end

local function _get_pid(ob)
    return ll.be_uint_to_num(ob.id, 8, 9)
end

local function _get_inc(ob)
    return ll.be_uint_to_num(ob.id, 10, 12)
end

local object_id_mt = {
    __tostring = _tostring;
    __eq = function ( a , b ) return a.id == b.id end ;
}

-- the random value and the counter are made on the first id in each
-- process, so that forked workers never share them
local process_pid, process_rand, inc

local function generate_id ( )
    local pid = ngx_worker_pid()
    if pid ~= process_pid then
        local rand = resty_random.bytes(5)
        if not rand or #rand ~= 5 then
            return nil, "random bytes failed"
        end
        local c = resty_random.bytes(3)
        if not c or #c ~= 3 then
            return nil, "random bytes failed"
        end
        process_rand = rand
        inc = ll.be_uint_to_num(c, 1, 3)
        process_pid = pid
    end
    inc = (inc + 1) % 0x1000000
    return num_to_be_uint ( floor(ngx_time()) , 4 ) .. process_rand
        .. num_to_be_uint ( inc , 3 )
end

local function new_object_id(str)
    if str then
        if #str ~= 12 then
            return nil, "invalid object id"
        end
    else
        local err
        str, err = generate_id()
        if not str then
            return nil, err
        end
    end
    return setmetatable({id = str,
                        tostring = _tostring,
                        get_ts = _get_ts,
                        get_pid = _get_pid,
                        get_hostname = _get_hostname,
                        get_inc = _get_inc,
                        } , object_id_mt)
end

local function new_from_hex(hex)
    if type(hex) ~= "string" or #hex ~= 24 or not hex:match("^%x+$") then
        return nil, "invalid hex string"
    end
    local b = {}
    for i = 1, 12 do
        b[i] = strchar(tonumber(hex:sub(2 * i - 1, 2 * i), 16))
    end
    return new_object_id(t_concat(b))
end

return {
    new = new_object_id ;
    new_from_hex = new_from_hex ;
    metatable = object_id_mt ;
}
