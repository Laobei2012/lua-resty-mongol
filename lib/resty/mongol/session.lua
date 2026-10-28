-- Logical sessions and transactions (MongoDB sessions and transactions
-- specifications). A transaction runs on the primary connection of the
-- session only.

local mod_name = (...):match ( "^(.*)%..-$" )

local getmetatable , setmetatable = getmetatable , setmetatable
local ipairs , unpack = ipairs , unpack
local type = type
local next = next

local resty_random = require "resty.random"

local bson = require ( mod_name .. ".bson" )
-- wire is called through the module table, so that tests can replace
-- wire.command
local wire = require ( mod_name .. ".wire" )

local _M = { }
local methods = { }
local session_mt = { __index = methods }
_M.metatable = session_mt

local UNKNOWN = "UnknownTransactionCommitResult"

-- states: none, starting (no command sent yet), in_progress, committing
-- (a commit was sent; it can be sent again), committed, aborted
local active = { starting = true , in_progress = true , committing = true }

function _M.new ( conn )
    local rnd = resty_random.bytes ( 16 , true )
    if not rnd or #rnd ~= 16 then
        return nil , "random bytes failed"
    end
    return setmetatable ( {
        conn = conn ,
        lsid = { id = bson.get_bin_data ( rnd , 4 ) } ,
        txn_number = 0 ,
        state = "none" ,
    } , session_mt )
end

function _M.is_session ( v )
    return getmetatable ( v ) == session_mt
end

-- true while the operations of the session belong to a transaction
function methods:in_transaction ( )
    return self.state == "starting" or self.state == "in_progress"
end

local function finish ( self , state )
    self.state = state
    local sessions = self.conn.active_sessions
    if sessions then
        sessions [ self ] = nil
        if next ( sessions ) == nil then
            self.conn.active_sessions = nil
        end
    end
end

-- the fields that wire.command adds to a command: an ordered list of
-- {key, value}. It does not change the command.
function methods:fields ( )
    local list = { { "lsid" , self.lsid } }
    if active [ self.state ] then
        list [ 2 ] = { "txnNumber" , bson.int64 ( self.txn_number ) }
        list [ 3 ] = { "autocommit" , false }
        if self.state == "starting" then
            list [ 4 ] = { "startTransaction" , true }
        end
    end
    return list
end

-- called after a successful send: the first command of
-- a transaction carries startTransaction, the others do not
function methods:mark_sent ( )
    if self.state == "starting" then
        self.state = "in_progress"
    end
end

function methods:start_transaction ( )
    if active [ self.state ] then
        return nil , "transaction already in progress"
    end
    self.txn_number = self.txn_number + 1
    self.state = "starting"
    local sessions = self.conn.active_sessions or { }
    sessions [ self ] = true
    self.conn.active_sessions = sessions
    return true
end

local function has_label ( doc , label )
    for _ , l in ipairs ( doc.errorLabels or { } ) do
        if l == label then
            return true
        end
    end
    return false
end

-- the commit result is unknown, so the caller can commit again
local function is_unknown ( doc )
    if doc.code == 50 or has_label ( doc , "RetryableWriteError" ) then
        return true
    end
    local wce = doc.writeConcernError
    if type ( wce ) == "table" and wce.code ~= 79 and wce.code ~= 100 then
        return true
    end
    return false
end

function methods:commit_transaction ( )
    if not active [ self.state ] then
        return nil , "no transaction in progress"
    end
    if self.state == "starting" then
        -- nothing was sent: the transaction is empty
        finish ( self , "committed" )
        return true
    end
    local cmd = { { "commitTransaction" , 1 } }
    if self.state == "committing" then
        -- a retry
        cmd [ 2 ] = { "writeConcern" , { w = "majority" , wtimeout = 10000 } }
    end
    self.state = "committing"

    local r , err , doc = wire.command ( self.conn , "admin" , bson.ordered ( cmd ) ,
                                         nil , nil , self )
    local failed , errmsg
    if r then
        local wce = r.writeConcernError
        if type ( wce ) == "table" then
            failed = r
            errmsg = wce.errmsg or "write concern error"
        end
    else
        errmsg = err
        if doc then
            failed = doc
        else
            -- a socket error or a timeout
            failed = { ok = 0 , errmsg = err , errorLabels = { UNKNOWN } }
        end
    end
    if not failed then
        finish ( self , "committed" )
        return true
    end
    if not has_label ( failed , UNKNOWN ) and is_unknown ( failed ) then
        local labels = { unpack ( failed.errorLabels or { } ) }
        labels [ #labels + 1 ] = UNKNOWN
        failed.errorLabels = labels
    end
    return nil , errmsg , failed
end

-- The session can start a new transaction after this call, whatever the
-- result: the server ends a transaction that it does not hear of again.
function methods:abort_transaction ( )
    if not active [ self.state ] then
        return nil , "no transaction in progress"
    end
    if self.state == "starting" then
        finish ( self , "aborted" )
        return true
    end
    local r , err , doc = wire.command ( self.conn , "admin" ,
                                         bson.ordered ( { { "abortTransaction" , 1 } } ) ,
                                         nil , nil , self )
    finish ( self , "aborted" )
    if not r then
        return nil , err , doc
    end
    return true
end

return _M
