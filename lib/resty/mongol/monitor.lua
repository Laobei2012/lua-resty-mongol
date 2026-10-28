-- Command monitoring (MongoDB Command Logging and Monitoring
-- specification). The driver sends no metrics itself; an application
-- sets a monitor with mongol.set_monitor() and connects it to its own
-- metrics or logs.

local mod_name = (...):match ( "^(.*)%..-$" )

local getmetatable , setmetatable = getmetatable , setmetatable
local ipairs , pairs = ipairs , pairs
local pcall = pcall
local type = type
local strfind , strsub = string.find , string.sub
local tostring = tostring
local ngx = ngx
local ngx_now , ngx_update_time = ngx.now , ngx.update_time
local ngx_log , ngx_ERR = ngx.log , ngx.ERR

local bson = require ( mod_name .. ".bson" )
local null = bson.null
local empty_array = bson.empty_array

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

-- the name of the command is the first key of the encoded document, so
-- it is the key that goes first on the wire
local function command_name ( body )
    local z = strfind ( body , "\0" , 6 , true )
    return z and strsub ( body , 6 , z - 1 )
end

local function decode ( bytes )
    local ok , doc = pcall ( bson.decode , bytes )
    return ok and doc or { }
end

-- Decided from all the fields that are sent: the command and the fields
-- that the driver adds after it (extra).
local function is_sensitive ( name , body , extra )
    if sensitive_commands [ name ] then
        return true
    end
    if not hello_commands [ name ] then
        return false
    end
    for _ , kv in ipairs ( extra or { } ) do
        if kv [ 1 ] == "speculativeAuthenticate" then
            return true
        end
    end
    return decode ( body ).speculativeAuthenticate ~= nil
end

-- A deep copy of a reply, so that a hook cannot change what the caller
-- gets. bson.null and bson.empty_array are shared values and stay as they
-- are. The metatables come from the decoder.
local function copy ( v )
    if type ( v ) ~= "table" or v == null or v == empty_array then
        return v
    end
    local out = { }
    for k , x in pairs ( v ) do
        out [ k ] = copy ( x )
    end
    local mt = getmetatable ( v )
    if type ( mt ) == "table" then
        setmetatable ( out , mt )
    end
    return out
end

-- The command of the event is decoded from the bytes that were sent, so
-- it is a new table with no link to the tables of the caller, and it has
-- the keys that went on the wire. The kind-1 sequences are merged in under
-- their identifier.
local function command_copy ( body , seqinfo , extra )
    local out = decode ( body )
    -- the fields that the driver adds after $db: $readPreference, lsid ...
    for _ , kv in ipairs ( extra or { } ) do
        out [ kv [ 1 ] ] = copy ( kv [ 2 ] )
    end
    for _ , seq in ipairs ( seqinfo or { } ) do
        local docs = { }
        for i , bytes in ipairs ( seq [ 2 ] ) do
            docs [ i ] = decode ( bytes )
        end
        out [ seq [ 1 ] ] = docs
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
-- the end events go to the same monitor. An event is built only for a
-- handler that exists, so that a monitor with one handler pays only for
-- that handler.
function _M.started ( mon , conn , dbname , body , seqinfo , request_id , extra )
    local state = {
        mon = mon ,
        command_name = command_name ( body ) ,
        db = dbname ,
        request_id = request_id ,
        host = conn.host ,
        port = conn.port ,
    }
    if mon.started or mon.succeeded or mon.failed then
        state.sensitive = is_sensitive ( state.command_name , body , extra )
    end
    if mon.succeeded or mon.failed then
        -- the duration needs the start time
        ngx_update_time ( )
        state.start = ngx_now ( )
    end
    if mon.started then
        call ( mon , "started" , {
            command_name = state.command_name ,
            db = dbname ,
            request_id = request_id ,
            host = state.host ,
            port = state.port ,
            command = state.sensitive and { } or command_copy ( body , seqinfo , extra ) ,
        } )
    end
    return state
end

local function duration_ms ( state )
    ngx_update_time ( )
    return ( ngx_now ( ) - state.start ) * 1000
end

function _M.succeeded ( state , reply )
    if not state.mon.succeeded then
        return
    end
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
    if not state.mon.failed then
        return
    end
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
