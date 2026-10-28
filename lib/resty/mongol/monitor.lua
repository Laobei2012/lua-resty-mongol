-- Command monitoring (MongoDB Command Logging and Monitoring
-- specification). The driver sends no metrics itself; an application
-- sets a monitor with mongol.set_monitor() and connects it to its own
-- metrics or logs.

local mod_name = (...):match ( "^(.*)%..-$" )

local getmetatable , setmetatable = getmetatable , setmetatable
local ipairs , pairs = ipairs , pairs
local pcall = pcall
local type = type
local tostring = tostring
local ngx = ngx
local ngx_now , ngx_update_time = ngx.now , ngx.update_time
local ngx_log , ngx_ERR = ngx.log , ngx.ERR

local bson = require ( mod_name .. ".bson" )
local ordered_mt = bson.ordered_mt
local opairs = require ( mod_name .. ".misc" ).opairs

local _M = { }

-- the monitor of this worker, or nil. wire.lua reads it once for each
-- command.
_M.current = nil

local sensitive_commands = {
    authenticate = true , saslStart = true , saslContinue = true ,
    getnonce = true , createUser = true , updateUser = true ,
    copydbgetnonce = true , copydbsaslstart = true , copydb = true ,
}

local hello_commands = { hello = true , isMaster = true , ismaster = true }

function _M.set ( m )
    _M.current = m
end

local function command_name ( cmd )
    if getmetatable ( cmd ) == ordered_mt then
        return cmd [ 1 ] and cmd [ 1 ] [ 1 ]
    end
    local k = opairs ( cmd )
    return ( k ( cmd ) )
end

local function has_key ( cmd , key )
    if getmetatable ( cmd ) == ordered_mt then
        for _ , kv in ipairs ( cmd ) do
            if kv [ 1 ] == key then
                return true
            end
        end
        return false
    end
    return cmd [ key ] ~= nil
end

local function is_sensitive ( name , cmd )
    if sensitive_commands [ name ] then
        return true
    end
    return hello_commands [ name ] and has_key ( cmd , "speculativeAuthenticate" )
end

-- a deep copy, so that a hook cannot change the data of the driver
local function copy ( v )
    if type ( v ) ~= "table" then
        return v
    end
    local out = { }
    for k , x in pairs ( v ) do
        out [ k ] = copy ( x )
    end
    return setmetatable ( out , getmetatable ( v ) )
end

-- a copy of the command as a map; the kind-1 sequences are merged in
-- under their identifier
local function command_copy ( cmd , sequences )
    local out
    if getmetatable ( cmd ) == ordered_mt then
        out = { }
        for _ , kv in ipairs ( cmd ) do
            out [ kv [ 1 ] ] = copy ( kv [ 2 ] )
        end
    else
        out = copy ( cmd )
    end
    if sequences then
        for _ , seq in ipairs ( sequences ) do
            local docs = { }
            for i , d in ipairs ( seq [ 2 ] ) do
                if type ( d ) == "string" then
                    -- a document that is already encoded
                    local ok , doc = pcall ( bson.decode , d )
                    d = ok and doc or { }
                else
                    d = copy ( d )
                end
                docs [ i ] = d
            end
            out [ seq [ 1 ] ] = docs
        end
    end
    return out
end

local function call ( mon , name , ev )
    local f = mon [ name ]
    if not f then
        return
    end
    local ok , err = pcall ( f , ev )
    if not ok then
        ngx_log ( ngx_ERR , "mongol monitor " , name , " hook failed: " ,
                  tostring ( err ) )
    end
end

-- starts the monitoring of a command: returns the state for succeeded
-- and failed. mon is the monitor that was current when the command began;
-- the end events go to the same monitor.
function _M.started ( mon , conn , dbname , cmd , sequences , request_id )
    local name = command_name ( cmd )
    local sensitive = is_sensitive ( name , cmd )
    local state = {
        mon = mon ,
        sensitive = sensitive ,
        command_name = name ,
        db = dbname ,
        request_id = request_id ,
        host = conn.host ,
        port = conn.port ,
    }
    ngx_update_time ( )
    state.start = ngx_now ( )
    call ( mon , "started" , {
        command_name = name ,
        db = dbname ,
        request_id = request_id ,
        host = conn.host ,
        port = conn.port ,
        command = sensitive and { } or command_copy ( cmd , sequences ) ,
    } )
    return state
end

local function duration_ms ( state )
    ngx_update_time ( )
    return ( ngx_now ( ) - state.start ) * 1000
end

function _M.succeeded ( state , reply )
    call ( state.mon , "succeeded" , {
        command_name = state.command_name ,
        db = state.db ,
        request_id = state.request_id ,
        host = state.host ,
        port = state.port ,
        duration_ms = duration_ms ( state ) ,
        reply = state.sensitive and { } or copy ( reply ) ,
    } )
end

function _M.failed ( state , err )
    call ( state.mon , "failed" , {
        command_name = state.command_name ,
        db = state.db ,
        request_id = state.request_id ,
        host = state.host ,
        port = state.port ,
        duration_ms = duration_ms ( state ) ,
        error = state.sensitive and "redacted" or tostring ( err ) ,
    } )
end

return _M
