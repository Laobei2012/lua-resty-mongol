local assert = assert
local strsub = string.sub
local t_insert = table.insert
local t_concat = table.concat

local function get_from_string ( s , i )
	i = i or 1
	return function ( n )
		if not n then -- Rest of string
			n = #s - i + 1
		end
		i = i + n
		assert ( i-1 <= #s , "Unable to read enough characters" )
		return strsub ( s , i-n , i-1 )
	end , function ( new_i )
		if new_i then i = new_i end
		return i
	end
end

local function string_to_array_of_chars ( s )
	local t = { }
	for i = 1 , #s do
		t [ i ] = strsub ( s , i , i )
	end
	return t
end

local function read_terminated_string ( get , terminators )
	local terminators = string_to_array_of_chars ( terminators or "\0" )
	local str = { }
	local found = 0
	while found < #terminators do
		local c = get ( 1 )
		if c == terminators [ found + 1 ] then
			found = found + 1
		else
			found = 0
		end
		t_insert ( str , c )
	end
	return t_concat ( str , "" , 1 , #str - #terminators )
end

return {
	get_from_string = get_from_string ;
	read_terminated_string = read_terminated_string ;
}
