-- mongodb:// connection strings

local error = error
local tonumber = tonumber
local type = type
local strchar = string.char
local strfind , strsub , strlower = string.find , string.sub , string.lower

local _M = { }

local option_names = {
    authsource = "authSource" ,
    tls = "tls" ,
    replicaset = "replicaSet" ,
    readpreference = "readPreference" ,
}

-- percent-decoding; a "%" that is not followed by two hex digits is an error
local function decode ( s )
    if strfind ( s , "%%%X" ) or strfind ( s , "%%%x%X" )
       or strfind ( s , "%%%x?$" ) then
        return nil , "invalid percent-encoding"
    end
    return ( s:gsub ( "%%(%x%x)" , function ( h )
        return strchar ( tonumber ( h , 16 ) )
    end ) )
end

local function parse_host ( str )
    local host , port
    if strsub ( str , 1 , 1 ) == "[" then
        local close = strfind ( str , "]" , 1 , true )
        if not close then
            return nil , "invalid host"
        end
        host = strsub ( str , 2 , close - 1 )
        local rest = strsub ( str , close + 1 )
        if rest ~= "" then
            port = rest:match ( "^:(%d+)$" )
            if not port then
                return nil , "invalid host"
            end
        end
    else
        host , port = str:match ( "^([^:]+):?(%d*)$" )
        if not host then
            return nil , "invalid host"
        end
        if port == "" then
            if strfind ( str , ":" , 1 , true ) then
                return nil , "invalid port"
            end
            port = nil
        end
    end
    if host == "" then
        return nil , "invalid host"
    end
    if port then
        port = tonumber ( port )
        if port < 1 or port > 65535 then
            return nil , "invalid port"
        end
    end
    return { host = host , port = port or 27017 }
end

-- str -> {hosts = {{host =, port =}}, db =, user =, password =,
--         options = {authSource =, tls =, replicaSet =, readPreference =}}
--      | nil, err
function _M.parse ( str )
    if type ( str ) ~= "string" then
        error ( "bad argument #1 to 'parse' (string expected)" , 2 )
    end
    local rest = str:match ( "^mongodb://(.*)$" )
    if not rest then
        if str:match ( "^mongodb%+srv://" ) then
            return nil , "mongodb+srv is not supported"
        end
        return nil , "invalid scheme"
    end

    local query
    local q = strfind ( rest , "?" , 1 , true )
    if q then
        query = strsub ( rest , q + 1 )
        rest = strsub ( rest , 1 , q - 1 )
    end
    local authority , dbpart = rest , nil
    local slash = strfind ( rest , "/" , 1 , true )
    if slash then
        authority = strsub ( rest , 1 , slash - 1 )
        dbpart = strsub ( rest , slash + 1 )
    end

    local result = { hosts = { } , options = { } }

    local _ , ats = authority:gsub ( "@" , "" )
    if ats > 1 then
        return nil , "invalid user information (escape @ as %40)"
    end
    local hostlist = authority
    if ats == 1 then
        local userinfo
        userinfo , hostlist = authority:match ( "^(.*)@(.*)$" )
        local _ , colons = userinfo:gsub ( ":" , "" )
        if colons > 1 then
            return nil , "invalid user information (escape : as %3A)"
        end
        local user , password = userinfo:match ( "^([^:]*):?(.*)$" )
        if user == "" then
            return nil , "empty user name"
        end
        local err
        result.user , err = decode ( user )
        if not result.user then
            return nil , err
        end
        if colons == 1 then
            result.password , err = decode ( password )
            if not result.password then
                return nil , err
            end
        end
    end

    if hostlist == "" then
        return nil , "no host"
    end
    -- split at commas, but not inside [ ]
    local pos = 1
    while pos <= #hostlist + 1 do
        local comma
        local bracket = strfind ( hostlist , "[" , pos , true )
        local first_comma = strfind ( hostlist , "," , pos , true )
        if bracket and ( not first_comma or bracket < first_comma ) then
            local close = strfind ( hostlist , "]" , bracket , true )
            comma = close and strfind ( hostlist , "," , close , true )
        else
            comma = first_comma
        end
        local item = strsub ( hostlist , pos , ( comma or #hostlist + 1 ) - 1 )
        local h , err = parse_host ( item )
        if not h then
            return nil , err
        end
        result.hosts [ #result.hosts + 1 ] = h
        if not comma then
            break
        end
        pos = comma + 1
    end

    if dbpart and dbpart ~= "" then
        local db , err = decode ( dbpart )
        if not db then
            return nil , err
        end
        result.db = db
    end

    if query and query ~= "" then
        for pair in query:gmatch ( "[^&]+" ) do
            local k , v = pair:match ( "^([^=]+)=(.*)$" )
            if not k then
                return nil , "invalid option"
            end
            local value , err = decode ( v )
            if not value then
                return nil , err
            end
            local name = option_names [ strlower ( k ) ]
            if name == "tls" then
                if value == "true" then
                    result.options.tls = true
                elseif value == "false" then
                    result.options.tls = false
                else
                    return nil , "invalid value for tls"
                end
            elseif name then
                result.options [ name ] = value
            end
        end
    end
    return result
end

return _M
