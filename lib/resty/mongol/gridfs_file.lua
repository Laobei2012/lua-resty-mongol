local mod_name = (...):match ( "^(.*)%..-$" )

local string = string
local type = type
local error = error
local math = math
local table = table

local md5 = require "resty.md5"
local str = require "resty.string"
local bson = require ( mod_name .. ".bson" )

local gridfs_file_mt = { }
local gridfs_file = { __index = gridfs_file_mt }
local get_bin_data = bson.get_bin_data

-- write size bytes from the buf string into mongo, by the offset.
-- Chunks that exist are updated, so the bytes around the written range
-- stay. Chunks that do not exist yet are inserted with one col:insert,
-- which splits them into batches that fit the server limits.
function gridfs_file_mt:write(buf, offset, size)
    if type(buf) ~= "string" then
        error("bad argument #1 to 'write' (string expected)", 2)
    end
    if type(offset) ~= "number" or offset ~= math.floor(offset) then
        error("bad argument #2 to 'write' (whole number expected)", 2)
    end
    if size ~= nil and (type(size) ~= "number" or size ~= math.floor(size)) then
        error("bad argument #3 to 'write' (whole number expected)", 2)
    end
    size = size or string.len(buf)
    if offset < 0 or offset > self.file_size then return nil, "invalid offset" end
    if size < 0 or size > #buf then return nil, "invalid size" end
    if size == 0 then return 0 end

    local cs = self.chunk_size
    local first = math.floor(offset / cs)
    local last = math.floor((offset + size - 1) / cs)

    local ok, ierr = self.bucket:ensure_indexes()
    if not ok then return nil, ierr end

    -- the chunks that exist in the range
    local old = {}
    local cursor = self.chunk_col:find({files_id = self.files_id,
                                        n = {["$gte"] = first, ["$lte"] = last}})
    while true do
        local i, doc = cursor:next()
        if not i then
            -- the end of the cursor has no second value, an error has one
            if doc then return nil, doc end
            break
        end
        old[doc.n] = doc.data.v
    end

    local inserts = {}
    local r, err
    for n = first, last do
        local chunk_start = n * cs
        local lo = math.max(offset, chunk_start)
        local hi = math.min(offset + size, chunk_start + cs)
        local piece = string.sub(buf, lo - offset + 1, hi - offset)
        local before = old[n]
        local data
        if before then
            -- keep the bytes before and after the written range
            data = string.sub(before, 1, lo - chunk_start) .. piece
                   .. string.sub(before, hi - chunk_start + 1)
            r, err = self.chunk_col:update({files_id = self.files_id, n = n},
                        {["$set"] = {data = get_bin_data(data)}}, 0, 0, true)
            if not r then return nil, "write failed: " .. err end
            if r == 0 then
                -- the chunk was removed after we read it
                return nil, "write failed: chunk " .. n .. " is gone"
            end
        else
            inserts[#inserts + 1] = {files_id = self.files_id,
                                     n = bson.int32(n),
                                     data = get_bin_data(piece)}
        end
    end
    if #inserts > 0 then
        r, err = self.chunk_col:insert(inserts, nil, true)
        if not r then return nil, "write failed: " .. err end
    end

    -- The stored length only grows ($max), even if this handle has an old
    -- file size. The md5 is not valid any more, so it is removed.
    local new_size = offset + size
    r, err = self.file_col:update({_id = self.files_id},
                {["$max"] = {length = bson.int64(new_size)},
                 ["$unset"] = {md5 = ""}}, 0, 0, true)
    if not r then return nil, "write failed: " .. err end
    if r == 0 then
        return nil, "write failed: the files document is gone"
    end
    if new_size > self.file_size then
        self.file_size = new_size
    end
    self.file_md5 = nil
    return size
end

-- Loads the data of chunk n and checks it as the GridFS specification
-- wants: the chunk exists, its data is binary, and its length is the chunk
-- size (the rest of the file for the last chunk).
local function load_chunk(self, n)
    local r, err = self.chunk_col:find_one({files_id = self.files_id, n = n})
    if not r then return nil, err or "read chunk failed" end
    local data = r.data
    if type(data) ~= "table" or type(data.v) ~= "string" then
        return nil, "chunk " .. n .. " is not binary data"
    end
    local cs = self.chunk_size
    local last = math.ceil(self.file_size / cs) - 1
    local expected = (n == last) and (self.file_size - n * cs) or cs
    if #data.v ~= expected then
        return nil, "chunk " .. n .. " has the wrong length: " .. #data.v
                    .. " instead of " .. expected
    end
    return data.v
end

-- read size bytes from mongo by the offset; size defaults to the rest of
-- the file and is cut at the end of the file
function gridfs_file_mt:read(size, offset)
    offset = offset or 0
    if offset == 0 and self.file_size == 0 and (size == nil or size >= 0) then
        return ""
    end
    if offset < 0 or offset >= self.file_size then
        return nil, "invalid offset"
    end
    size = size or self.file_size - offset
    if size < 0 then
        return nil, "invalid size"
    end
    if size > self.file_size - offset then
        size = self.file_size - offset
    end
    if size == 0 then
        return ""
    end

    local cs = self.chunk_size
    local first = math.floor(offset / cs)
    local last = math.floor((offset + size - 1) / cs)
    local parts = {}
    for n = first, last do
        local data, err = load_chunk(self, n)
        if not data then return nil, err end
        -- the part of this chunk inside the range
        local from = (n == first) and (offset - n * cs) or 0
        local to = (n == last) and (offset + size - n * cs) or cs
        parts[#parts + 1] = string.sub(data, from + 1, to)
    end
    return table.concat(parts)
end

function gridfs_file_mt:update_md5()
    -- the chunks 0 to ceil(length / chunk size) - 1
    local n = math.ceil(self.file_size / self.chunk_size)
    local md5_obj = md5:new()
    local r, err

    for i = 0, n - 1 do
        local data
        data, err = load_chunk(self, i)
        if not data then return false, err end

        md5_obj:update(data)
    end
    local md5hex = str.to_hex(md5_obj:final())

    local nv = {}
    nv["$set"] = {md5 = md5hex}
    r,err = self.file_col:update({_id = self.files_id}, nv, 0, 0, true)
    if not r then return false, "update failed: "..err end
    self.file_md5 = md5hex
    return true
end

return gridfs_file
