local mod_name = (...):match ( "^(.*)%..-$" )

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

function gridfs_mt:find_one(fields)
    local r = self.file_col:find_one(fields)
    if not r then return nil end

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
    local f = self:find_one(fields)
    if not f then return nil, "file not found" end
    local r = fh:write(f:read())
    return r
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
    for k,v in cursor:pairs() do
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

    meta.md5 = 0
    meta.uploadDate = get_utc_date(ngx.time() * 1000)
    meta.length = 0
    local r, err = self.file_col:insert({meta}, nil, true)
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
                                n = n,
                                data = get_bin_data(bytes),
                                }}, nil, safe)
        if safe and not r then return nil, err end

        n = n + 1
        length = length + string.len(bytes)
    end
    local md5hex = str.to_hex(md5_obj:final())

    meta.md5 = md5hex
    meta.uploadDate = get_utc_date(ngx.time() * 1000)
    meta.length = length
    r, err = self.file_col:insert({meta}, nil, safe)
    if safe and not r then return nil, err end
    return r
end

return gridfs
