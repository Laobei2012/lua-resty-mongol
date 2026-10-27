local mod_name = (...):match ( "^(.*)%..-$" )

local setmetatable = setmetatable
local string = string

local assert , error = assert , error
local getmetatable = getmetatable
local type = type
local tonumber , tostring = tonumber , tostring
local t_insert = table.insert
local t_concat = table.concat
local strbyte = string.byte

local ll = require ( mod_name .. ".ll" )
local le_uint_to_num = ll.le_uint_to_num
local le_int_to_num = ll.le_int_to_num
local num_to_le_uint = ll.num_to_le_uint
local num_to_le_int = ll.num_to_le_int
local from_double = ll.from_double
local to_double = ll.to_double

local opairs = require ( mod_name .. ".misc" ).opairs

local getlib = require ( mod_name .. ".get" )
local read_terminated_string = getlib.read_terminated_string

local obid = require ( mod_name .. ".object_id" )
local new_object_id = obid.new
local object_id_mt = obid.metatable
local binary_mt = {}
local utc_date = {}


local function read_document ( get , numerical )
	get ( 4 ) -- document length

	local ho , hk , hv = false , false , false
	local t = { }
	while true do
		local op = get ( 1 )
		if op == "\0" then break end

		local e_name = read_terminated_string ( get )
		local v
		if op == "\1" then -- Double
			v = from_double ( get ( 8 ) )
		elseif op == "\2" then -- String
			local len = le_uint_to_num ( get ( 4 ) )
			v = get ( len - 1 )
			assert ( get ( 1 ) == "\0" )
		elseif op == "\3" then -- Embedded document
			v = read_document ( get , false )
		elseif op == "\4" then -- Array
			v = read_document ( get , true )
		elseif op == "\5" then -- Binary
			local len = le_uint_to_num ( get ( 4 ) )
			get ( 1 ) -- subtype
			v = get ( len )
		elseif op == "\7" then -- ObjectId
			v = new_object_id ( get ( 12 ) )
		elseif op == "\8" then -- false
			local f = get ( 1 )
			if f == "\0" then
				v = false
			elseif f == "\1" then
				v = true
			else
				error ( f:byte ( ) )
			end
		elseif op == "\9" then -- UTC datetime milliseconds
			v = le_uint_to_num ( get ( 8 ) , 1 , 8 )
		elseif op == "\10" then -- Null
			v = nil
		elseif op == "\16" then --int32
			v = le_int_to_num ( get ( 4 ) , 1 , 8 )
        elseif op == "\17" then --int64
            v = le_int_to_num(get(8), 1, 8)
        elseif op == "\18" then --int64
            v = le_int_to_num(get(8), 1, 8)
		else
			error ( "Unknown BSON type: " .. strbyte ( op ) )
		end

		if numerical then
			t [ tonumber ( e_name ) ] = v
		else
			t [ e_name ] = v
		end

		-- Check for special universal map
		if e_name == "_keys" then
			hk = v
		elseif e_name == "_vals" then
			hv = v
		else
			ho = true
		end
	end

	if not ho and hk and hv then
		t = { }
			for i=1,#hk do
			t [ hk [ i ] ] = hv [ i ]
		end
	end

	return t
end

local function get_utc_date(v)
    return setmetatable({v = v}, utc_date)
end

local function get_bin_data(v)
    return setmetatable({v = v, st = "\0"}, binary_mt)
end

local function from_bson ( get )
	local t = read_document ( get , false )
	return t
end

local to_bson
local function pack ( k , v )
	local ot = type ( v )
	local mt = getmetatable ( v )

	if ot == "number" then
		return "\1" .. k .. "\0" .. to_double ( v )
	elseif ot == "nil" then
		return "\10" .. k .. "\0"
	elseif ot == "string" then
		return "\2" .. k .. "\0" .. num_to_le_uint ( #v + 1 ) .. v .. "\0"
	elseif ot == "boolean" then
		if v == false then
			return "\8" .. k .. "\0\0"
		else
			return "\8" .. k .. "\0\1"
		end
	elseif mt == object_id_mt then
		return "\7" .. k .. "\0" .. v.id
	elseif mt == utc_date then
		return "\9" .. k .. "\0" .. num_to_le_int(v.v, 8)
	elseif mt == binary_mt then
		return "\5" .. k .. "\0" .. num_to_le_uint(string.len(v.v)) ..
               v.st .. v.v
	elseif ot == "table" then
		local doc , array = to_bson(v)
		if array then
			return "\4" .. k .. "\0" .. doc
		else
			return "\3" .. k .. "\0" .. doc
		end
	else
		error ( "Failure converting " .. ot ..": " .. tostring ( v ) )
	end
end

function to_bson(ob)
	-- Find out if ob if an array; string->value map; or general table
	local onlyarray = true
	local seen_n , high_n = { } , 0
	local onlystring = true
	for k , v in opairs ( ob ) do
		local t_k = type ( k )
		onlystring = onlystring and ( t_k == "string" )
		if onlyarray then
			if t_k == "number" and k >= 0 then
				if k >= high_n then
					high_n = k
					seen_n [ k ] = v
				end
			else
				onlyarray = false
			end
		end
		if not onlyarray and not onlystring then break end
	end

	local retarray , m = false
	if onlystring then -- Do string first so the case of an empty table is done properly
		local r = { }
        for k , v in opairs ( ob ) do
--ngx.log(ngx.ERR,"="..k..i)
            t_insert ( r , pack ( k , v ) )
        end
		m = t_concat ( r )
	elseif onlyarray then
		local r = { }

		local low = 0
		--if seen_n [ 0 ] then low = 0 end
		for i=low , high_n do
			r [ i ] = pack ( i , seen_n [ i ] )
		end

		m = t_concat ( r , "" , low , high_n )
		retarray = true
	else
		local ni = 1
		local keys , vals = { } , { }
		for k , v in opairs ( ob ) do
			keys [ ni ] = k
			vals [ ni ] = v
			ni = ni + 1
		end
		return to_bson ( { _keys = keys , _vals = vals } )
	end

	return num_to_le_uint ( #m + 4 + 1 ) .. m .. "\0" , retarray
end

return {
	from_bson = from_bson ;
	to_bson = to_bson ;
    get_bin_data = get_bin_data;
    get_utc_date = get_utc_date;
}
