-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- ZBC. A B compiler for the modern world. (Maybe.)

local f = io.open("test.b", "r")
local s = f:read("*a")
f:close()

local lex = require("lex")
-- All the tokens go in here.
local alltokens = lex(s)
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
local tokens = tokenSubset(alltokens, 1, #alltokens)

-- leave this in global for debugging purposes.
dump = function (obj, indent)
 indent = indent or 1
 local ispc = string.rep(" ", indent)
 if type(obj) == "table" then
  local b = "{\n" .. ispc
  local newline = false
  for k, v in pairs(obj) do
   if newline then
    b = b .. ",\n" .. ispc
   end
   b = b .. "[" .. dump(k, indent + 1) .. "] = " .. dump(v, indent + 1)
   newline = true
  end
  return b .. "}"
 else
  return tostring(obj)
 end
end

local par = require("par")
local ast = par(tokens)

-- The guide to the base AST format.
-- This is a binary format when it comes down to it,
--  because strings may contain newlines in the source file that carry,
--  but a lot of padding exists for readability :)
-- Essentially, any object starts with a line.
-- A line is always terminated by 0x0A or 0x08. (aka "\n" and "\t")
-- A line MAY NOT be terminated by any other system,
--  including extensions like 0x0D 0x0A, as allowing this
--  would allow people to screw up their file output by accident,
--  and that would probably cause the aforementioned newlines case to fail.

-- All 0x20 bytes can be safely removed from a line.
-- It is safe to use a whitespace-trimming function to achieve this.

-- The first byte in a line specifies the type.
-- The rest of the data in that line is specific to that object type,
--  and immediately after the line ends, a binary blob may exist.

-- There are only 4 object types.
-- { : Table. Further objects will be values.
--     No valid AST tables contain value holes,
--      or non-numeric keys.
-- } : Nil. If used as a table value, that ends the table.
-- % : Number. The main body of the line is the number.
-- $ : String. The main body of the line is the number of bytes in the text.
--             Immediately following is that amount of bytes,
--              plus an additional newline.
-- Y : Yes.
-- N : No.

-- There is also:
-- : : Comment. Read in another object to take it's place.

local astlib = require("ast")
-- give enough information in the file that someone can decode the format
--  properly, without shipping an entire specification in every AST.
io.stdout:write(": ZBC AST\n")
io.stdout:write(": This is a binary file - treat it as such.\n")
io.stdout:write(": (Don't worry, using standard string trim is fine,\n")
io.stdout:write(":  between the type-character and the linebreak -\n")
io.stdout:write(":  both \\n and \\t define a linebreak here.)\n")
astlib.dump_mshl(ast, io.stdout, "")
