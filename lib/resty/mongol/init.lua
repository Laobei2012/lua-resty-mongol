local mod_name = (...)

local _M = { _VERSION = "1.0.0" }

local error = error
local ipairs = ipairs
local type = type
local tostring = tostring
local select = select
local t_concat = table.concat
local setmetatable = setmetatable

local socket = ngx.socket.tcp
local new

local connmethods = { }
local connmt = { __index = connmethods }

local dbmt = require ( mod_name .. ".dbmt" )
local bson = require ( mod_name .. ".bson" )
local monitor = require ( mod_name .. ".monitor" )
local uri = require ( mod_name .. ".uri" )
local session = require ( mod_name .. ".session" )

-- sets the command monitor of this worker (nil removes it); see monitor.lua
function _M.set_monitor(m)
    if m ~= nil and type(m) ~= "table" then
        error("bad argument #1 to 'set_monitor' (table or nil expected)", 2)
    end
    if m then
        for _, name in ipairs({"started", "succeeded", "failed"}) do
            if m[name] ~= nil and type(m[name]) ~= "function" then
                error("bad argument #1 to 'set_monitor' (" .. name
                      .. " must be a function)", 2)
            end
        end
    end
    monitor.set(m)
    return true
end

_M.int32 = bson.int32
_M.int64 = bson.int64
_M.double = bson.double

-- a logical session on this connection (the primary connection)
function connmethods:start_session()
    return session.new(self)
end

function connmethods:ismaster()
    local db = self:new_db_handle("admin")
    local r, err = db:cmd({hello = 1})
    if not r then
        return nil, err
    end
    return r.isWritablePrimary, r.hosts
end

-- "host:port" or "[ipv6]:port" as the members of hello are named; the same
-- parser as for the URI. Returns host, port | nil.
local function parse_host ( str )
    local h = uri.parse_host ( str )
    if not h then
        return nil
    end
    return h.host , h.port
end

function connmethods:getprimary ( searched )
    searched = searched or { [ self.host .. ":" .. self.port ] = true }

    -- the hosts that hello names use the TLS options of the seed, but not
    -- its pool name, which belongs to the seed
    local discovery_opts
    local sopts = self.opts
    if sopts and sopts.ssl then
        discovery_opts = {
            ssl = true,
            ssl_verify = sopts.ssl_verify,
            ssl_server_name = sopts.ssl_server_name,
        }
    end

    local db = self:new_db_handle("admin")
    local r, err = db:cmd({ hello = 1 })
    if not r then
        return nil, "query admin failed: "..err
    elseif r.isWritablePrimary then return self
    else
        for _ , v in ipairs ( r.hosts or {} ) do
            if not searched[v] then
                searched[v] = true
                local host, port = parse_host(v)
                if not host then
                    return nil, "invalid member name: " .. v
                end
                local conn = new()
                local ok, err = conn:connect(host, port, discovery_opts)
                if not ok then
                    return nil, "connect failed: "..err..v
                end

                local found = conn:getprimary(searched)
                if found ~= conn then
                    conn:close()
                end
                if found then
                    return found
                end
            end
        end
    end
    return nil , "No master server found"
end

function connmethods:databases()
    local db = self:new_db_handle("admin")
    local r, err = db:cmd({ listDatabases = 1 })
    if not r then
        return nil, err
    end
    return r.databases
end

function connmethods:shutdown()
    local db = self:new_db_handle("admin")
    local r, err = db:cmd({ shutdown = 1 })
    -- the server closes the socket when it shuts down
    if r or err == "closed" then
        return true
    end
    return nil, err
end

function connmethods:new_db_handle ( db )
    if not db then
        return nil
    end

    return setmetatable ( {
            conn = self ;
            db = db ;
        } , dbmt )
end

function connmethods:set_timeout(timeout)
    self.timeout = timeout
    local sock = self.sock
    if not sock then
        return true
    end

    return sock:settimeout(timeout)
end

function connmethods:set_keepalive(...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end
    if self.read_conn then
        self.read_conn:set_keepalive(...)
    end
    if self.broken then
        return nil, "closed"
    end
    if self.active_session then
        return nil, "transaction in progress"
    end

    return sock:setkeepalive(...)
end

function connmethods:get_reused_times()
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:getreusedtimes()
end

-- parts of a pool name, each as <length>:<text>
local function pool_key ( ... )
    local t = { }
    for i = 1 , select ( "#" , ... ) do
        local v = tostring ( ( select ( i , ... ) ) )
        t [ i ] = #v .. ":" .. v
    end
    return t_concat ( t )
end

-- opts: pool, pool_size, backlog (for the connection pool), and ssl,
-- ssl_verify (default true), ssl_server_name (default host) and
-- ssl_reused_session (for the TLS handshake). A call with no arguments
-- reuses the host, port and opts of the last successful connect.
function connmethods:connect(host, port, opts)
    if opts ~= nil and type(opts) ~= "table" then
        error("bad argument #3 to 'connect' (table expected)", 2)
    end
    if host == nil and port == nil and opts == nil then
        opts = self.opts
    end
    host = host or self.host
    port = port or self.port

    local sock = self.sock
    if not sock or self.broken then
        sock = socket()
        self.broken = nil
        if self.timeout then
            sock:settimeout(self.timeout)
        end
        self.sock = sock
    end

    -- A TLS socket that goes back to the pool is already past its
    -- handshake, so a later connect with other TLS rules would skip them.
    -- Without a pool name from the caller, the pool name holds the TLS
    -- settings.
    -- The prefixes "plain:", "tls:" and "user:" keep the three kinds of
    -- names apart, so that a name can never equal another kind, not even
    -- the cosocket default "host:port".
    -- Every part of a generated name has its length in front of it, so
    -- that two different settings never give the same name.
    local pool
    if opts and opts.pool then
        pool = "user:" .. opts.pool
    elseif opts and opts.ssl then
        pool = "tls:" .. pool_key ( host , port ,
                                    opts.ssl_verify == false and "noverify" or "verify" ,
                                    opts.ssl_server_name or host )
    else
        pool = "plain:" .. pool_key ( host , port )
    end

    local ok, err = sock:connect(host, port, {
        pool = pool,
        pool_size = opts and opts.pool_size,
        backlog = opts and opts.backlog,
    })
    if not ok then
        return nil, err
    end

    local session
    if opts and opts.ssl then
        local verify = opts.ssl_verify
        if verify == nil then
            verify = true
        end
        session, err = sock:sslhandshake(opts.ssl_reused_session,
                                         opts.ssl_server_name or host, verify)
        if not session then
            sock:close()
            return nil, err
        end
    end

    self.host, self.port, self.opts = host, port, opts
    if session then
        return ok, session
    end
    return ok
end

function connmethods:close()
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end
    if self.read_conn then
        self.read_conn:close()
    end

    return sock:close()
end

connmt.__call = connmethods.new_db_handle

new = function(self)
    return setmetatable ( {
            host = "localhost";
            port = 27017;
        } , connmt )
end

_M.new = new

local read_preferences = {
    primary = true , primaryPreferred = true ,
    secondary = true , secondaryPreferred = true ,
}

-- Connects to one host and asks hello. Returns conn, hello reply | nil, err.
-- With a user, each user has its own pool, so that a logged in socket
-- never goes to another user.
local function try_host ( u , host , port )
    local opts
    if u.options.tls then
        opts = { ssl = true }
    end
    if u.user then
        opts = opts or { }
        opts.pool = "uri:" .. pool_key ( u.user , u.auth_source , host , port ,
                                         u.options.tls and "tls" or "plain" )
    end
    local conn = new ( )
    local ok , err = conn:connect ( host , port , opts )
    if not ok then
        return nil , err
    end
    local r
    r , err = conn:new_db_handle ( "admin" ):cmd ( { hello = 1 } )
    if not r then
        conn:close ( )
        return nil , err
    end
    return conn , r
end

local function login ( u , conn )
    if not u.user then
        return true
    end
    local ok , err = conn:new_db_handle ( u.auth_source ):auth ( u.user ,
                                                              u.password or "" )
    if not ok then
        return nil , err
    end
    return true
end

-- Connects with a mongodb:// string. The connection that it returns always
-- talks to the primary: writes and db:cmd use it. For the read preferences
-- secondary and secondaryPreferred, conn.read_conn is a second connection
-- to a secondary, and the reads use it (see colmt.lua and wire.lua).
function _M.connect_uri ( str )
    if type ( str ) ~= "string" then
        error ( "bad argument #1 to 'connect_uri' (string expected)" , 2 )
    end
    local u , err = uri.parse ( str )
    if not u then
        return nil , err
    end
    local mode = u.options.readPreference or "primary"
    if not read_preferences [ mode ] then
        return nil , "unsupported readPreference: " .. mode
    end
    u.auth_source = u.options.authSource or u.db or "admin"

    -- the seeds first, then the members that hello names
    local tried = { }
    local primary , hello
    local last_err
    local function consider ( host , port )
        local key = host .. ":" .. port
        if tried [ key ] then
            return
        end
        tried [ key ] = true
        local conn , r = try_host ( u , host , port )
        if not conn then
            last_err = r
            return
        end
        if r.isWritablePrimary then
            primary , hello = conn , r
            return
        end
        conn:close ( )
        return r.hosts
    end
    for _ , h in ipairs ( u.hosts ) do
        local members = consider ( h.host , h.port )
        if primary then break end
        for _ , m in ipairs ( members or { } ) do
            local mhost , mport = parse_host ( m )
            if mhost then
                consider ( mhost , mport )
            end
            if primary then break end
        end
        if primary then break end
    end
    if not primary then
        return nil , last_err or "no primary found"
    end

    local ok
    ok , err = login ( u , primary )
    if not ok then
        primary:close ( )
        return nil , err
    end

    if mode == "secondary" or mode == "secondaryPreferred" then
        local read_conn
        for _ , m in ipairs ( hello.hosts or { } ) do
            if m ~= hello.me then
                local mhost , mport = parse_host ( m )
                local conn , r
                if mhost then
                    conn , r = try_host ( u , mhost , mport )
                end
                if conn and r.secondary then
                    read_conn = conn
                    break
                elseif conn then
                    conn:close ( )
                end
            end
        end
        if read_conn then
            ok , err = login ( u , read_conn )
            if not ok then
                read_conn:close ( )
                primary:close ( )
                return nil , err
            end
            read_conn.read_preference = mode
            primary.read_conn = read_conn
        elseif mode == "secondary" then
            primary:close ( )
            return nil , "no secondary available"
        end
    end
    return primary
end

return _M
