-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- Honeywell B automatic-insert-of-extrn pass.
-- Honeywell B doesn't use extrn for function calls.
-- Specifically not function calls.
-- It requires them elsewhere, though.
-- So, find function calls by constant IDs, then.

-- Arguments are IDs to never add as extrns.
-- For the ZPU backend, this should be "__asm__ __asmnv__",
--  and this pass should after things such as zpu-char.

local astlib = require("ast")
local walker = require("astwalker")

return {["run"] = function (ast, args)
 local collect_extrn, collect_cid

 local handle_rvalue = nil
 handle_rvalue = function (rv)
  if rv[1] == "call" then
   if rv[2][1] == "id" then
    collect_cid[rv[2][2]] = true
   end
  end
  walker.walk_rvalue(rv, handle_rvalue)
 end

 local handle_statement = nil

 handle_statement = function (stmt)
  if stmt[1] == "auto" then
   for _, v in ipairs(stmt[2]) do
    -- Try not to sabotage indirect calls.
    collect_extrn[v[1]] = true
   end
  end
  if stmt[1] == "extrn" then
   for _, v in ipairs(stmt[2]) do
    collect_extrn[v] = true
   end
  end
  walker.walk_statement(stmt, handle_statement, handle_rvalue)
 end

 for _, v in ipairs(ast) do
  if v[1] == "function" then
   collect_extrn = {}
   collect_cid = {}
   for _, v in ipairs(args) do
    collect_extrn[v] = true
   end
   for _, v in ipairs(v[3]) do
    -- Try not to sabotage indirect calls.
    collect_extrn[v] = true
   end
   handle_statement(v[4])
   local res = {}
   for k, v in pairs(collect_cid) do
    if not collect_extrn[k] then
     table.insert(res, k)
    end
   end
   v[4] = {"compound", {{"extrn", res, v[5]}, v[4]}, v[5]}
  end
 end
 return ast
end, ["input"] = "ast", ["output"] = "ast"}
