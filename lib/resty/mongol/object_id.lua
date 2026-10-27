local mod_name = (...):match ( "^(.*)%..-$" )

local os = os
local assert = assert

local setmetatable = setmetatable
local strbyte = string.byte
local strformat = string.format
local t_insert = table.insert
local t_concat = table.concat

local hasposix , posix = pcall ( require , "posix" )

local ll = require ( mod_name .. ".ll" )
local num_to_le_uint = ll.num_to_le_uint
local num_to_be_uint = ll.num_to_be_uint

local function _tostring(ob)
    local t = {}
    for i = 1 , 12 do
        t_insert(t, strformat("%02x", strbyte(ob.id, i, i)))
    end
    return t_concat(t)
end

local function _get_ts(ob)
    return ll.be_uint_to_num(ob.id, 1, 4)
end

local function _get_hostname(ob)
    local t = {}
    for i = 5, 7 do
        t_insert(t, strformat("%02x", strbyte(ob.id, i, i)))
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

local machineid
if hasposix then
    machineid = posix.uname("%n")
else
    machineid = assert(io.popen("uname -n")):read("*l")
end
machineid = ngx.md5_bin(machineid):sub(1, 3)

local pid = num_to_le_uint(bit.band(ngx.worker.pid(), 0xFFFF), 2)

local inc = 0
local function generate_id ( )
    inc = inc + 1
    -- 4-byte timestamp, 3-byte machine id, 2-byte process id, 3-byte
    -- counter. Timestamp and counter are big endian.
    return num_to_be_uint ( os.time ( ) , 4 ) .. machineid .. pid .. num_to_be_uint ( inc , 3 )
end

local function new_object_id(str)
    if str then
        assert(#str == 12)
    else
        str = generate_id()
    end
    return setmetatable({id = str,
                        tostring = _tostring,
                        get_ts = _get_ts,
                        get_pid = _get_pid,
                        get_hostname = _get_hostname,
                        get_inc = _get_inc,
                        } , object_id_mt)
end

return {
    new = new_object_id ;
    metatable = object_id_mt ;
}
