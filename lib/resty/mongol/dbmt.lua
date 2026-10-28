local mod_name = (...):match ( "^(.*)%..-$" )

local ipairs = ipairs
local type = type
local setmetatable = setmetatable

local colmt = require ( mod_name .. ".colmt" )
local wire = require ( mod_name .. ".wire" )
local bson = require ( mod_name .. ".bson" )
local gridfs = require ( mod_name .. ".gridfs" )
local cursor = require ( mod_name .. ".cursor" )
local scram = require ( mod_name .. ".scram" )

local dbmethods = { }
local dbmt = { __index = dbmethods }

function dbmethods:cmd(q)
    return wire.command(self.conn, self.db, q)
end

function dbmethods:listcollections ( num_each )
    local r, err = wire.command(self.conn, self.db, bson.ordered({
        { "listCollections" , 1 } ,
        { "cursor" , num_each and { batchSize = num_each } or { } } ,
    }))
    if not r then
        return nil, err
    end
    return cursor.from_reply(self:get_col("$cmd"), r.cursor, num_each)
end

dbmethods.list = dbmethods.listcollections

function dbmethods:dropDatabase ( )
    local r, err = self:cmd({ dropDatabase = 1 })
    if not r then
        return nil, err
    end
    return 1
end

function dbmethods:add_user ( username , password )
    local r, err = self:cmd(bson.ordered({
        { "createUser" , username } ,
        { "pwd" , password } ,
        { "roles" , bson.empty_array } ,
    }))
    if not r then
        return nil, err
    end
    return r
end

-- logs in with the best mechanism that the server lists for the user:
-- SCRAM-SHA-256 if listed, else SCRAM-SHA-1
function dbmethods:auth(username, password)
    local r, err = self:cmd(bson.ordered({
        { "hello" , 1 } ,
        { "saslSupportedMechs" , self.db .. "." .. username } ,
    }))
    if not r then
        return nil, err
    end
    local mechanism = "SCRAM-SHA-256"
    local list = r.saslSupportedMechs
    if type(list) == "table" and #list > 0 then
        mechanism = "SCRAM-SHA-1"
        for _, m in ipairs(list) do
            if m == "SCRAM-SHA-256" then
                mechanism = m
                break
            end
        end
    end
    local ok
    ok, err = scram.authenticate(self.conn, self.db, username, password,
                                 mechanism)
    if not ok then
        return nil, err
    end
    return 1
end

-- keeps the old name; always uses SCRAM-SHA-1
function dbmethods:auth_scram_sha1(username, password)
    local ok, err = scram.authenticate(self.conn, self.db, username, password,
                                       "SCRAM-SHA-1")
    if not ok then
        return nil, err
    end
    return 1
end

function dbmethods:get_col(collection)
    if not collection then
        return nil, "collection needed"
    end

    return setmetatable ( {
            conn = self.conn;
            db_obj = self;
            db = self.db ;
            col = collection;
        } , colmt )
end

function dbmethods:get_gridfs(fs)
    if not fs then
        return nil, "fs name needed"
    end

    return setmetatable({
            conn = self.conn;
            db_obj = self;
            db = self.db;
            file_col = self:get_col(fs..".files");
            chunk_col = self:get_col(fs..".chunks");
        } , gridfs)
end

return dbmt
