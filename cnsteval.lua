-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- B constant evaluator pass.
-- (Because why should the *compiler* have to do this?)
-- Also acts as a good verification pass to determine if you've 
--  forgotten to add <your favorite AST node> to the relevant backend passes.

local astlib = require("ast")
local ast = astlib.read_mshl(io.stdin)

local defines = {}
local condensechars = false
local bigendian = false
local indexnicer = false
local args = {...}
local p = 1

-- -D: Define. Ex. -DHELLO 1
-- -C: Condense. Ex. -C
-- -B: Big-endian (used by Condense). Ex. -C -B
-- -I: Index multiply by WORD_VALS. Ex. -DWORD_VALS 4 -I
--     This is a compatibility setting,
--      so when code using indexes hits the compiler,
--      any required index multiplication is already done.

while p < #args do
 local arg = args[p]
 if arg:sub(1, 2) == "-D" then
  defines[arg:sub(2)] = astlib.parse_int(args[p + 1])
  p = p + 2
 else
  if arg:sub(1, 2) == "-C" then
   condensechars = true
   p = p + 1
  else
   if arg:sub(1, 2) == "-B" then
    bigendian = true
    p = p + 1
   else
    if arg:sub(1, 2) == "-I" then
     indexnicer = true
     p = p + 1
    else
     error("argument unknown: " .. arg)
    end
   end
  end
 end
end

-- Handle one particular rvalue's calculation if possible.
-- This only has to cover the things the constant evaluator performs.
local function try_calc(rv)
 if rv[1] == "char" then
  local r = astlib.parse_str(rv[2], astlib.default_escapes, rv[3])
  r = astlib.parse_chars(r, rv[3], bigendian, true)
  if #r > 1 then error("Character constant does not fit in char @ line " .. rv[3]) end
  return r[1]
 end
 if rv[1] == "int" then
  return astlib.parse_int(rv[2])
 end
 if rv[1] == "id" then
  if defines[rv[2]] then
   return defines[rv[2]]
  end
 end
 if rv[1] == "arglist(" then
  if (#rv[2]) ~= 1 then
   error("Subexpr with comma @ " .. rv[3])
  end
  return try_calc(rv[2][1])
 end
 if rv[1] == "puop" then
  if not rv[4] then
   local n = try_calc(rv[3])
   if n then
    if rv[2] == "-" then
     return -n
    end
    if rv[2] == "~" then
     return -(n + 1)
    end
   end
  end
 end
 if rv[1] == "pbop" then
  local lhs = try_calc(rv[3])
  local rhs = try_calc(rv[4])
  if lhs and rhs then
   if rv[2] == "+" then
    return lhs + rhs
   end
   if rv[2] == "-" then
    return lhs - rhs
   end
   if rv[2] == "*" then
    return lhs * rhs
   end
   if rv[2] == "/" then
    local v = lhs / rhs
    if lhs < 0 then
     v = math.ceil(v)
    else
     v = math.floor(v)
    end
    return v
   end
   if rv[2] == "%" then
    return lhs / rhs
   end
  end
 end
end

local handle_rvalue = nil

-- Used to make sure that no matter what, all rvalues are handled.
-- This has to cover all expression AST nodes.

local function handle_more_rvalues(rv)
 if rv[1] == "int" then return end
 if rv[1] == "id" then return end
 if rv[1] == "char" then return end
 if rv[1] == "string" then return end

 if rv[1] == "puop" then
  handle_rvalue(rv[3])
  return
 end
 if rv[1] == "pbop" then
  handle_rvalue(rv[3])
  handle_rvalue(rv[4])
  return
 end
 if rv[1] == "ptop" then
  handle_rvalue(rv[3])
  handle_rvalue(rv[4])
  handle_rvalue(rv[5])
  return
 end
 if (rv[1] == "arglist(") or (rv[1] == "arglist[") then
  for _, v in ipairs(rv[2]) do
   handle_rvalue(v)
  end
  return
 end
 if (rv[1] == "call") or (rv[1] == "index") then
  if indexnicer and (rv[1] == "index") then
   if #rv[3] ~= 1 then error("Multiple indices with -I @ " .. rv[4]) end
   -- Do this *before* constantization
   local o = rv[3][1]
   rv[3][1] = {"pbop", "*", o, {"int", "4", o[#o]}, o[#o]}
  end
  handle_rvalue(rv[2])
  for _, v in ipairs(rv[3]) do
   handle_rvalue(v)
  end
  return
 end
 error("IDK how to handle " .. rv[1] .. " @ " .. rv[#rv])
end

handle_rvalue = function (rv)
 handle_more_rvalues(rv)
 local r = try_calc(rv)
 if r then
  -- overwrite the instance
  local line = rv[#rv]
  for k, v in pairs(rv) do
   rv[k] = nil
  end
  if r >= 0 then
   rv[1] = "int"
   rv[2] = tostring(r)
   rv[3] = line
  else
   rv[1] = "puop"
   rv[2] = "-"
   rv[3] = {"int", tostring(-r), line}
   rv[4] = false
   rv[5] = line
  end
 end
end

local handle_statement = nil

-- This must handle every statement.
handle_statement = function (stmt)
 if stmt[1] == "compound" then
  for _, v in ipairs(stmt[2]) do
   handle_statement(v)
  end
  return
 end
 if stmt[1] == "extrn" then
  return
 end
 if stmt[1] == "auto" then
  for _, v in ipairs(stmt[2]) do
   if v[3] then
    handle_rvalue(v[3])
   end
  end
  return
 end
 if stmt[1] == "rvalue" then
  handle_rvalue(stmt[2])
  return
 end
 if stmt[1] == "label" then
  handle_statement(stmt[3])
  return
 end
 if stmt[1] == "break" then
  return
 end
 if stmt[1] == "return_void" then
  return
 end
 if stmt[1] == "return" then
  handle_rvalue(stmt[2])
  return
 end
 if stmt[1] == "goto" then
  handle_rvalue(stmt[2])
  return
 end
 if stmt[1] == "case" then
  handle_rvalue(stmt[2])
  handle_statement(stmt[3])
  return
 end
 if (stmt[1] == "if") or (stmt[1] == "switch") or (stmt[1] == "while") then
  handle_rvalue(stmt[2])
  handle_statement(stmt[3])
  return
 end
 if stmt[1] == "if_else" then
  handle_rvalue(stmt[2])
  handle_statement(stmt[3])
  handle_statement(stmt[4])
  return
 end
 error("IDK statement " .. stmt[1] .. " @ " .. stmt[#stmt])
end

local function handle_declaration(def)
 if def[1] == "function" then
  handle_statement(def[4])
 end
 if def[1] == "vecdef" then
  handle_rvalue(def[3])
  for _, v in ipairs(def[4]) do
   handle_rvalue(v)
  end
 end
 if def[1] == "vardef" then
  for _, v in ipairs(def[3]) do
   handle_rvalue(v)
  end
 end
end

for _, v in ipairs(ast) do
 handle_declaration(v)
end

astlib.dump_mshl(ast, io.stdout, "")
