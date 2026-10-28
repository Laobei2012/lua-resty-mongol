local mod_name = (...):match ( "^(.*)%..-$" )

local error = error
local getmetatable , setmetatable = getmetatable , setmetatable
local ipairs = ipairs
local pcall = pcall
local type = type
local tonumber , tostring = tonumber , tostring
local floor = math.floor
local ffi = require "ffi"
local strformat = string.format
local ngx = ngx
local require = require
local huge = math.huge
local strbyte , strchar , strfind , strsub = string.byte , string.char ,
                                            string.find , string.sub
local t_concat = table.concat
local t_sort = table.sort

local ll = require ( mod_name .. ".ll" )
local le_uint_to_num = ll.le_uint_to_num
local le_int_to_num = ll.le_int_to_num
local num_to_le_uint = ll.num_to_le_uint
local num_to_le_int = ll.num_to_le_int
local from_double = ll.from_double
local to_double = ll.to_double
local int64_to_le = ll.int64_to_le
local le_to_int64 = ll.le_to_int64
local is_int64 = ll.is_int64

local opairs = require ( mod_name .. ".misc" ).opairs
local decimal128 = require ( mod_name .. ".decimal128" )

local obid = require ( mod_name .. ".object_id" )
local new_object_id = obid.new
local object_id_mt = obid.metatable

local _M = { }

local binary_mt = { }
local utc_date = { }
local int32_mt = { }
local int64_mt = { }
local double_mt = { }
local timestamp_mt = { }
local ordered_mt = { }
local array_mt = { }
local decimal128_mt = { __tostring = function ( self )
    return decimal128.tostring ( self.v )
end }
local regex_mt = { }
local minkey_mt = { }
local maxkey_mt = { }
local null_mt = { __tostring = function ( ) return "null" end }

local null = setmetatable ( { } , null_mt )
local empty_array = setmetatable ( { } , {
    __newindex = function ( )
        error ( "bson.empty_array is read only" , 2 )
    end
} )

_M.null = null
_M.empty_array = empty_array
_M.array_mt = array_mt

-- Wrappers

local function check_number ( name , n )
    if type ( n ) ~= "number" and not is_int64 ( n ) then
        error ( "bad argument #1 to '" .. name .. "' (number expected)" , 3 )
    end
end

function _M.int32 ( n )
    check_number ( "int32" , n )
    if n ~= floor ( n ) or n < -2^31 or n >= 2^31 then
        error ( "bad argument #1 to 'int32' (out of range)" , 2 )
    end
    return setmetatable ( { v = n } , int32_mt )
end

function _M.int64 ( n )
    check_number ( "int64" , n )
    if type ( n ) == "number"
        and ( n ~= floor ( n ) or n < -2^63 or n >= 2^63 ) then
        error ( "bad argument #1 to 'int64' (out of range)" , 2 )
    end
    return setmetatable ( { v = n } , int64_mt )
end

function _M.double ( n )
    check_number ( "double" , n )
    return setmetatable ( { v = tonumber ( n ) } , double_mt )
end

function _M.timestamp ( t , i )
    return setmetatable ( { t = t , i = i } , timestamp_mt )
end

function _M.get_utc_date ( v )
    return setmetatable ( { v = v } , utc_date )
end

function _M.get_bin_data ( v , subtype )
    subtype = subtype or 0
    if type ( subtype ) ~= "number" or subtype < 0 or subtype > 255 then
        error ( "bad argument #2 to 'get_bin_data' (0 to 255 expected)" , 2 )
    end
    return setmetatable ( { v = v , st = strchar ( subtype ) } , binary_mt )
end

-- list is { {k1, v1}, {k2, v2}, ... }; keys are written in this order
function _M.ordered ( list )
    if type ( list ) ~= "table" then
        error ( "bad argument #1 to 'ordered' (table expected)" , 2 )
    end
    return setmetatable ( list , ordered_mt )
end

-- a Decimal128 from a decimal string; the value keeps its 16 bytes in v
function _M.decimal128 ( str )
    if type ( str ) ~= "string" then
        error ( "bad argument #1 to 'decimal128' (string expected)" , 2 )
    end
    local raw , err = decimal128.parse ( str )
    if not raw then
        return nil , err
    end
    return setmetatable ( { v = raw } , decimal128_mt )
end

-- the options are sorted, as the BSON specification wants
function _M.regex ( pattern , options )
    if type ( pattern ) ~= "string" or type ( options or "" ) ~= "string" then
        error ( "bad argument #1 to 'regex' (strings expected)" , 2 )
    end
    local chars = { }
    for c in ( options or "" ):gmatch ( "." ) do
        chars [ #chars + 1 ] = c
    end
    t_sort ( chars )
    return setmetatable ( { pattern = pattern , options = t_concat ( chars ) } ,
                          regex_mt )
end

function _M.minkey ( )
    return setmetatable ( { } , minkey_mt )
end

function _M.maxkey ( )
    return setmetatable ( { } , maxkey_mt )
end

_M.decimal128_mt = decimal128_mt
_M.regex_mt = regex_mt
_M.minkey_mt = minkey_mt
_M.maxkey_mt = maxkey_mt
_M.int32_mt = int32_mt
_M.int64_mt = int64_mt
_M.double_mt = double_mt
_M.timestamp_mt = timestamp_mt
_M.ordered_mt = ordered_mt
_M.binary_mt = binary_mt
_M.utc_date_mt = utc_date

-- Decoding

local function utf8_valid ( s )
    if not strfind ( s , "[\128-\255]" ) then
        return true
    end
    local i , n = 1 , #s
    while i <= n do
        local c = strbyte ( s , i )
        local len
        if c < 0x80 then
            len = 1
        elseif c >= 0xC2 and c <= 0xDF then
            len = 2
        elseif c >= 0xE0 and c <= 0xEF then
            len = 3
        elseif c >= 0xF0 and c <= 0xF4 then
            len = 4
        else
            return false
        end
        if i + len - 1 > n then
            return false
        end
        for k = i + 1 , i + len - 1 do
            local cc = strbyte ( s , k )
            if cc < 0x80 or cc > 0xBF then
                return false
            end
        end
        if len == 3 then
            local c2 = strbyte ( s , i + 1 )
            if ( c == 0xE0 and c2 < 0xA0 ) or ( c == 0xED and c2 > 0x9F ) then
                return false
            end
        elseif len == 4 then
            local c2 = strbyte ( s , i + 1 )
            if ( c == 0xF0 and c2 < 0x90 ) or ( c == 0xF4 and c2 > 0x8F ) then
                return false
            end
        end
        i = i + len
    end
    return true
end

local function need ( s , p , n , last )
    if p + n - 1 > last then
        error ( "bson: truncated element" , 0 )
    end
end

local read_document

-- reads one value of type op at position p; returns value, next position
local function read_value ( s , op , p , last )
    if op == 0x01 then -- Double
        need ( s , p , 8 , last )
        return from_double ( s , p ) , p + 8
    elseif op == 0x02 then -- String
        need ( s , p , 4 , last )
        local len = le_int_to_num ( s , p , p + 3 )
        if len < 1 then
            error ( "bson: bad string length" , 0 )
        end
        need ( s , p + 4 , len , last )
        if strbyte ( s , p + 4 + len - 1 ) ~= 0 then
            error ( "bson: string is not null-terminated" , 0 )
        end
        local v = strsub ( s , p + 4 , p + 4 + len - 2 )
        if not utf8_valid ( v ) then
            error ( "bson: invalid UTF-8" , 0 )
        end
        return v , p + 4 + len
    elseif op == 0x03 then -- Embedded document
        return read_document ( s , p , last , false )
    elseif op == 0x04 then -- Array
        return read_document ( s , p , last , true )
    elseif op == 0x05 then -- Binary
        need ( s , p , 5 , last )
        local len = le_int_to_num ( s , p , p + 3 )
        if len < 0 then
            error ( "bson: bad binary length" , 0 )
        end
        local st = strsub ( s , p + 4 , p + 4 )
        need ( s , p + 5 , len , last )
        local data = strsub ( s , p + 5 , p + 5 + len - 1 )
        if st == "\2" then
            if len < 4 or le_int_to_num ( data , 1 , 4 ) ~= len - 4 then
                error ( "bson: bad binary subtype 2 length" , 0 )
            end
            data = strsub ( data , 5 )
        end
        return setmetatable ( { v = data , st = st } , binary_mt ) ,
               p + 5 + len
    elseif op == 0x07 then -- ObjectId
        need ( s , p , 12 , last )
        return new_object_id ( strsub ( s , p , p + 11 ) ) , p + 12
    elseif op == 0x08 then -- Boolean
        need ( s , p , 1 , last )
        local b = strbyte ( s , p )
        if b == 0 then
            return false , p + 1
        elseif b == 1 then
            return true , p + 1
        end
        error ( "bson: invalid boolean value" , 0 )
    elseif op == 0x09 then -- UTC datetime milliseconds
        need ( s , p , 8 , last )
        return setmetatable ( { v = le_to_int64 ( s , p ) } , utc_date ) ,
               p + 8
    elseif op == 0x0B then -- Regular expression
        local z1 = strfind ( s , "\0" , p , true )
        if not z1 or z1 > last then
            error ( "bson: truncated regex" , 0 )
        end
        local z2 = strfind ( s , "\0" , z1 + 1 , true )
        if not z2 or z2 > last then
            error ( "bson: truncated regex" , 0 )
        end
        return setmetatable ( { pattern = strsub ( s , p , z1 - 1 ) ,
                                options = strsub ( s , z1 + 1 , z2 - 1 ) } ,
                              regex_mt ) , z2 + 1
    elseif op == 0x13 then -- Decimal128
        need ( s , p , 16 , last )
        return setmetatable ( { v = strsub ( s , p , p + 15 ) } ,
                              decimal128_mt ) , p + 16
    elseif op == 0x7F then -- MaxKey
        return setmetatable ( { } , maxkey_mt ) , p
    elseif op == 0xFF then -- MinKey
        return setmetatable ( { } , minkey_mt ) , p
    elseif op == 0x0A then -- Null
        return null , p
    elseif op == 0x10 then -- int32
        need ( s , p , 4 , last )
        return le_int_to_num ( s , p , p + 3 ) , p + 4
    elseif op == 0x11 then -- Timestamp
        need ( s , p , 8 , last )
        return setmetatable ( {
                i = le_uint_to_num ( s , p , p + 3 ) ,
                t = le_uint_to_num ( s , p + 4 , p + 7 ) ,
            } , timestamp_mt ) , p + 8
    elseif op == 0x12 then -- int64
        need ( s , p , 8 , last )
        return le_to_int64 ( s , p ) , p + 8
    end
    error ( "bson: unknown BSON type: " .. op , 0 )
end

-- reads a document that starts at p; `last` is the last byte that the
-- parent allows; returns the document and the position after it
function read_document ( s , p , last , is_array )
    need ( s , p , 5 , last )
    local len = le_int_to_num ( s , p , p + 3 )
    if len < 5 then
        error ( "bson: bad document length" , 0 )
    end
    local doc_last = p + len - 1
    if doc_last > last then
        error ( "bson: document length too long" , 0 )
    end
    if strbyte ( s , doc_last ) ~= 0 then
        error ( "bson: document is not null-terminated" , 0 )
    end

    local t = { }
    local q = p + 4
    while q < doc_last do
        local op = strbyte ( s , q )
        local z = strfind ( s , "\0" , q + 1 , true )
        if not z or z >= doc_last then
            error ( "bson: truncated key" , 0 )
        end
        local name = strsub ( s , q + 1 , z - 1 )
        local v
        v , q = read_value ( s , op , z + 1 , doc_last - 1 )
        if is_array then
            local k = tonumber ( name )
            if k then
                t [ k + 1 ] = v
            else
                t [ #t + 1 ] = v
            end
        else
            t [ name ] = v
        end
    end
    if q ~= doc_last then
        error ( "bson: document length too short" , 0 )
    end
    if is_array then
        setmetatable ( t , array_mt )
    end
    return t , doc_last + 1
end

-- decodes a whole string that holds exactly one document;
-- raises an error on bad input
function _M.decode ( s , p )
    p = p or 1
    local t , q = read_document ( s , p , #s , false )
    if q ~= #s + 1 then
        error ( "bson: data after the document" , 0 )
    end
    return t
end

-- reads one document through a get(n) function
function _M.from_bson ( get )
    local head = get ( 4 )
    local len = le_int_to_num ( head , 1 , 4 )
    if len < 5 then
        error ( "bson: bad document length" , 0 )
    end
    return _M.decode ( head .. get ( len - 4 ) )
end

-- Encoding

local function check_key ( k )
    if strfind ( k , "\0" , 1 , true ) then
        error ( "invalid key" , 0 )
    end
    return k
end

local encode_document

local function pack ( k , v )
    local ot = type ( v )

    if ot == "number" then
        if v == v and v ~= huge and v ~= -huge and v == floor ( v )
            and not ( v == 0 and 1 / v < 0 ) then
            if v >= -2^31 and v < 2^31 then
                return "\16" .. k .. "\0" .. num_to_le_int ( v , 4 )
            elseif v >= -2^63 and v < 2^63 then
                return "\18" .. k .. "\0" .. int64_to_le ( v )
            end
        end
        return "\1" .. k .. "\0" .. to_double ( v )
    elseif ot == "string" then
        return "\2" .. k .. "\0" .. num_to_le_uint ( #v + 1 ) .. v .. "\0"
    elseif ot == "boolean" then
        return "\8" .. k .. "\0" .. ( v and "\1" or "\0" )
    elseif ot == "cdata" then
        if is_int64 ( v ) then
            return "\18" .. k .. "\0" .. int64_to_le ( v )
        end
        error ( "unsupported cdata value" , 0 )
    elseif ot ~= "table" then
        error ( "unsupported value type " .. ot , 0 )
    end

    local mt = getmetatable ( v )
    if v == null then
        return "\10" .. k .. "\0"
    elseif mt == object_id_mt then
        return "\7" .. k .. "\0" .. v.id
    elseif mt == utc_date then
        return "\9" .. k .. "\0" .. int64_to_le ( v.v )
    elseif mt == binary_mt then
        local data = v.v
        if v.st == "\2" then
            data = num_to_le_uint ( #data ) .. data
        end
        return "\5" .. k .. "\0" .. num_to_le_uint ( #data ) .. v.st .. data
    elseif mt == int32_mt then
        return "\16" .. k .. "\0" .. num_to_le_int ( v.v , 4 )
    elseif mt == int64_mt then
        return "\18" .. k .. "\0" .. int64_to_le ( v.v )
    elseif mt == double_mt then
        return "\1" .. k .. "\0" .. to_double ( v.v )
    elseif mt == decimal128_mt then
        return "\19" .. k .. "\0" .. v.v
    elseif mt == regex_mt then
        if strfind ( v.pattern , "\0" , 1 , true )
           or strfind ( v.options , "\0" , 1 , true ) then
            error ( "invalid regex" , 0 )
        end
        return "\11" .. k .. "\0" .. v.pattern .. "\0" .. v.options .. "\0"
    elseif mt == minkey_mt then
        return "\255" .. k .. "\0"
    elseif mt == maxkey_mt then
        return "\127" .. k .. "\0"
    elseif mt == timestamp_mt then
        return "\17" .. k .. "\0" .. num_to_le_uint ( v.i , 4 )
                                 .. num_to_le_uint ( v.t , 4 )
    end
    local doc , array = encode_document ( v )
    return ( array and "\4" or "\3" ) .. k .. "\0" .. doc
end

local function finish ( r )
    local m = t_concat ( r )
    return num_to_le_uint ( #m + 5 ) .. m .. "\0"
end

-- returns the encoded document and true if it is an array
function encode_document ( ob )
    local mt = getmetatable ( ob )
    local r = { }

    if ob == empty_array then
        return finish ( r ) , true
    elseif mt == ordered_mt then
        for i , kv in ipairs ( ob ) do
            local k = kv [ 1 ]
            if type ( k ) ~= "string" then
                error ( "invalid key" , 0 )
            end
            r [ i ] = pack ( check_key ( k ) , kv [ 2 ] )
        end
        return finish ( r ) , false
    elseif mt == array_mt then
        for i = 1 , #ob do
            r [ i ] = pack ( tostring ( i - 1 ) , ob [ i ] )
        end
        return finish ( r ) , true
    end

    -- a table with keys 1 to n is an array; anything else is a document
    local n , only_index = 0 , true
    for k in opairs ( ob ) do
        n = n + 1
        if only_index and ( type ( k ) ~= "number" or k < 1
                            or k ~= floor ( k ) ) then
            only_index = false
        end
    end
    if only_index and n > 0 and ob [ n ] ~= nil then
        local ok = true
        for i = 1 , n do
            if ob [ i ] == nil then ok = false break end
        end
        if ok then
            for i = 1 , n do
                r [ i ] = pack ( tostring ( i - 1 ) , ob [ i ] )
            end
            return finish ( r ) , true
        end
    end

    for k , v in opairs ( ob ) do
        local tk = type ( k )
        if tk == "number" then
            k = tostring ( k )
        elseif tk ~= "string" then
            error ( "invalid key" , 0 )
        end
        r [ #r + 1 ] = pack ( check_key ( k ) , v )
    end
    return finish ( r ) , false
end

local function encode ( ob )
    local s = encode_document ( ob )
    return s
end

local function append ( doc , list )
    local r = { strsub ( doc , 5 , -2 ) }
    for i , kv in ipairs ( list ) do
        r [ i + 1 ] = pack ( check_key ( kv [ 1 ] ) , kv [ 2 ] )
    end
    return finish ( r )
end

-- adds the {key, value} pairs of list to the end of an encoded document
function _M.append ( doc , list )
    local ok , s = pcall ( append , doc , list )
    if not ok then
        return nil , tostring ( s )
    end
    return s
end

function _M.to_bson ( ob )
    if type ( ob ) ~= "table" then
        error ( "bad argument #1 to 'to_bson' (table expected)" , 2 )
    end
    local ok , s = pcall ( encode , ob )
    if not ok then
        if type ( s ) ~= "string" then
            s = tostring ( s )
        end
        return nil , s
    end
    return s
end

-- JSON for lua-cjson. cjson does not call metamethods and raises on
-- cdata, so to_json_safe returns a copy of the document with plain
-- values. NaN and Infinity doubles become the strings "NaN", "Infinity"
-- and "-Infinity".

-- ISO 8601 UTC string for milliseconds since 1970 (also before 1970)
local function iso_date ( ms )
    -- split in int64 arithmetic, so that a date above 2^53 keeps its
    -- milliseconds
    local ms64 = type ( ms ) == "number" and ffi.cast ( "int64_t" , floor ( ms ) )
                 or ms
    local q = ms64 / 86400000LL
    local r = ms64 % 86400000LL
    if r < 0 then
        r = r + 86400000LL
        q = q - 1
    end
    local days = tonumber ( q )
    local rem = tonumber ( r )
    -- civil date from days since 1970-01-01 (H. Hinnant)
    local z = days + 719468
    local era = floor ( z / 146097 )
    local doe = z - era * 146097
    local yoe = floor ( ( doe - floor ( doe / 1460 ) + floor ( doe / 36524 )
                          - floor ( doe / 146096 ) ) / 365 )
    local y = yoe + era * 400
    local doy = doe - ( 365 * yoe + floor ( yoe / 4 ) - floor ( yoe / 100 ) )
    local mp = floor ( ( 5 * doy + 2 ) / 153 )
    local d = doy - floor ( ( 153 * mp + 2 ) / 5 ) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then
        y = y + 1
    end
    -- years outside 0000 to 9999 have a sign and six digits (ISO 8601)
    local ys
    if y >= 0 and y <= 9999 then
        ys = strformat ( "%04d" , y )
    else
        ys = strformat ( y < 0 and "-%06d" or "+%06d" , y < 0 and -y or y )
    end
    return strformat ( "%s-%02d-%02dT%02d:%02d:%02d.%03dZ" , ys , m , d ,
                       floor ( rem / 3600000 ) , floor ( rem / 60000 ) % 60 ,
                       floor ( rem / 1000 ) % 60 , rem % 1000 )
end

local to_json

local function json_array ( cjson , t , n )
    if n == 0 then
        return setmetatable ( { } , cjson.empty_array_mt )
    end
    local out = { }
    for i = 1 , n do
        out [ i ] = to_json ( cjson , t [ i ] )
    end
    return out
end

function to_json ( cjson , v )
    local tv = type ( v )
    if tv == "cdata" then
        if is_int64 ( v ) then
            -- a string, so that no digits are lost
            return ( tostring ( v ):gsub ( "LL$" , "" ) )
        end
        return tostring ( v )
    elseif tv == "number" then
        -- cjson raises on these unless encode_invalid_numbers is set
        if v ~= v then
            return "NaN"
        elseif v == huge then
            return "Infinity"
        elseif v == -huge then
            return "-Infinity"
        end
        return v
    elseif tv ~= "table" then
        return v
    end

    local mt = getmetatable ( v )
    if v == null then
        return cjson.null
    elseif v == empty_array then
        return setmetatable ( { } , cjson.empty_array_mt )
    elseif mt == object_id_mt then
        return v:tostring ( )
    elseif mt == utc_date then
        return iso_date ( v.v )
    elseif mt == binary_mt then
        return ngx.encode_base64 ( v.v )
    elseif mt == decimal128_mt then
        return tostring ( v )
    elseif mt == timestamp_mt then
        return { t = v.t , i = v.i }
    elseif mt == regex_mt then
        return { pattern = v.pattern , options = v.options }
    elseif mt == minkey_mt then
        return "MinKey"
    elseif mt == maxkey_mt then
        return "MaxKey"
    elseif mt == int32_mt or mt == int64_mt or mt == double_mt then
        return to_json ( cjson , v.v )
    elseif mt == array_mt then
        return json_array ( cjson , v , #v )
    end

    -- a table with the keys 1 to n is an array
    local n , only_index = 0 , true
    for k in opairs ( v ) do
        n = n + 1
        if type ( k ) ~= "number" or k < 1 or k ~= floor ( k ) then
            only_index = false
        end
    end
    if only_index and n > 0 and v [ n ] ~= nil then
        return json_array ( cjson , v , n )
    end
    -- a document: the keys are strings, as in the BSON encoding. A sparse
    -- table with number keys would make cjson raise "excessively sparse
    -- array".
    local out = { }
    for k , x in opairs ( v ) do
        if type ( k ) == "number" then
            k = tostring ( k )
        end
        out [ k ] = to_json ( cjson , x )
    end
    return out
end

function _M.to_json_safe ( doc )
    if type ( doc ) ~= "table" then
        error ( "bad argument #1 to 'to_json_safe' (table expected)" , 2 )
    end
    return to_json ( require "cjson" , doc )
end

return _M
