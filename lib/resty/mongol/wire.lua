-- OP_MSG encode, decode, send and receive

local mod_name = (...):match ( "^(.*)%..-$" )

local bit = require "bit"
local band = bit.band

local ipairs = ipairs
local pcall = pcall
local type = type
local tostring = tostring
local strbyte , strfind , strsub = string.byte , string.find , string.sub
local t_concat = table.concat

local ll = require ( mod_name .. ".ll" )
local num_to_le_uint = ll.num_to_le_uint
local le_uint_to_num = ll.le_uint_to_num
local le_int_to_num = ll.le_int_to_num

local bson = require ( mod_name .. ".bson" )
local monitor = require ( mod_name .. ".monitor" )
local to_bson = bson.to_bson
local bson_append = bson.append
local bson_decode = bson.decode

local OP_MSG = 2013
local CHECKSUM_PRESENT = 1
local MORE_TO_COME = 2
-- a reply larger than this is a framing error
local MAX_REPLY_SIZE = 64 * 1024 * 1024

local _M = {
    -- the same on MongoDB 6.0 to 9.0; tests can lower them
    limits = {
        max_bson_size = 16777216 ,
        max_message_size = 48000000 ,
        max_write_batch_size = 100000 ,
    } ,
}

local request_id = 0

local function fail ( conn , err )
    local sock = conn.sock
    if sock then
        sock:close ( )
    end
    conn.broken = true
    return nil , err
end

-- builds the OP_MSG bytes; extra is a list of {key, value} pairs that
-- go after the fields of cmd, after $db. Returns the message, nil, the
-- request id, the encoded command (without $db) and, if want_info is
-- true, the encoded documents of each sequence: {{identifier, {bytes}}}.
-- The monitor reads these, so that it sees what goes on the wire.
local function encode_msg ( dbname , cmd , sequences , flags , extra , want_info )
    local body , err = to_bson ( cmd )
    if not body then
        return nil , err
    end
    local cmd_bytes = body
    local seqinfo = want_info and { } or nil
    local fields = { { "$db" , dbname } }
    if extra then
        for i = 1 , #extra do
            fields [ #fields + 1 ] = extra [ i ]
        end
    end
    body , err = bson_append ( body , fields )
    if not body then
        return nil , err
    end

    local parts = { num_to_le_uint ( flags ) , "\0" , body }
    if sequences then
        for _ , seq in ipairs ( sequences ) do
            local docs = { }
            for i , d in ipairs ( seq [ 2 ] ) do
                -- a string is a document that is already encoded
                if type ( d ) ~= "string" then
                    local derr
                    d , derr = to_bson ( d )
                    if not d then
                        return nil , derr
                    end
                end
                docs [ i ] = d
            end
            if seqinfo then
                seqinfo [ #seqinfo + 1 ] = { seq [ 1 ] , docs }
            end
            local payload = seq [ 1 ] .. "\0" .. t_concat ( docs )
            parts [ #parts + 1 ] = "\1"
            parts [ #parts + 1 ] = num_to_le_uint ( #payload + 4 )
            parts [ #parts + 1 ] = payload
        end
    end
    local msg = t_concat ( parts )
    local total = 16 + #msg
    if total > _M.limits.max_message_size then
        return nil , "message too large"
    end
    request_id = ( request_id + 1 ) % 2147483647
    return num_to_le_uint ( total ) .. num_to_le_uint ( request_id )
        .. "\0\0\0\0" .. num_to_le_uint ( OP_MSG ) .. msg , nil , request_id ,
        cmd_bytes , seqinfo
end

-- parses the bytes after the 16-byte header; returns the body document
local function decode_reply ( data )
    if #data < 5 then
        return nil , "reply too short"
    end
    local flags = le_uint_to_num ( data , 1 , 4 )
    -- bits 0 to 15 are required bits; only checksumPresent is known
    if band ( flags , 0xFFFF ) ~= band ( flags , CHECKSUM_PRESENT ) then
        return nil , "unsupported flag bits"
    end
    local last = #data
    if band ( flags , CHECKSUM_PRESENT ) ~= 0 then
        last = last - 4
    end

    local body
    local p = 5
    while p <= last do
        local kind = strbyte ( data , p )
        p = p + 1
        if p + 3 > last then
            return nil , "section past the end of the message"
        end
        local size = le_int_to_num ( data , p , p + 3 )
        if size < 5 or p + size - 1 > last then
            return nil , "section past the end of the message"
        end
        if kind == 0 then
            if body then
                return nil , "reply has more than one body section"
            end
            local ok , doc = pcall ( bson_decode , strsub ( data , p , p + size - 1 ) )
            if not ok then
                return nil , tostring ( doc )
            end
            body = doc
        elseif kind == 1 then
            local section_last = p + size - 1
            local z = strfind ( data , "\0" , p + 4 , true )
            if not z or z > section_last then
                return nil , "kind-1 section has no identifier terminator"
            end
            local q = z + 1
            while q <= section_last do
                if q + 3 > section_last then
                    return nil , "kind-1 section has a truncated document"
                end
                local dlen = le_int_to_num ( data , q , q + 3 )
                if dlen < 5 or q + dlen - 1 > section_last then
                    return nil , "bson: document length too long"
                end
                local ok , derr = pcall ( bson_decode ,
                                          strsub ( data , q , q + dlen - 1 ) )
                if not ok then
                    return nil , tostring ( derr )
                end
                q = q + dlen
            end
        else
            return nil , "unknown section kind " .. kind
        end
        p = p + size
    end
    if not body then
        return nil , "reply has no body section"
    end
    return body
end

local function receive ( conn )
    local sock = conn.sock
    local header , err = sock:receive ( 16 )
    if not header then
        return fail ( conn , err )
    end
    local len = le_int_to_num ( header , 1 , 4 )
    if len < 21 or len > MAX_REPLY_SIZE then
        return fail ( conn , "invalid message length" )
    end
    local data
    data , err = sock:receive ( len - 16 )
    if not data then
        return fail ( conn , err )
    end
    local op = le_uint_to_num ( header , 13 , 16 )
    if op ~= OP_MSG then
        return fail ( conn , "unexpected opcode " .. op )
    end
    local doc
    doc , err = decode_reply ( data )
    if not doc then
        return fail ( conn , err )
    end
    return doc
end

local function send ( conn , msg )
    local sock = conn.sock
    if not sock or conn.broken then
        return nil , "closed"
    end
    local ok , err = sock:send ( msg )
    if not ok then
        return fail ( conn , err )
    end
    return true
end

-- A connection to a secondary has read_preference set; every command on it
-- carries $readPreference, because a secondary refuses a read without it.
-- The commands on the primary connection never carry it.
local function with_read_preference ( conn , extra )
    local list = { { "$readPreference" , { mode = conn.read_preference } } }
    if extra then
        for i = 1 , #extra do
            list [ #list + 1 ] = extra [ i ]
        end
    end
    return list
end

-- sends cmd to dbname and reads the reply;
-- returns reply | nil, err, reply
-- adds the fields of a session (lsid, and for a transaction txnNumber,
-- autocommit and startTransaction) after the other extra fields
local function with_session ( session , extra )
    local list = { }
    for i = 1 , #( extra or { } ) do
        list [ i ] = extra [ i ]
    end
    for _ , kv in ipairs ( session:fields ( ) ) do
        list [ #list + 1 ] = kv
    end
    return list
end

function _M.command ( conn , dbname , cmd , sequences , extra , session )
    if conn.read_preference then
        extra = with_read_preference ( conn , extra )
    end
    if session then
        extra = with_session ( session , extra )
    end
    -- one check when no monitor is set
    local mon = monitor.current
    local msg , err , request_id , cmd_bytes , seqinfo =
        encode_msg ( dbname , cmd , sequences , 0 , extra , mon ~= nil )
    if not msg then
        return nil , err
    end
    if session then
        session:mark_sent ( )
    end
    local state = mon and monitor.started ( mon , conn , dbname , cmd_bytes ,
                                           seqinfo , request_id )
    local ok
    ok , err = send ( conn , msg )
    if not ok then
        if state then monitor.failed ( state , err ) end
        return nil , err
    end
    local reply
    reply , err = receive ( conn )
    if not reply then
        if state then monitor.failed ( state , err ) end
        return nil , err
    end
    if reply.ok ~= 1 then
        local errmsg = reply.errmsg
        if type ( errmsg ) ~= "string" then
            errmsg = "command failed"
        end
        if state then monitor.failed ( state , errmsg ) end
        return nil , errmsg , reply
    end
    if state then monitor.succeeded ( state , reply ) end
    return reply
end

-- sends cmd with moreToCome and reads no reply; for w = 0 writes
function _M.send_only ( conn , dbname , cmd , sequences , extra , session )
    if conn.read_preference then
        extra = with_read_preference ( conn , extra )
    end
    if session then
        extra = with_session ( session , extra )
    end
    local mon = monitor.current
    local msg , err , request_id , cmd_bytes , seqinfo =
        encode_msg ( dbname , cmd , sequences , MORE_TO_COME , extra , mon ~= nil )
    if not msg then
        return nil , err
    end
    if session then
        session:mark_sent ( )
    end
    local state = mon and monitor.started ( mon , conn , dbname , cmd_bytes ,
                                           seqinfo , request_id )
    local ok
    ok , err = send ( conn , msg )
    if not ok then
        if state then monitor.failed ( state , err ) end
        return nil , err
    end
    -- the server sends no reply: succeeded means that the driver sent it
    if state then monitor.succeeded ( state , { ok = 1 } ) end
    return true
end

_M.fail = fail
_M.encode_msg = encode_msg
_M.decode_reply = decode_reply

return _M
