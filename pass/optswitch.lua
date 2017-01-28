-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- B switch block helper.
-- Under a case not using fallthrough such as:
-- switch (c) {
--  case 0:
--   do_things();
--   break;
--  case 1:
--   do_somethings();
--   break;
--  case 2:
--   do_moarthings();
--   break;
-- }
-- the compiler may be able to avoid the GOTO overhead,
-- and instead use:
-- if (c == 0) {
--  do_things();
-- } else if (c == 1) {
--  do_somethings();
-- } else if (c == 2) {
--  do_moarthings();
-- }
-- This is actually expressed as:
-- if (c == 0) {
--  while (1) { do_things(); break; }
-- } else if (c == 1) {
--  while (1) { do_somethings(); break; }
-- } else if (c == 2) {
--  while (1) { do_moarthings(); break; }
-- }
-- but should still compile better than the naive switch-based version.

local astlib = require("ast")
local walker = require("astwalker")

local function actcase(stmt)
 if stmt[1] == "case" then
  return true
 end
 if stmt[1] ~= "label" then
  return false
 end
 return stmt[2] == "default"
end

-- Note that start should point to a case.
local function contains_case(t, start)
 local contains_case = false
 local handle_statement = nil
 handle_statement = function (stmt)
  if actcase(stmt) then
   contains_case = true
   return
  end
  if stmt[1] == "switch" then
   -- cases inside another switch do not count
   return
  end
  walker.walk_statement(stmt, handle_statement, function () end)
 end
 local i = start
 local con = {}
 while (t[i][1] ~= "break") do
  local stmt = t[i]
  if stmt == nil then
   return contains_case, con, i - 1
  end
  if i == start then
   if stmt[3][1] == "break" then
    -- special exception
    return false, {stmt[3]}, i
   end
   table.insert(con, stmt[3])
   walker.walk_statement(stmt[3], handle_statement, function () end)
  else
   if actcase(stmt) then
    return true, con, i
   end
   table.insert(con, t[i])
   walker.walk_statement(stmt, handle_statement, function () end)
  end
  i = i + 1
 end
 return contains_case, con, i
end

local function buildnode(ndi, line)
 return {"while", {"int", "1", line}, {"compound", ndi, line}, line}
end

local function buildcond(av, rv, line)
 return {"pbop", "==", {"id", av, line}, rv, line}
end

local try_fixup = function (stmt)
 if stmt[3][1] == "compound" then
  local t = stmt[3][2]
  local k = 1
  local casingpoints = {}
  local defpoint = {{"break", stmt[#stmt]}}
  while k <= #t do
   if not actcase(t[k]) then
    return
   end
   local cc, con, ed = contains_case(t, k)
   if cc then
    return
   end
   table.insert(con, {"break", stmt[3][3]})
   if t[k][2] == "default" then
    defpoint = con
   else
    table.insert(casingpoints, {t[k][2], con})
   end
   k = ed + 1
  end
  -- If it's even eligible, all cases have been accounted for in casingpoints.
  -- Start with the default case, if one exists.
  local switchvar = "@pass.optswitch@switchingvar"
  local nd = buildnode(defpoint, stmt[#stmt])
  for _, v in ipairs(casingpoints) do
   local ndb = buildnode(v[2], nd[#nd])
   nd = {"if_else", buildcond(switchvar, v[1], nd[#nd]), ndb, nd, nd[#nd]}
  end
  local isetup = {"pbop", "=", {"id", switchvar, nd[#nd]}, stmt[2], nd[#nd]}

  for k, v in ipairs(stmt) do
   stmt[k] = nil
  end
  local ndo = {"compound", {
    {"auto", {{switchvar}}, nd[#nd]},
    {"rvalue", isetup, nd[#nd]},
    nd
   }, nd[#nd]}
  for k, v in ipairs(ndo) do
   stmt[k] = v
  end
 end
end

return {["run"] = function (ast, args)
 local handle_statement = nil
 handle_statement = function (stmt)
  if stmt[1] == "switch" then
   try_fixup(stmt)
  end
  walker.walk_statement(stmt, handle_statement, function () end)
 end

 for _, v in ipairs(ast) do
  walker.walk_declaration(v, handle_statement, function () end)
 end
 return ast
end, ["input"] = "ast", ["output"] = "ast"}
