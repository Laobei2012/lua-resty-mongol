-- Decimal128 (BID encoding) from and to strings, as the BSON Decimal128
-- specification describes it. A value is 16 bytes, least significant
-- byte first.

local floor = math.floor
local strbyte , strchar , strrep = string.byte , string.char , string.rep
local strsub , strfind , strlower = string.sub , string.find , string.lower
local t_concat = table.concat
local tonumber = tonumber
local unpack = unpack

local _M = { }

local BIAS = 6176
local EMAX = 6111
local EMIN = -6176
local MAX_DIGITS = 34

local function from_parts ( neg , digits , e )
    local b = { }
    for i = 1 , 16 do
        b [ i ] = 0
    end
    -- the coefficient: b = b * 10 + digit
    for i = 1 , #digits do
        local carry = strbyte ( digits , i ) - 48
        for j = 1 , 16 do
            local v = b [ j ] * 10 + carry
            b [ j ] = v % 256
            carry = floor ( v / 256 )
        end
    end
    -- the biased exponent has 14 bits, from bit 113 up
    local E = e + BIAS
    b [ 15 ] = b [ 15 ] + ( E % 128 ) * 2
    b [ 16 ] = floor ( E / 128 ) + ( neg and 128 or 0 )
    return strchar ( unpack ( b ) )
end

local function special ( top , neg )
    local b = strrep ( "\0" , 15 ) .. strchar ( top + ( neg and 128 or 0 ) )
    return b
end

-- a decimal string to 16 bytes | nil, err
function _M.parse ( str )
    local sign , rest = str:match ( "^([+-]?)(.*)$" )
    local neg = sign == "-"
    local lower = strlower ( rest )
    if lower == "inf" or lower == "infinity" then
        return special ( 0x78 , neg )
    elseif lower == "nan" then
        return special ( 0x7c , neg )
    elseif lower == "snan" then
        return special ( 0x7e , neg )
    end

    local mant , exp = rest , 0
    local ePos = strfind ( rest , "[eE]" )
    if ePos then
        mant = strsub ( rest , 1 , ePos - 1 )
        local es = strsub ( rest , ePos + 1 )
        if not es:match ( "^[+-]?%d+$" ) then
            return nil , "invalid decimal128 string"
        end
        exp = tonumber ( es )
    end
    local int_part , frac_part = mant:match ( "^(%d*)%.?(%d*)$" )
    if not int_part or int_part == "" and frac_part == "" then
        return nil , "invalid decimal128 string"
    end

    local digits = ( int_part .. frac_part ):gsub ( "^0+" , "" )
    local e = exp - #frac_part
    if digits == "" then
        -- zero: clamp the exponent
        if e > EMAX then
            e = EMAX
        elseif e < EMIN then
            e = EMIN
        end
        return from_parts ( neg , "0" , e )
    end

    -- more than 34 digits: only trailing zeros may go
    while #digits > MAX_DIGITS and strsub ( digits , -1 ) == "0" do
        digits = strsub ( digits , 1 , -2 )
        e = e + 1
    end
    if #digits > MAX_DIGITS then
        return nil , "decimal128 value is inexact"
    end
    -- too large an exponent: pad the coefficient with zeros
    while e > EMAX and #digits < MAX_DIGITS do
        digits = digits .. "0"
        e = e - 1
    end
    if e > EMAX then
        return nil , "decimal128 overflow"
    end
    -- too small an exponent: drop trailing zeros
    while e < EMIN and #digits > 1 and strsub ( digits , -1 ) == "0" do
        digits = strsub ( digits , 1 , -2 )
        e = e + 1
    end
    if e < EMIN then
        return nil , "decimal128 underflow"
    end
    return from_parts ( neg , digits , e )
end

-- 16 bytes to the decimal string
function _M.tostring ( raw )
    local b = { strbyte ( raw , 1 , 16 ) }
    local top = b [ 16 ]
    local neg = top >= 128
    local c5 = floor ( ( top % 128 ) / 4 )
    if c5 == 31 then
        return "NaN"
    elseif c5 == 30 then
        return neg and "-Infinity" or "Infinity"
    end

    local E
    if top % 128 >= 96 then
        -- not a canonical form: the coefficient is 0
        E = floor ( b [ 14 ] / 128 ) + b [ 15 ] * 2 + ( top % 32 ) * 512
        for i = 1 , 16 do
            b [ i ] = 0
        end
    else
        E = floor ( b [ 15 ] / 2 ) + ( top % 128 ) * 128
        b [ 15 ] = b [ 15 ] % 2
        b [ 16 ] = 0
    end
    local e = E - BIAS

    -- the coefficient to decimal digits: divide by 10 until it is 0
    local rev = { }
    while true do
        local zero = true
        local carry = 0
        for j = 15 , 1 , -1 do
            local v = carry * 256 + b [ j ]
            b [ j ] = floor ( v / 10 )
            carry = v % 10
            if b [ j ] ~= 0 then zero = false end
        end
        rev [ #rev + 1 ] = carry
        if zero then break end
    end
    local digits = { }
    for i = #rev , 1 , -1 do
        digits [ #digits + 1 ] = rev [ i ]
    end
    local s = t_concat ( digits )
    if #s > MAX_DIGITS then
        -- a coefficient above 10^34 - 1 is read as 0
        s = "0"
    end

    local n = #s
    local sci = e + n - 1
    local out
    if e > 0 or sci < -6 then
        out = strsub ( s , 1 , 1 )
        if n > 1 then
            out = out .. "." .. strsub ( s , 2 )
        end
        out = out .. "E" .. ( sci >= 0 and "+" or "-" ) .. ( sci >= 0 and sci or -sci )
    elseif e == 0 then
        out = s
    elseif n > -e then
        out = strsub ( s , 1 , n + e ) .. "." .. strsub ( s , n + e + 1 )
    else
        out = "0." .. strrep ( "0" , -e - n ) .. s
    end
    return ( neg and "-" or "" ) .. out
end

return _M
