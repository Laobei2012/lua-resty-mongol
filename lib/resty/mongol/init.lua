local mod_name = (...)

local _M = { _VERSION = "1.0.0" }

local error = error
local ipairs = ipairs
local type = type
local setmetatable = setmetatable

local socket = ngx.socket.tcp
local new

local connmethods = { }
local connmt = { __index = connmethods }

local dbmt = require ( mod_name .. ".dbmt" )
local bson = require ( mod_name .. ".bson" )

_M.int32 = bson.int32
_M.int64 = bson.int64
_M.double = bson.double

function connmethods:ismaster()
    local db = self:new_db_handle("admin")
    local r, err = db:cmd({hello = 1})
    if not r then
        return nil, err
    end
    return r.isWritablePrimary, r.hosts
end

local function parse_host ( str )
    local host , port = str:match ( "([^:]+):?(%d*)" )
    port = port or 27017
    return host , port
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
    if self.broken then
        return nil, "closed"
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
    local pool = opts and opts.pool
    if not pool and opts and opts.ssl then
        pool = host .. ":" .. port .. ":tls:"
               .. (opts.ssl_verify == false and "noverify" or "verify") .. ":"
               .. (opts.ssl_server_name or host)
    end

    local ok, err
    if pool or (opts and (opts.pool_size or opts.backlog)) then
        ok, err = sock:connect(host, port, {
            pool = pool,
            pool_size = opts.pool_size,
            backlog = opts.backlog,
        })
    else
        ok, err = sock:connect(host, port)
    end
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

return _M
