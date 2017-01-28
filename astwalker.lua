-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

local astlib = require("ast")

-- walk_declaration, def, handle_statement, handle_rvalue
-- walk_statement, stmt, handle_statement, handle_rvalue
-- walk_rvalue, rv, handle_rvalue

return {["walk_declaration"] = function (def, handle_statement, handle_rvalue)
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
 end, ["walk_statement"] = function (stmt, handle_statement, handle_rvalue)
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
  if stmt[1] == "null" then
   return
  end
  error("IDK statement " .. stmt[1] .. " @ " .. stmt[#stmt])
 end, ["walk_rvalue"] = function (rv, handle_rvalue)
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
   handle_rvalue(rv[2])
   for _, v in ipairs(rv[3]) do
    handle_rvalue(v)
   end
   return
  end
  error("IDK how to handle " .. rv[1] .. " @ " .. rv[#rv])
 end}