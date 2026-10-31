-- Library for reading low level data

local ffi = require "ffi"

local unpack = unpack
local floor = math.floor
local strbyte , strchar = string.byte , string.char
local tonumber = tonumber
local type = type
local ffi_new , ffi_string , ffi_copy = ffi.new , ffi.string , ffi.copy

local le_uint_to_num = function ( s , i , j )
	i , j = i or 1 , j or #s
	if j - i == 3 and i >= 1 and j <= #s then
		local a , b , c , d = strbyte ( s , i , j )
		return a + b * 256 + c * 65536 + d * 16777216
	end
	local b = { strbyte ( s , i , j ) }
	local n = 0
	for k=#b , 1 , -1 do
		n = n*2^8 + b [ k ]
	end
	return n
end
local le_int_to_num = function ( s , i , j )
	i , j = i or 1 , j or #s
	local n = le_uint_to_num ( s , i , j )
	local bits = 8 * ( j - i + 1 )
	if n >= 2^( bits - 1 ) then
		n = n - 2^bits
	end
	return n
end
local num_to_le_uint = function ( n , bytes )
	bytes = bytes or 4
	if n < 0 or n >= 2^(8*bytes) or n ~= floor ( n ) then
		return nil , "number out of range"
	end
	if bytes == 4 then
		return strchar ( n % 256 , floor ( n / 256 ) % 256 ,
		                 floor ( n / 65536 ) % 256 , floor ( n / 16777216 ) )
	end
	local b = { }
	for i=1 , bytes do
		b [ i ] , n = n % 2^8 , floor ( n / 2^8 )
	end
	return strchar ( unpack ( b ) )
end
local num_to_le_int = function ( n , bytes )
	bytes = bytes or 4
	if n < -2^(8*bytes-1) or n >= 2^(8*bytes-1) then
		return nil , "number out of range"
	end
	if n < 0 then -- Converted to unsigned.
		n = 2^(8*bytes) + n
	end
	return num_to_le_uint ( n , bytes )
end

local be_uint_to_num = function ( s , i , j )
	i , j = i or 1 , j or #s
	local b = { strbyte ( s , i , j ) }
	local n = 0
	for k=1 , #b do
		n = n*2^8 + b [ k ]
	end
	return n
end
local num_to_be_uint = function ( n , bytes )
	bytes = bytes or 4
	if n < 0 or n >= 2^(8*bytes) or n ~= floor ( n ) then
		return nil , "number out of range"
	end
	local b = { }
	for i=bytes , 1 , -1 do
		b [ i ] , n = n % 2^8 , floor ( n / 2^8 )
	end
	return strchar ( unpack ( b ) )
end

-- Returns (as a number); bits i to j (indexed from 0)
local extract_bits = function ( s , i , j )
	j = j or i
	local i_byte = floor ( i / 8 ) + 1
	local j_byte = floor ( j / 8 ) + 1

	local n = be_uint_to_num ( s , i_byte , j_byte )
	n = n % 2^( j_byte*8 - i )
	n = floor ( n / 2^( (-(j+1) ) % 8 ) )
	return n
end

-- Look at ith bit in given string (indexed from 0)
-- Returns boolean
local le_bpeek = function ( s , bitnum )
	local byte = floor ( bitnum / 8 ) + 1
	local bit = bitnum % 8
	local char = strbyte ( s , byte )
	return floor ( ( char % 2^(bit+1) ) / 2^bit ) == 1
end

local be_bpeek = function ( s , bitnum )
	local byte = floor ( bitnum / 8 ) + 1
	local bit = 7-bitnum % 8
	local char = strbyte ( s , byte )
	return floor ( ( char % 2^(bit+1) ) / 2^bit ) == 1
end

-- the target CPUs are little-endian, so the in-memory bytes are the
-- BSON bytes
local dbuf = ffi_new ( "double[1]" )
local ibuf = ffi_new ( "int64_t[1]" )

local function to_double ( n )
	dbuf [ 0 ] = n
	return ffi_string ( dbuf , 8 )
end

local function from_double ( str , i )
	ffi_copy ( dbuf , i and str:sub ( i , i + 7 ) or str , 8 )
	return dbuf [ 0 ]
end

-- v is a whole Lua number or int64_t cdata
local function int64_to_le ( v )
	ibuf [ 0 ] = v
	return ffi_string ( ibuf , 8 )
end

-- returns a Lua number up to 2^53, int64_t cdata above that
local function le_to_int64 ( s , i )
	i = i or 1
	ffi_copy ( ibuf , s:sub ( i , i + 7 ) , 8 )
	local v = ibuf [ 0 ]
	if v >= -9007199254740992LL and v <= 9007199254740992LL then
		return tonumber ( v )
	end
	return v
end

local function is_int64 ( v )
	return type ( v ) == "cdata" and ffi.istype ( "int64_t" , v )
end

return {
	le_uint_to_num = le_uint_to_num ;
	le_int_to_num = le_int_to_num ;
	num_to_le_uint = num_to_le_uint ;
	num_to_le_int = num_to_le_int ;

	be_uint_to_num = be_uint_to_num ;
	num_to_be_uint = num_to_be_uint ;

	extract_bits = extract_bits ;

	le_bpeek = le_bpeek ;
	be_bpeek = be_bpeek ;

	to_double = to_double ;
	from_double = from_double ;

	int64_to_le = int64_to_le ;
	le_to_int64 = le_to_int64 ;
	is_int64 = is_int64 ;
}
