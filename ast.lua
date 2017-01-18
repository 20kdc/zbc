-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- AST format functions.

local ast = {}
ast.dump_mshl = function (obj, f, indent)
 local tp = type(obj)
 if obj == nil then
  f:write(indent .. "}\n")
  return
 end
 if tp == "table" then
  f:write(indent .. "{\n")
  for k, v in ipairs(obj) do
   ast.dump_mshl(v, f, indent .. " ")
  end
  f:write(indent .. "}\n")
  return
 end
 if tp == "number" then
  f:write(indent .. "%" .. obj .. "\n")
  return
 end
 if tp == "string" then
  f:write(indent .. "$" .. obj:len() .. "\t")
  f:write(obj .. "\n")
  return
 end
 if tp == "boolean" then
  local r = "N"
  if obj then r = "Y" end
  f:write(indent .. r .. "\n")
  return
 end
 error("Cannot handle object type " .. tp)
end

local read_mshl_inner = nil

read_mshl_inner = function (f, gl)
 local line = gl()
 local c = line:sub(1, 1)
 if c == "{" then
  local tbl = {}
  local p = read_mshl_inner(f, gl)
  while p ~= nil do
   table.insert(tbl, p)
   p = read_mshl_inner(f, gl)
  end
  return tbl
 end
 if c == "$" then
  local n = tonumber(line:sub(2))
  local s = f:read(n + 1)
  if s:len() ~= n + 1 then
   error("Error reading AST: Could not read whole string")
  end
  return s:sub(1, n)
 end
 if c == "%" then
  return tonumber(line:sub(2))
 end
 if c == "}" then
  return nil
 end
 if c == "Y" then
  return true
 end
 if c == "N" then
  return false
 end
 error("unknown marshalling type " .. c)
end

ast.read_mshl = function (f)
 local function gla()
  local c = f:read(1)
  local s = ""
  while true do
   if c == "\r" then error("NOPE") end
   if c == "\n" then return s end
   if c == "\t" then return s end
   if c ~= " " then
    s = s .. c
   end
   c = f:read(1)
  end
 end
 local function gl()
  local t = gla()
  while t:sub(1, 1) == ":" do
   t = gla()
  end
  return t
 end
 return read_mshl_inner(f, gl)
end

ast.parse_int = function (str)
 if str:sub(1, 1) == "0" then
  -- Octal/Zero
  local v = 0
  for i = 2, str:len() do
   v = v * 8
   v = v + (str:byte(i) - 0x30)
  end
  return v
 else
  -- Decimal
  return tonumber(str)
 end
end

-- Note that line is used for error reporting.
ast.parse_str = function (str, valid_escapes, line)
 str = str:sub(2, str:len() - 1)
 local res = ""
 while str:len() > 0 do
  local c = str:sub(1, 1)
  if c == "*" then
   local es = str:sub(1, 2)
   if es:len() ~= 2 then error("Terminated escape @ line " .. line) end
   if not valid_escapes[es] then error("Unknown escape " .. es .. " @ line " .. line) end
   res = res .. valid_escapes[es]
   str = str:sub(3)
  else
   str = str:sub(2)
   res = res .. c
  end
 end
 return res
end

local function handle_char_pusher(cr, ch, omul, odiv, nmul)
 local r = math.floor((cr * omul) / odiv)
 return r + (ch * nmul)
end
local function handle_char_leinserter(cr, ch, ip)
 local p = 1
 for i = 1, ip do
  p = p * 256
 end
end

local function handle_char(cr, ch, be, ra, ip)
 -- if BE XOR RA, then the strategy must be to OR-in characters
 -- otherwise, it must be to "push in" characters
 if be then
  if ra then
   -- right-adjust, so start at the right
   -- but big-endian, so highest must be first
   return handle_char_pusher(cr, ch, 256, 1, 1)
  else
   -- left-adjust, so start at the left
   -- but big-endian, so highest must be first
   return handle_char_leinserter(cr, ch, 3 - ip)
  end
 else
  if ra then
   -- right-adjust, so start at the right
   -- but little-endian, so lowest must be first
   return handle_char_leinserter(cr, ch, ip)
  else
   -- left-adjust, so start at the left
   -- but little-endian, so lowest must be first
   return handle_char_pusher(cr, ch, 1, 256, 0x1000000)
  end
 end
end

-- Turn an already parsed string into a bunch of integers,
--  assuming a 32-bit platform.
ast.parse_chars = function (str, line, bigendian, radjust)
 local work = {}
 local ip = 0
 local current = 0
 while str:len() > 0 do
  current = handle_char(current, str:byte(), bigendian, radjust, ip)
  str = str:sub(2)
  ip = ip + 1
  if ip == 4 then
   table.insert(work, current)
   ip = 0
  end
 end
 if ip ~= 0 then
  table.insert(work, current)
 end
 return work
end

ast.default_escapes = {
 ["*0"] = "\x00",
 ["*e"] = "\x04",
 ["*("] = "{",
 ["*)"] = "}",
 ["*t"] = "\t",
 ["**"] = "*",
 ["*'"] = "'",
 ["*\""] = "\"",
 ["*n"] = "\n"
}

return ast
