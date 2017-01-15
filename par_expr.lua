-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- B Expression Parser.

-- Notably, this does not need to deal with any of the kind of rules 
--  which apply to tokens, as those are dealt with earlier.

-- This thus allows the code to solely focus on the correct 
--  implementation of precedence rules.
-- Hopefully that will lead to a correct implementation.

local function subset(t, f, l)
 local r = {}
 for i = f, l do
  table.insert(r, t[i])
 end
 return r
end

-- Attempts to reduce an expression to a node.
-- Pass in a list of expression pieces.
local try_reduce = nil

local function finddiv(rhs)
 for i = 1, #rhs do
  if rhs[i][1] == "colon" then
   return i
  end
 end
 error("Unable to find trinary divider.")
end

-- The core function to try expression reduction.
try_reduce = function(expr)
 if #expr == 1 then
  -- Issues will throw when they hit the compiler,
  --  and for the majority of bad cases that's expected,
  --  but check for anything *obvious* now.
  if expr[1][1] == "op" then
   error("Dangling operator")
  end
  if expr[1][1] == "colon" then
   error("Dangling colon")
  end
  return expr[1]
 end
 if #expr == 0 then error("Could not operate on empty expression.") end

 local done = nil
 -- "right to left binding"
 -- is x=(y=0)
 -- so "ltr", and "rtl" are the association values.
 -- "trinary" is "rtl", but doing trinary stuff.

 -- Notably, "pbop" is "processed binary operator",
 --  and "ptop" is "processed trinary operator".
 -- This is to mark processed operators from unprocessed,
 --  so a sane error can be thrown if reduction is successful but
 --  the reduced data contains dangling operators.
 local function handle_op(ops, assoc)
  if done then return end
  for i = 1, #expr do
   local ri = i
   if assoc == "ltr" then
    ri = (#expr) - (i - 1)
   end
   if expr[ri][1] == "op" then
    for _, v in ipairs(ops) do
     if v == expr[ri][2] then
      local lhs = subset(expr, 1, ri - 1)
      local rhs = subset(expr, ri + 1, #expr)
      if assoc == "trinary" then
       local div = finddiv(rhs)
       local rhsa = subset(rhs, 1, div - 1)
       local rhsb = subset(rhs, div + 1, #rhs)
       done = {"ptop", v, try_reduce(lhs), try_reduce(rhsa), try_reduce(rhsb), expr[ri][3]}
       return
      else
       -- if LHS is empty, assume ambiguity struck.
       -- (it'll just give a generic expression reduction failure,
       --  if it turns out that this is wrong)
       -- Otherwise, since LHS contained something,
       -- there is absolutely no possible way this can be a workable unary op
       if #lhs ~= 0 then
        local lhse = try_reduce(lhs)
        local rhse = try_reduce(rhs)
        done = {"pbop", v, lhse, rhse, expr[ri][3]}
        return
       end
      end
     end
    end
   end
  end
 end
 local function handle_unop(ops, rightop)
  if done then return end
  local ind = 1
  local st = 2
  local en = #expr
  if rightop then
   ind = #expr
   st = 1
   en = #expr - 1
  end
  if expr[ind][1] == "op" then
   for _, v in ipairs(ops) do
    if v == expr[ind][2] then
     done = {"puop", v, try_reduce(subset(expr, st, en)), rightop, expr[ind][3]}
     return
    end
   end
  end
 end

 -- actually attempt to parse according to the rules
 -- essentially: Read the sections from 4.11 *backwards*.
 handle_op({"=", "=|", "=&", "===", "=!=", "=<", "=<=", "=>", "=>=",
  "=<<", "=>>", "=+", "=-", "=%", "=*", "=/"}, "rtl")
 handle_op({"?"}, "trinary")
 handle_op({"|"}, "ltr")
 handle_op({"^"}, "ltr") -- May be Honeywell-specific
 handle_op({"&"}, "ltr")--4.8
 handle_op({"==", "!="}, "unk")
 handle_op({"<", "<=", ">", ">="}, "unk")
 handle_op({"<<", ">>"}, "ltr")
 handle_op({"+", "-"}, "ltr")
 handle_op({"*", "/", "%"}, "ltr")
 --
 -- Deal with unary operations last.

 -- Currently this gives the most accurate results,
 --  for cases like "*adx++".
 -- The '~' operator may be Honeywell-specific.
 handle_unop({"++", "--", "~", "!", "-", "&", "*"}, false)
 handle_unop({"++", "--"}, true)

 if done then return done end

 -- Deal with calls and indexing 'manually'.
 -- Notably, this occurs *after* any other reduction steps are performed,
 --  meaning they are the last to be performed,
 --  and thus will postfix a primary expression whenever possible,
 --  as the specification dictates.
 -- This behavior should be changed to actual primary-expression-only binding,
 --  if there is some ambiguous case which causes an issue.
 if (expr[#expr][1] == "arglist[") or (expr[#expr][1] == "arglist(") then
  -- notably, the "processed" forms have different IDs from unprocessed,
  -- since otherwise it would be too easy for unprocessed tokens to leak.
  local id = "call"
  if expr[#expr][1] == "arglist[" then
   id = "index"
  end
  local al = expr[#expr][2]
  return {id, try_reduce(subset(expr, 1, #expr - 1)), al, expr[1][3]}
 end

 error("Could not reduce expression. (" .. #expr .. " tokens)")
end

return function (e) return try_reduce(e) end
