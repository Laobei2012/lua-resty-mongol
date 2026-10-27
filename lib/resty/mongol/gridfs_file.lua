local mod_name = (...):match ( "^(.*)%..-$" )

local string = string
local math = math

local md5 = require "resty.md5"
local str = require "resty.string"
local bson = require ( mod_name .. ".bson" )

local gridfs_file_mt = { }
local gridfs_file = { __index = gridfs_file_mt }
local get_bin_data = bson.get_bin_data

-- write size bytes from the buf string into mongo, by the offset
function gridfs_file_mt:write(buf, offset, size)
    size = size or string.len(buf)
    if offset > self.file_size then return nil, "invalid offset" end
    if size > #buf then return nil, "invalid size" end

    local cn        -- number of chunks to be updated
    local af        -- number of bytes to be updated in first chunk
    local bn = 0    -- bytes number of buf already updated
    local nv = {}
    local od, t, r, err
    local of = offset % self.chunk_size
    local n = math.floor(offset/self.chunk_size)

    if of == 0 and size % self.chunk_size == 0 then
        --               chunk1 chunk2 chunk3
        -- old data      ====== ====== ======
        -- write buf            ====== ======
        --
        -- old data      ====== ====== ======
        -- write buf     ======

        cn = size/self.chunk_size
        for i = 1, cn do
            nv["$set"] = {data = get_bin_data(string.sub(buf,
                            self.chunk_size*(i-1) + 1,
                            self.chunk_size*(i-1) + self.chunk_size))}
            r, err = self.chunk_col:update({files_id = self.files_id,
                                            n = n+i-1}, nv, 1, 0, true)
            if not r then return nil,"write failed: "..err end
        end
        bn = size
    else

        if of + size > self.chunk_size then
            --               chunk1 chunk2 chunk3
            -- old data      ====== ====== ======
            -- write buf        =======
            --               ...     -> of
            --                  ...  -> af
            af = self.chunk_size - of
        else
            af = size
        end

        cn = math.ceil((size + offset)/self.chunk_size) - n
        for i = 1, cn do
            if i == 1 then
                od = self.chunk_col:find_one(
                                {files_id = self.files_id, n = n+i-1})
                if of ~= 0 and od then
                    if size + of >= self.chunk_size then
                        --               chunk1 chunk2 chunk3
                        -- old data      ====== ====== ======
                        -- write buf        =====
                        t = string.sub(od.data.v, 1, of)
                                .. string.sub(buf, 1, af)
                    else
                        --               chunk1 chunk2 chunk3
                        -- old data      ====== ====== ======
                        -- write buf        ==
                        t = string.sub(od.data.v, 1, of)
                                .. string.sub(buf, 1, af)
                                .. string.sub(od.data.v, size + of + 1)
                    end
                    bn = af
                elseif of == 0 and od then
                    if size < self.chunk_size then
                        --               chunk1 chunk2 chunk3
                        -- old data      ====== ====== ======
                        -- write buf     ===
                        t = string.sub(buf, 1)
                                .. string.sub(od.data.v, size + 1)
                        bn = bn + size
                    else
                        --               chunk1 chunk2 chunk3
                        -- old data      ====== ====== ======
                        -- write buf     =========
                        t = string.sub(buf, 1, self.chunk_size)
                        bn = bn + self.chunk_size
                    end
                else
                    t = string.sub(buf, 1, self.chunk_size)
                    bn = bn + #t --self.chunk_size
                end
                nv["$set"] = {data = get_bin_data(t)}
                r,err = self.chunk_col:update({files_id = self.files_id,
                                            n = n+i-1}, nv, 1, 0, true)
                if not r then return nil,"write failed: "..err end
            elseif i == cn then
                od = self.chunk_col:find_one(
                                {files_id = self.files_id, n = n + i - 1}
                            )
                if od then
                    t = string.sub(buf, bn + 1, size)
                                .. string.sub(od.data.v, size - bn + 1)
                else
                    t = string.sub(buf, bn + 1, size)
                end
                nv["$set"] = {data = get_bin_data(t)}
                r,err = self.chunk_col:update({files_id = self.files_id,
                                            n = n+i-1}, nv, 1, 0, true)
                if not r then return nil,"write failed: "..err end
                bn = size
            else
                nv["$set"] = {data = get_bin_data(string.sub(buf,
                                        bn + 1, bn + self.chunk_size))}
                r,err = self.chunk_col:update({files_id = self.files_id,
                                        n = n+i-1}, nv, 1, 0, true)
                if not r then return nil,"write failed: "..err end
                bn = bn + self.chunk_size
            end
        end
    end

    local nf = offset + bn
    if nf > self.file_size then
        nv["$set"] = {length = nf}
        r,err = self.file_col:update({_id = self.files_id},nv,
                        0, 0, true)
        if not r then return nil,"write failed: "..err end
    end

    nv["$set"] = {md5 = 0}
    r,err = self.file_col:update({_id = self.files_id},nv,
                        0, 0, true)
    if not r then return nil,"write failed: "..err end
    return bn
end

-- read size bytes from mongo by the offset
function gridfs_file_mt:read(size, offset)
    size = size or self.file_size
    if size < 0 then
        return nil, "invalid size"
    end
    offset = offset or 0
    if offset < 0 or offset >= self.file_size then
        return nil, "invalid offset"
    end

    local n = math.floor(offset / self.chunk_size)
    local r
    local bytes = ""
    local rn = 0
    while true do
        r = self.chunk_col:find_one({files_id = self.files_id, n = n})
        if not r then return nil, "read chunk failed" end
        if size - rn < self.chunk_size then
            bytes = bytes .. string.sub(r.data.v, 1, size - rn)
            rn = size
        else
            bytes = bytes .. r.data.v
            rn = rn + self.chunk_size
        end
        n = n + 1
        if rn >= size then break end
    end
    return bytes
end

function gridfs_file_mt:update_md5()
    local n = math.floor(self.file_size/self.chunk_size)
    local md5_obj = md5:new()
    local r, err

    for i = 0, n do
        r = self.chunk_col:find_one({files_id = self.files_id, n = i})
        if not r then return false, "read chunk failed" end

        md5_obj:update(r.data.v)
    end
    local md5hex = str.to_hex(md5_obj:final())

    local nv = {}
    nv["$set"] = {md5 = md5hex}
    self.file_md5 = md5hex
    r,err = self.file_col:update({_id = self.files_id}, nv, 0, 0, true)
    if not r then return false, "update failed: "..err end
    return true
end

return gridfs_file
