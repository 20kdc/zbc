-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- ZPU character access translator pass.
-- char(base, idx)
--  Reads a character from memory.
--  In C, this would be ((char *) base)[idx].
-- (Not 100% efficient, but only by 1 instruction, so...)

-- lchar(base, idx, val)
--  Writes a character to memory (returns val)
--  In C, this would be ((char *) base)[idx] = (char) val,
--   including the implied return-of-value.
-- (It's detected if the return is ignored,
--   and thus should only be as inefficient as char.)

-- This also can add, if "-H" is the first argument,
--  half/lhalf for 16-bit value access.
-- Rather than being base[idx], they are base[idx * 2].

local astlib = require("ast")
local walker = require("astwalker")

return {["run"] = function (ast, args)
 -- Modify a call to be an assembly routine.
 -- The call's target should be an ID already.
 -- 'doret' determines if the routine returns a value or not.
 local function modify_call(rv, assembly, doret, m2)
  rv[2][2] = "__asmnv__"
  if doret then
   rv[2][2] = "__asm__"
  end
  -- Move the "add" outside (it can be processed equally efficiently by the expression evaluator,
  --  and allows AST optimization passes to process it.)
  local add_a = table.remove(rv[3], 1)
  local add_b = table.remove(rv[3], 1)
  if m2 then
   -- Multiply idx by 2.
   add_b = {"pbop", "*", add_b, {"int", "2", rv[#rv]}, rv[#rv]}
  end
  local f = {"pbop", "+", add_a, add_b, rv[#rv]}
  table.insert(rv[3], 1, f)
  
  -- Prepend the assembly.
  table.insert(rv[3], 1, {"string", "\"" .. assembly .. "\"", rv[#rv]})
 end
 local function process_call(rv, doret)
  -- The rvalue is a call.
  if rv[2][1] == "id" then
   if rv[2][2] == "char" then
    if #rv[3] == 2 then
     modify_call(rv,
      "LOADB\n", true, false)
    end
   end
   if rv[2][2] == "lchar" then
    if #rv[3] == 3 then
     if doret then
      -- This has to backup the new value, then store it.
      -- If it wasn't for the inefficiency this entails doret wouldn't exist.
      modify_call(rv,
       "LOADSP 4\n" ..
       "LOADSP 4\n" ..
       "STOREB\n" ..
       "STORESP 0\n", true, false)
     else
      modify_call(rv,
       "STOREB\n", false, false)
     end
    end
   end
   if args[1] == "-H" then
    if rv[2][2] == "half" then
     if #rv[3] == 2 then
      modify_call(rv,
       "LOADH\n", true, true)
     end
    end
    if rv[2][2] == "lhalf" then
     if #rv[3] == 3 then
      if doret then
       -- This has to backup the new value, then store it.
       -- If it wasn't for the inefficiency this entails doret wouldn't exist.
       modify_call(rv,
        "LOADSP 4\n" ..
        "LOADSP 4\n" ..
        "STOREH\n" ..
        "STORESP 0\n", true, true)
      else
       modify_call(rv,
        "STOREH\n", false, true)
      end
     end
    end
   end
  end
 end

 local handle_rvalue = nil
 handle_rvalue = function (rv)
  walker.walk_rvalue(rv, handle_rvalue)
  -- now any inner processing is done...
  if rv[1] == "call" then
   process_call(rv, true)
  end
 end
 local handle_statement = nil
 handle_statement = function (stmt)
  if stmt[1] == "rvalue" then
   -- Do immediate processing on the outermost value
   --  considering the lack of a return before 
   --  trying anything else.
   -- Still walk it normally, including the double-check this implies,
   --   (because double-checks act as a NOP, this is fine)
   --   due to common sense:
   -- strmemcpy(a, b, s) {
   --  while (s > WORD_VALS - 1) {
   --   *a = *b;
   --   a =+ WORD_VALS;
   --   b =+ WORD_VALS;
   --  }
   --  while (s) {
   --   lchar(a, s, char(b, s)); // this line!
   --   s--;
   --  }
   -- }
   if stmt[2][1] == "call" then
    process_call(stmt[2], false)
   end
  end
  walker.walk_statement(stmt, handle_statement, handle_rvalue)
 end
 for _, v in ipairs(ast) do
  walker.walk_declaration(v, handle_statement, handle_rvalue)
 end
 return ast
end, ["input"] = "ast", ["output"] = "ast"}
