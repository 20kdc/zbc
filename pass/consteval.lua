-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- B constant evaluator pass.
-- (Because why should the *compiler* have to do this?)
-- Also acts as a good verification pass to determine if you've 
--  forgotten to add <your favorite AST node> to the relevant backend passes.

local astlib = require("ast")
local walker = require("astwalker")

return {["run"] = function (ast, args)
 local defines = {}
 local condensechars = false
 local bigendian = false
 local indexnicer = false
 local p = 1

 -- -D: Define. Ex. -DHELLO 1
 -- -C: Condense. Ex. -C. This turns character constants into their respective integers pre-emptively, so that they be processed.
 --
 --     Notes on when it's acceptable to use this:
 --
 --        On a machine with 32-bit/24-bit/16-bit/8-bit words, 8-bit characters, and no special character translation.
 --        You can use '-B' to specify big-endian (it's little-endian as a default).
 --        Notably, the characters are always "right-adjusted":
 --        On a big-endian machine,    'AB' is 0x4142.
 --        On a little-endian machine, 'AB' is 0x4241.
 --        (This is why it's safe to use on a < 32-bit machine, and also makes sure the values are sane for single characters.)
 --
 --     Example: 
 --     Using SHIFT-JIS on ZPU is fine, so long as any translation to SHIFT-JIS is done before consteval.
 --     Otherwise, the condensed integers will still be in the pre-translation format.
 --
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
     return lhs % rhs
    end
   end
  end
 end

 local handle_rvalue = nil

 -- Used to make sure that no matter what, all rvalues are handled.
 -- This has to cover all expression AST nodes.

 handle_rvalue = function (rv)
  if indexnicer and (rv[1] == "index") then
   if #rv[3] ~= 1 then error("Multiple indices with -I @ " .. rv[4]) end
   -- Do this *before* constantization
   local o = rv[3][1]
   rv[3][1] = {"pbop", "*", o, {"int", "4", o[#o]}, o[#o]}
  end
  walker.walk_rvalue(rv, handle_rvalue)
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
 handle_statement = function (stmt)
  walker.walk_statement(stmt, handle_statement, handle_rvalue)
 end

 for _, v in ipairs(ast) do
  walker.walk_declaration(v, handle_statement, handle_rvalue)
 end
 return ast
end, ["input"] = "ast", ["output"] = "ast"}