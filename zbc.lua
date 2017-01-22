-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- ZBC. A B compiler for the modern world. (Maybe.)
-- This is just the "driver" program.
-- It takes an input,
--  interprets it in whatever format a pass expects,
--  runs that pass on it,
--  then spits out an output.
-- For ZPU work, if you prefer a long form, use:
-- zbc.lua core.lex < input.b > work.tkn
-- zbc.lua core.par < work.tkn > work.ast
-- zbc.lua pass.consteval -DWORD_CHARS 4 -DWORD_VALS 4 -I -C -B < work.ast > work2.ast
-- zbc.lua output.zpu < work2.ast > out.S
--  or the following single line:
-- zbc.lua core.lex -- core.par -- cnsteval -DWORD_CHARS 4 -DWORD_VALS 4 -I -C -B -- output.zpu < input.b > out.S

local args = {...}

local tokenSubset = nil
tokenSubset = function (tokens, first, last)
 last = last or (#tokens)
 local ts = {}
 local len = (last - first) + 1
 -- Acts much like a string.
 for i = 1, len do
  ts[i] = tokens[(first + i) - 1]
 end
 ts.sub = tokenSubset
 local function fixMatcher(t)
  if type(t) == "string" then
   return function (tkn) return tkn[1] == t end
  end
  if type(t) == "table" then
   local r = {}
   for _, v in ipairs(t) do
    r[v] = true
   end
   return function (tkn)
    return r[tkn[1]]
   end
  end
  return t
 end
 ts.find = function (self, ft, reverse)
  ft = fixMatcher(ft)
  for i = 1, len do
   local ei = i
   if reverse then ei = len - (i - 1) end
   if ft(ts[ei]) then
    return ei
   end
  end
 end
 -- find, avoiding subexpressions
 ts.findAVP = function (self, ft, reverse)
  ft = fixMatcher(ft)
  local subexprC = 0
  for i = 1, len do
   local ei = i
   if reverse then ei = len - (i - 1) end

   -- It doesn't matter if this goes negative in reverse,
   -- so long as it's 0 / not 0 at the right times.
   -- Notably, a find rp should work properly to find the EOE,
   --  though a find lp won't work properly.
   -- (Except in reverse, where it's the opposite way around.)
   if ts[ei][1] == "lp" then subexprC = subexprC + 1 end
   if ts[ei][1] == "rp" then subexprC = subexprC - 1 end
   if ts[ei][1] == "ls" then subexprC = subexprC + 1 end
   if ts[ei][1] == "rs" then subexprC = subexprC - 1 end

   if ft(ts[ei]) and subexprC == 0 then
    return ei
   end
  end
 end
 ts.len = function (self) return len end
 return ts
end

local astlib = require("ast")

local suppliers = {}
suppliers["string"] = function (f)
 return f:read("*a")
end
suppliers["ast"] = function (f)
 return astlib.read_mshl(f)
end
suppliers["tokenlist"] = suppliers["ast"]

local preparers = {}
preparers["tokenlist"] = function (alltokens)
 return tokenSubset(alltokens, 1, #alltokens)
end

local consumers = {}
consumers["string"] = function (f, s)
 f:write(s)
end
consumers["ast"] = function (f, ast)
 -- give enough information in the file that someone can decode the format
 --  properly, without shipping an entire specification in every AST.
 f:write(": ZBC AST\n")
 f:write(": This is a binary file - treat it as such.\n")
 f:write(": (Don't worry, using standard string trim is fine,\n")
 f:write(":  between the type-character and the linebreak -\n")
 f:write(":  both \\n and \\t define a linebreak here.)\n")
 astlib.dump_mshl(ast, f, "")
end
consumers["tokenlist"] = function (f, ast)
 -- give enough information in the file that someone can decode the format
 --  properly, without shipping an entire specification in every AST.
 f:write(": ZBC TOKEN LIST\n")
 f:write(": This is a binary file - treat it as such.\n")
 f:write(": (Don't worry, using standard string trim is fine,\n")
 f:write(":  between the type-character and the linebreak -\n")
 f:write(":  both \\n and \\t define a linebreak here.)\n")
 astlib.dump_mshl(ast, f, "")
end

-- All critical pieces are in place, try to run the pipeline
io.stderr:write("ZBC pipeline:\n")
local data_type = nil
local data = nil
while #args > 0 do
 local split = nil
 for i = 1, #args do
  if not split then
   if args[i] == "--" then
    split = i
   end
  end
 end
 local res = {}
 if split then
  for i = 1, split - 1 do
   table.insert(res, table.remove(args, 1))
  end
  table.remove(args, 1)
 else
  res = args
  args = {}
 end

 io.stderr:write(res[1] .. "\n")

 local pass = require(table.remove(res, 1))

 if not data then
  data = suppliers[pass.input](io.stdin)
  data_type = pass.input
 end

 if data_type ~= pass.input then
  error("Incompatible types: " .. data_type .. " but wanted " .. pass.input)
 end

 if preparers[data_type] then
  data = preparers[data_type](data)
 end
 data = pass.run(data, res)
 data_type = pass.output
end
io.stderr:write("outputting...\n")
if not data_type then
 io.stderr:write("error: apparently, nothing was outputted.\n")
end
consumers[data_type](io.stdout, data)