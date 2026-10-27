-- globalsplus.lua
-- Like globals.lua in Lua 5.1.4 but records fields in global tables too.
-- Probably works but not well tested.  Could be extended even further.
--
-- usage: luac -p -l example.lua  | lua globalsplus.lua
--
-- D.Manura, 2010-07, public domain

local function parse(line)
  local idx,linenum,opname,arga,argb,extra =
    line:match('^%s+(%d+)%s+%[(%d+)%]%s+(%w+)%s+([-%d]+)%s+([-%d]+)%s*(.*)')
  if idx then
    idx = tonumber(idx)
    linenum = tonumber(linenum)
    arga = tonumber(arga)
    argb = tonumber(argb)
  end
  local argc, const
  if extra then
    local extra2
    argc, extra2 = extra:match('^([-%d]+)%s*(.*)')
    if argc then argc = tonumber(argc); extra = extra2 end
  end
  if extra then
    const = extra:match('^; (.+)')
  end
  return {idx=idx,linenum=linenum,opname=opname,arga=arga,argb=argb,argc=argc,const=const}
end

local function getglobals(fh)
  local globals = {}
  local last
  for line in fh:lines() do
    local data = parse(line)
    if data.opname == 'GETGLOBAL' then
      data.gname = data.const
      last = data
      table.insert(globals, {linenum=last.linenum, name=data.const, isset=false})
    elseif data.opname == 'SETGLOBAL' then
      last = data
      table.insert(globals, {linenum=last.linenum, name=data.const, isset=true})
    elseif (data.opname == 'GETTABLE' or data.opname == 'SETTABLE') and last and
           last.gname and last.idx == data.idx-1 and last.arga == data.arga and data.const
    then
      local const = data.const:match('^"(.*)"')
      if const then
        data.gname = last.gname .. '.' .. const
        last = data
        table.insert(globals, {linenum=last.linenum, name=data.gname, isset=data.opname=='SETTABLE'})
      end
    else
      last = nil
    end
  end
  return globals
end

local function rindex(t, name)
  for part in name:gmatch('%w+') do
    t = t[part]
    if t == nil then return nil end
  end
  return t
end

local whitelist = _G

local globals = getglobals(io.stdin)
table.sort(globals, function(a,b) return a.linenum < b.linenum end)
for i,v in ipairs(globals) do
   local found = rindex(whitelist, v.name)
   print(v.linenum, v.name, v.isset and 'set' or 'get', found and 'defined' or 'undefined')
end
