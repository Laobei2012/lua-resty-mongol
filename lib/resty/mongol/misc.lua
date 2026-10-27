local getmetatable , setmetatable = getmetatable , setmetatable
local pairs = pairs
local next = next

-- pairs() that honors __pairs, without touching _G.pairs
local function opairs ( t )
    local mt = getmetatable ( t )
    if mt then
        local f = mt.__pairs
        if f then
            return f ( t )
        end
    end
    return pairs ( t )
end


local pairs_start = function ( t , sk )
    local i = 0
    return function ( t , k , v )
        i = i + 1
        local nk, nv
        if i == 1 then
            return sk, t[sk]
        elseif i == 2 then
            nk, nv = next(t)
            -- fixbug: BSON field 'OperationSessionInfo.xxx' is a duplicate field
            if sk == nk then
                nk,nv = next(t,nk)
            end
        else
            nk, nv = next(t, k)
            if sk == nk then
                nk,nv = next(t,nk)
            end
        end
        return nk,nv
    end , t
end

local function attachpairs_start ( o , k )
    local mt = getmetatable ( o )
    if not mt then
        mt = { }
        setmetatable ( o , mt )
    end
    mt.__pairs = function ( t )
        return pairs_start ( t , k )
    end
    return o
end

return {
    opairs = opairs ;
    pairs_start = pairs_start ;
    attachpairs_start = attachpairs_start ;
}

