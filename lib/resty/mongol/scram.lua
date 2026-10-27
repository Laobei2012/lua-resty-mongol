-- SCRAM-SHA-1 and SCRAM-SHA-256 (RFC 5802, RFC 7677)

local mod_name = (...):match ( "^(.*)%..-$" )

local ffi = require "ffi"
local bit = require "bit"
local bxor = bit.bxor

local pcall = pcall
local type = type
local tonumber = tonumber
local strbyte , strchar , strrep = string.byte , string.char , string.rep
local strfind , strsub = string.find , string.sub
local t_concat = table.concat
local ngx = ngx
local encode_base64 , decode_base64 = ngx.encode_base64 , ngx.decode_base64
local ngx_md5 = ngx.md5

local resty_random = require "resty.random"
local resty_sha1 = require "resty.sha1"
local resty_sha256 = require "resty.sha256"
local resty_string = require "resty.string"

local bson = require ( mod_name .. ".bson" )
local wire = require ( mod_name .. ".wire" )

local _M = { }

local mechanisms = {
    ["SCRAM-SHA-1"] = { len = 20 , evp = "EVP_sha1" , new = resty_sha1 } ,
    ["SCRAM-SHA-256"] = { len = 32 , evp = "EVP_sha256" , new = resty_sha256 } ,
}

local function hash ( mech , s )
    local h = mechanisms [ mech ].new:new ( )
    h:update ( s )
    return h:final ( )
end

local function xor_bytes ( a , b )
    local t = { }
    for i = 1 , #a do
        t [ i ] = strchar ( bxor ( strbyte ( a , i ) , strbyte ( b , i ) ) )
    end
    return t_concat ( t )
end

-- HMAC and PBKDF2 in the OpenSSL that nginx links. At 15,000 iterations
-- a pure Lua PBKDF2 costs too much worker CPU. The Lua code below is the
-- fallback if the symbols are missing.
local C = ffi.C
local ffi_ok = pcall ( ffi.cdef , [[
const void *EVP_sha1(void);
const void *EVP_sha256(void);
int PKCS5_PBKDF2_HMAC(const char *pass, int passlen,
                      const unsigned char *salt, int saltlen, int iter,
                      const void *digest, int keylen, unsigned char *out);
unsigned char *HMAC(const void *evp_md, const void *key, int key_len,
                    const unsigned char *d, size_t n,
                    unsigned char *md, unsigned int *md_len);
]] )

local ffi_state -- nil: not probed, true: works, false: missing

local function ffi_pbkdf2 ( mech , password , salt , iter )
    local m = mechanisms [ mech ]
    local out = ffi.new ( "unsigned char[?]" , m.len )
    local md = C [ m.evp ] ( )
    local ok = C.PKCS5_PBKDF2_HMAC ( password , #password , salt , #salt , iter ,
                                     md , m.len , out )
    if ok ~= 1 then
        return nil
    end
    return ffi.string ( out , m.len )
end

local function ffi_hmac ( mech , key , data )
    local m = mechanisms [ mech ]
    local out = ffi.new ( "unsigned char[?]" , 64 )
    local outlen = ffi.new ( "unsigned int[1]" )
    local md = C [ m.evp ] ( )
    local r = C.HMAC ( md , key , #key , data , #data , out , outlen )
    if r == nil then
        return nil
    end
    return ffi.string ( out , outlen [ 0 ] )
end

-- RFC 2104 HMAC over a hash with a 64-byte block
local function pure_hmac ( mech , key , data )
    if #key > 64 then
        key = hash ( mech , key )
    end
    key = key .. strrep ( "\0" , 64 - #key )
    local ipad , opad = { } , { }
    for i = 1 , 64 do
        local b = strbyte ( key , i )
        ipad [ i ] = strchar ( bxor ( b , 0x36 ) )
        opad [ i ] = strchar ( bxor ( b , 0x5c ) )
    end
    return hash ( mech , t_concat ( opad ) ..
                         hash ( mech , t_concat ( ipad ) .. data ) )
end

-- RFC 8018 PBKDF2 with one output block (the key length is the hash length)
local function pure_pbkdf2 ( mech , password , salt , iter )
    local u = pure_hmac ( mech , password , salt .. "\0\0\0\1" )
    local acc = u
    for _ = 2 , iter do
        u = pure_hmac ( mech , password , u )
        acc = xor_bytes ( acc , u )
    end
    return acc
end

-- the RFC 6070 test vector for PBKDF2-HMAC-SHA1
local function probe ( )
    local ok , r = pcall ( ffi_pbkdf2 , "SCRAM-SHA-1" , "password" , "salt" , 2 )
    if not ok or not r then
        return false
    end
    local hex = resty_string.to_hex ( r )
    if hex ~= "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957" then
        return false
    end
    local ok2 , h = pcall ( ffi_hmac , "SCRAM-SHA-1" , "key" , "data" )
    return ok2 and h == pure_hmac ( "SCRAM-SHA-1" , "key" , "data" )
end

local function use_ffi ( )
    if _M.force_pure or not ffi_ok then
        return false
    end
    if ffi_state == nil then
        ffi_state = probe ( )
    end
    return ffi_state
end

local function hmac ( mech , key , data )
    if use_ffi ( ) then
        local r = ffi_hmac ( mech , key , data )
        if r then
            return r
        end
    end
    return pure_hmac ( mech , key , data )
end

local function pbkdf2 ( mech , password , salt , iter )
    if use_ffi ( ) then
        local r = ffi_pbkdf2 ( mech , password , salt , iter )
        if r then
            return r
        end
    end
    return pure_pbkdf2 ( mech , password , salt , iter )
end

-- salted passwords, so that pooled connections skip PBKDF2
local cache = { }
local cache_size = 0
local CACHE_MAX = 1000

local function salted_password ( mech , user , password , salt_b64 , iter )
    local key = t_concat ( { mech , user ,
                             resty_string.to_hex ( hash ( "SCRAM-SHA-256" , password ) ) ,
                             salt_b64 , iter } , "\0" )
    local salted = cache [ key ]
    if not salted then
        salted = pbkdf2 ( mech , password , decode_base64 ( salt_b64 ) , iter )
        if cache_size >= CACHE_MAX then
            cache , cache_size = { } , 0
        end
        cache [ key ] = salted
        cache_size = cache_size + 1
    end
    return salted
end

-- returns the client proof and the server signature, both in base64;
-- password is the string that goes into PBKDF2
function _M._proof ( mech , password , salt_b64 , iter , auth_message , user )
    local salted = salted_password ( mech , user or "" , password , salt_b64 , iter )
    local client_key = hmac ( mech , salted , "Client Key" )
    local stored_key = hash ( mech , client_key )
    local client_sig = hmac ( mech , stored_key , auth_message )
    local server_key = hmac ( mech , salted , "Server Key" )
    local server_sig = hmac ( mech , server_key , auth_message )
    return encode_base64 ( xor_bytes ( client_key , client_sig ) ) ,
           encode_base64 ( server_sig )
end

-- SASLprep (RFC 4013) for ASCII. Other characters need the full
-- stringprep tables, which are not implemented.
local function saslprep ( password )
    if strfind ( password , "[\128-\255]" ) then
        return nil , "non-ASCII password not supported"
    end
    if strfind ( password , "[%c]" ) then
        return nil , "password has prohibited characters"
    end
    return password
end

local function parse ( msg )
    local t = { }
    for k , v in msg:gmatch ( "([%a])=([^,]*)" ) do
        t [ k ] = v
    end
    return t
end

local function payload_of ( reply )
    local p = reply.payload
    if type ( p ) == "table" then
        return p.v
    end
    if type ( p ) == "string" then
        return decode_base64 ( p )
    end
end

local function bin ( s )
    return bson.get_bin_data ( s )
end

function _M.authenticate ( conn , dbname , user , password , mechanism )
    local m = mechanisms [ mechanism ]
    if not m then
        return nil , "unknown mechanism"
    end
    local pw
    if mechanism == "SCRAM-SHA-1" then
        pw = ngx_md5 ( user .. ":mongo:" .. password )
    else
        local err
        pw , err = saslprep ( password )
        if not pw then
            return nil , err
        end
    end

    local rnd = resty_random.bytes ( 24 , true )
    if not rnd or #rnd ~= 24 then
        return nil , "random bytes failed"
    end
    local nonce = encode_base64 ( rnd )
    local esc = user:gsub ( "=" , "=3D" ):gsub ( "," , "=2C" )
    local first_bare = "n=" .. esc .. ",r=" .. nonce

    local reply , err = wire.command ( conn , dbname , bson.ordered ( {
        { "saslStart" , 1 } ,
        { "mechanism" , mechanism } ,
        { "payload" , bin ( "n,," .. first_bare ) } ,
        { "autoAuthorize" , 1 } ,
        { "options" , { skipEmptyExchange = true } } ,
    } ) )
    if not reply then
        return nil , err
    end

    local server_first = payload_of ( reply )
    if not server_first then
        return nil , "bad server reply"
    end
    local sf = parse ( server_first )
    local iter = tonumber ( sf.i )
    if not sf.r or not sf.s or not iter or iter < 1 or iter ~= iter - iter % 1 then
        return nil , "bad server reply"
    end
    if strsub ( sf.r , 1 , #nonce ) ~= nonce then
        return nil , "server nonce mismatch"
    end

    local without_proof = "c=biws,r=" .. sf.r
    local auth_message = first_bare .. "," .. server_first .. "," .. without_proof
    local proof , server_sig = _M._proof ( mechanism , pw , sf.s , iter ,
                                           auth_message , user )
    local final = without_proof .. ",p=" .. proof

    reply , err = wire.command ( conn , dbname , bson.ordered ( {
        { "saslContinue" , 1 } ,
        { "conversationId" , reply.conversationId } ,
        { "payload" , bin ( final ) } ,
    } ) )
    if not reply then
        return nil , err
    end

    local server_final = payload_of ( reply )
    local v = server_final and parse ( server_final ).v
    if v ~= server_sig then
        return nil , "server signature mismatch"
    end

    -- without skipEmptyExchange the server waits for an empty message
    local tries = 0
    while not reply.done do
        tries = tries + 1
        if tries > 2 then
            return nil , "SASL conversation failed to complete"
        end
        reply , err = wire.command ( conn , dbname , bson.ordered ( {
            { "saslContinue" , 1 } ,
            { "conversationId" , reply.conversationId } ,
            { "payload" , bin ( "" ) } ,
        } ) )
        if not reply then
            return nil , err
        end
    end
    return true
end

_M.mechanisms = { "SCRAM-SHA-256" , "SCRAM-SHA-1" }

return _M
