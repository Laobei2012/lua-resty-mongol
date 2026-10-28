local mod_name = (...):match ( "^(.*)%..-$" )

local pairs = pairs
local setmetatable = setmetatable
local ngx = ngx
local string = string

local md5 = require "resty.md5"
local str = require "resty.string"
local bson = require ( mod_name .. ".bson" )
local object_id = require ( mod_name .. ".object_id" )
local gridfs_file= require ( mod_name .. ".gridfs_file" )

local gridfs_mt = { }
local gridfs = { __index = gridfs_mt }
local get_bin_data = bson.get_bin_data
local get_utc_date = bson.get_utc_date

-- the document for the files collection: chunkSize is int32 and length is
-- int64, as the GridFS specification says. The table of the caller is not
-- changed.
local function files_doc(meta, length, md5_value)
    local doc = {}
    for k, v in pairs(meta) do
        doc[k] = v
    end
    doc.chunkSize = bson.int32(meta.chunkSize)
    doc.length = bson.int64(length)
    doc.md5 = md5_value
    doc.uploadDate = get_utc_date(ngx.time() * 1000)
    return doc
end

function gridfs_mt:find_one(fields)
    local r, err = self.file_col:find_one(fields)
    if not r then return nil, err end

    return setmetatable({
                    file_col = self.file_col;
                    chunk_col = self.chunk_col;
                    chunk_size = r.chunkSize;
                    files_id = r._id;
                    file_size = r.length;
                    file_md5 = r.md5;
                    file_name = r.filename;
                    }, gridfs_file)
end

function gridfs_mt:get(fh, fields)
    local f, ferr = self:find_one(fields)
    if not f then return nil, ferr or "file not found" end
    local data, err = f:read()
    if not data then return nil, err end
    local ok
    ok, err = fh:write(data)
    if not ok then return nil, err end
    return true
end

function gridfs_mt:remove(fields, continue_on_err, safe)
    local r, err
    local n = 0
    if fields == {} then
        r,err = self.chunk_col:delete({}, continue_on_err, safe)
        if not r then return nil, "remove chunks failed: "..err end
        r,err = self.file_col:delete({}, continue_on_err, safe)
        if not r then return nil, "remove files failed: "..err end
        return r
    end

    local cursor = self.file_col:find(fields, {_id=1})
    while true do
        local i, v = cursor:next()
        if not i then
            -- the end of the cursor has no second value, an error has one
            if v then return nil, v end
            break
        end
        r,err = self.chunk_col:delete({files_id=v._id}, continue_on_err, safe)
        if not r then return nil, "remove chunks failed: "..err end
        r,err = self.file_col:delete({_id=v._id}, continue_on_err, safe)
        if not r then return nil, "remove files failed: "..err end
        n = n + 1
    end
    return n
end

function gridfs_mt:new(meta)
    meta = meta or {}
    meta._id = meta._id or object_id.new()
    meta.chunkSize = meta.chunkSize or 256*1024
    meta.filename = meta.filename or meta._id:tostring()

    local r, err = self.file_col:insert({files_doc(meta, 0, 0)}, nil, true)
    if not r then return nil, err end

    return setmetatable({
                    file_col = self.file_col;
                    chunk_col = self.chunk_col;
                    chunk_size = meta.chunkSize;
                    files_id = meta._id;
                    file_size = 0;
                    file_md5 = 0;
                    file_name = meta.filename;
                    }, gridfs_file)
end

function gridfs_mt:insert(fh, meta, safe)
    meta = meta or {}
    meta.chunkSize = meta.chunkSize or 256*1024
    meta._id = meta._id or object_id.new()
    meta.filename = meta.filename or meta._id:tostring()

    local n = 0
    local length = 0
    local r, err
    local md5_obj = md5:new()
    while true do
        local bytes = fh:read(meta.chunkSize)
        if not bytes then break end

        md5_obj:update(bytes)
        r, err = self.chunk_col:insert({{ files_id = meta._id,
                                n = bson.int32(n),
                                data = get_bin_data(bytes),
                                }}, nil, safe)
        if safe and not r then return nil, err end

        n = n + 1
        length = length + string.len(bytes)
    end
    local md5hex = str.to_hex(md5_obj:final())

    r, err = self.file_col:insert({files_doc(meta, length, md5hex)}, nil, safe)
    if safe and not r then return nil, err end
    return r
end

return gridfs
