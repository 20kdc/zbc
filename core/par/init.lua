-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- Takes a wrapped string of tokens,
--  and outputs a file's AST.

-- Since the beginning of time,
--  a single quote has been a substitute apostrophe.
-- What an odd world we live in.
-- (Actiony music puts me in a contemplative mood. mus_core.)

-- AST statements
-- (note, "..." means the element before it is optional, 
--  unless it's a "...+"):

-- NOTE: All statements should have the line number as their last value.
--       Compilers ARE allowed to expect this,
--        in order to simplify error processing.
-- rvalue, <rvalue>, <line>
-- if/while/switch, <rvalue>, <stmt>, <line>
-- if_else, <rvalue>, <stmt>, <stmt-else>, <line>

-- auto, {{<name>[, <rvalue-vecsize>]},...}, <line>
-- note that if the rvalue is present, this is a vector allocation.
-- Both PDP-11 and Honeywell syntaxes are supported.

-- extrn, {<name>, ...}, <line>
-- label, <name>, <stmt>, <line>
-- case, <rvalue>, <stmt>, <line>

-- break, <line>
-- Note that this can break out of while, and switch.
-- Honeywell B extension.

-- goto, <rvalue>, <line>
-- There is absolutely no guarantees in the specification of labels
--  outside the current function being available.
-- However, goto does, BNF-wise, in the documentation on PDP-11 B, take an rvalue.
-- The absolutely certain solution is to flush any
--  behind-the-scenes stack management work at labels,
--  or make your compiler not entirely compliant and error on non-ID gotos.

-- return_void, <line>
-- return, <rvalue>, <line>
-- Note that this accepts any rvalue, even though spec says () is required.
-- This should not make a difference for any valid B program.

-- compound, {<statement>, ...}
-- null, <line>

-- If your backend implements the full Honeywell B set rather than the PDP-11 B set,
--  then you have to handle default: as a special case of label.

-- AST decls
-- function, <name>, {<argid>,...}, <stmt>, <line>
-- vardef, <name>, {<ival>,...}, <line>
-- vecdef, <name>, <vsz>, {<ival>,...}, <line>

-- "par_" functions return the remaining tokens, and the output.
-- These are for cases where the length is unknown.
-- "park_" functions just return the output.
-- This is for the case where the length is known and must be the whole input.

-- Expression parsing is complicated by itself
local par_expr = require("core.par.expr")

local park_arglist = nil

-- This actually handles lvalues and rvalues,
--  since an lvalue is always in some way part of an rvalue.
-- The difference is only at compile-time,
--  where the compiler needs to keep track of
--  what it would have to write if the value was an rvalue.
local function par_rvalue_inner(tokens)
 -- Firstly, run a preprocessing step for subexpressions.
 -- The general idea is to make the precedence analysis rules simpler,
 --  by doing things like making calls treatable as an unary operator.
 -- (Which they are, but they aren't one token coming in.)
 local built = {}

 local primaries = {}
 primaries = {}
 primaries["int"] = true
 primaries["char"] = true
 primaries["id"] = true
 primaries["string"] = true
 primaries["lp"] = "indexer"
 primaries["ls"] = "indexer"

 local known = {}
 for k, v in pairs(primaries) do known[k] = v end
 known["op"] = true
 known["colon"] = true

 local lastprimary = false
 local lastpostunarybreakout = false
 -- Set to right parenthesis in order to skip past subexpressions
 --  that have already been handled.
 while #tokens > 0 do
  local tkn = tokens[1]
  if not known[tkn[1]] then
   return tokens, built
  end
  -- When switching this from park_ to par_, this had to be added.
  -- Notably, the case of a++ <statement> may cause confusion here.

  local primary = primaries[tkn[1]]
  if primary and lastprimary then
   -- indexers don't count for this
   if primary ~= "indexer" then
    return tokens, built
   end
  end

  -- Handle very specific case
  local postunarybreakout = false
  if (tkn[1] == "op") and ((tkn[2] == "++") or (tkn[2] == "--")) then
   if lastprimary then
    postunarybreakout = true
   end
  end
  if lastpostunarybreakout and primary then
   -- <primary>++<primary> is always invalid
   return tokens, built
  end

  lastprimary = primary
  lastpostunarybreakout = postunarybreakout

  if (tkn[1] == "lp") or (tkn[1] == "ls") then
   -- subexpression or arglist?
   local ender = "rp"
   if tkn[1] == "ls" then
    ender = "rs"
   end
   local rp = tokens:findAVP(ender)
   if not rp then error("Unterminated subexpr/arglist @ line " .. tkn[3]) end
   -- It is ambiguous if this is an arglist or a subexpression until later.
   table.insert(built, {"arglist" .. tkn[2], park_arglist(tokens:sub(2, rp - 1)), tkn[3]})
   tokens = tokens:sub(rp + 1)
  else
   -- generic token
   table.insert(built, tkn)
   tokens = tokens:sub(2)
  end
 end
 return tokens, built
end
local function par_rvalue(tokens)
 local line = tokens[1][3]
 local rtk, built = par_rvalue_inner(tokens)
 -- What comes out goes straight to compiler-land.
 
 -- Switching between these is useful for debugging.
 local r, re = pcall(par_expr, built)
 --local r, re = true, par_expr(built)
 
 if r then return rtk, re end
 error("Expression error @ line " .. line .. ":" .. re)
end

local function park_rvalue(tokens)
 local rtk, rv = par_rvalue(tokens)
 if #rtk > 0 then error("Remaining tokens (st. " .. tokens[1][1] .. ") after rvalue @ line " .. tokens[1][3]) end
 return rv
end

park_arglist = function (tokens)
 local groups = {}
 local a = tokens:findAVP("comma")
 while a do
  if a == 1 then
   error("Empty expression @ line " .. tokens[1][3])
  end
  table.insert(groups, park_rvalue(tokens:sub(1, a - 1)))
  tokens = tokens:sub(a + 1)
  a = tokens:findAVP("comma")
 end
 if #tokens ~= 0 then
  table.insert(groups, park_rvalue(tokens))
 end
 return groups
end

-- this is for cases which are bounded by semicolons
local function park_stmt_contents(tokens, line)
 if not tokens[1] then
  return {"null", line}
 end
 if tokens[1][1] == "id" then
  if tokens[1][2] == "extrn" then
   tokens = tokens:sub(2)
   local res = {}
   while #tokens > 0 do
    if tokens[1][1] ~= "id" then
     error("Expected ID in extdef @ line " .. tokens[1][3])
    end
    local id = tokens[1][2]
    if tokens[2] then
     if tokens[2][1] ~= "comma" then
      error("Expected comma after ID in extdef @ line " .. tokens[2][3])
     end
     tokens = tokens:sub(3)
    else
     tokens = tokens:sub(2)
    end
    table.insert(res, id)
   end
   return {"extrn", res, line}
  end
  if tokens[1][2] == "auto" then
   -- A bit more forgiving ("auto;" will do nothing, rvalues can be used)
   -- Notably, Honeywell B supports vector autos.
   -- Which leads into the problem of implementation.
   tokens = tokens:sub(2)
   local res = {}
   while #tokens > 0 do
    if tokens[1][1] ~= "id" then
     error("Expected ID in autodef @ line " .. tokens[1][3])
    end
    local id = tokens[1][2]
    local c = nil
    if tokens[2] then
     c = nil
     if tokens[2][1] == "comma" then
      tokens = tokens:sub(3)
     else
      tokens, c = par_rvalue(tokens:sub(2))
      if tokens[1] then
       if tokens[1][1] ~= "comma" then
        error("Nonsense after auto ival @ line " .. tokens[1][3])
       end
       tokens = tokens:sub(2)
      end
      -- Is this Honeywell B syntax?
      if c[1] == "arglist[" then
       c = c[2]
       if #c ~= 1 then
        error("bad vector auto definition @ line " .. line)
       end
       c = c[1]
      end
     end
    else
     tokens = tokens:sub(2)
    end
    table.insert(res, {id, c})
   end
   return {"auto", res, line}
  end
  if tokens[1][2] == "return" then
   if #tokens == 1 then
    return {"return_void", line}
   else
    return {"return", park_rvalue(tokens:sub(2)), line}
   end
  end
  if tokens[1][2] == "goto" then
   if #tokens == 1 then
    error("GOTO @ line " .. line .. " must have target!")
   else
    return {"goto", park_rvalue(tokens:sub(2)), line}
   end
  end
  if tokens[1][2] == "break" then
   if #tokens ~= 1 then
    error("break @ line " .. line .. " can't have any parameters.")
   else
    return {"break", line}
   end
  end
 end
 return {"rvalue", park_rvalue(tokens), line}
end

local par_stmt = nil

local function par_stmt_inner(tokens)
 -- Okay, so it's *not* a block.
 -- It could be a conditional, a label,
 --  or something terminatable with a semicolon.
 local conditional = false
 local canhaveelse = false
 local condpars = false
 if tokens[1][1] == "id" then
  -- This should be first, for lack of any better ideas.
  if tokens[2] then
   if tokens[2][1] == "colon" then
    local rt, rs = par_stmt(tokens:sub(3))
    return rt, {"label", tokens[1][2], rs}
   end
  end

  if tokens[1][2] == "if" then
   conditional = true
   canhaveelse = true
   condpars = true
  end
  if tokens[1][2] == "while" then
   conditional = true
   condpars = true
  end
  -- fun fact: it is legal, for some bizzare reason,
  --  for a switch to not have () around the rvalue.
  -- this required some reworking of the way rvalues are dealt with.
  if tokens[1][2] == "switch" then
   conditional = true
  end
  if tokens[1][2] == "case" then
   local cl = tokens[1][3]
   local bound = tokens:findAVP("colon")
   if not bound then error("Couldn't find colon in case @ line " .. cl) end
   local ex = park_rvalue(tokens:sub(2, bound - 1))
   tokens = tokens:sub(bound + 1)
   local rt, rs = par_stmt(tokens)
   return rt, {"case", ex, rs, cl}
  end
 end
 if conditional then
  local ct = tokens[1][2]
  local ctl = tokens[1][3]
  local ex = nil
  if condpars then
   if tokens[2][1] ~= "lp" then error("Conditional wants (), but couldn't get it @ line " .. ctl) end
   local pos = tokens:findAVP("rp")
   local tks = tokens:sub(2, pos)
   tokens = tokens:sub(pos + 1)
   ex = park_rvalue(tks)
  else
   tokens, ex = par_rvalue(tokens:sub(2))
  end
  local tokens, s = par_stmt(tokens)
  if canhaveelse then
   if tokens[1] then
    if (tokens[1][1] == "id") and (tokens[1][2] == "else") then
     local tokens, s2 = par_stmt(tokens:sub(2))
     return tokens, {ct .. "_else", ex, s, s2, ctl}
    end
   end
  end
  return tokens, {ct, ex, s, ctl}
 end
 -- So, it's not a conditional, a block, or a label.
 -- So by process of elimination...
 --  it must be something terminatable with a semicolon!
 local ft = tokens:find("semicolon")
 if not ft then
  error("Cannot understand statement '" .. tokens[1][2] .. "' ..., on line " .. tokens[1][3])
 end
 return tokens:sub(ft + 1), park_stmt_contents(tokens:sub(1, ft - 1), tokens[1][3])
end
par_stmt = function (tokens)
 if not tokens[1] then error("Expected statement at EOF") end
 local firstTP = tokens[1][1]
 if firstTP == "lb" then
  -- bunch of tokens
  local group = {}
  local line = tokens[1][3]
  tokens = tokens:sub(2)
  while true do
   if not tokens[1] then error("Hit EOF when going through function body.") end
   if tokens[1][1] == "rb" then
    return tokens:sub(2), {"compound", group, line}
   end
   local ntokens, stmt = par_stmt(tokens)
   tokens = ntokens
   table.insert(group, stmt)
  end
 end
 return par_stmt_inner(tokens)
end
local function park_decl_inner(tokens, name, line)
 -- optionally handle vector size
 local vect = nil
 if tokens[1] then
  if tokens[1][1] == "ls" then
   local line = tokens[1][3]
   if tokens[2] then
    if tokens[2][1] == "rs" then
     -- Special exception, fake a [0]
     vect = {"int", "0", line}
     tokens = tokens:sub(3)
    end
   end
   if not vect then
    tokens, vect = par_rvalue(tokens)
    if vect[1] ~= "arglist[" then
     error("Nonsense after vector size @ line " .. tokensp)
    end
    if #vect[2] ~= 1 then
     error("Invalid vector size @ line " .. tokensp)
    end
    vect = vect[2][1]
   end
  end
 end
 -- remaining tokens are ivals
 local ivals = park_arglist(tokens)
 if vect then
  return {"vecdef", name, vect, ivals, line}
 else
  return {"vardef", name, ivals, line}
 end
end
local function par_declaration(tokens)
 local id = tokens[1][2]
 local idl = tokens[1][3]
 if tokens[1][1] ~= "id" then error("Bad declaration @ line " .. idl) end
 if tokens[2][1] == "lp" then
  local f = tokens:find("lp")
  if f ~= 2 then error("Could not find start of function arglist @ line " .. idl) end

  tokens = tokens:sub(3)
  f = tokens:find("rp")
  if not f then error("Could not find end of function arglist @ line " .. idl) end
  local args = park_arglist(tokens:sub(1, f - 1))
  local argsr = {}
  for k, v in ipairs(args) do
   if v[1] ~= "id" then
    error("args should only contain IDs @ line " .. v[#v])
   end
   argsr[k] = v[2]
  end
  tokens = tokens:sub(f + 1)
  local tokens, stmt = par_stmt(tokens)
  return tokens, {"function", id, argsr, stmt, idl}
 else
  -- Declaration ending in semicolon
  local es = tokens:find("semicolon")
  if not es then error("Declaration not a function, but no semicolon, @ line " .. idl) end
  return tokens:sub(es + 1), park_decl_inner(tokens:sub(2, es - 1), id, idl)
 end
end
return {["run"] = function (tokens)
 local declarations = {}
 while #tokens > 0 do
  local decl = nil
  tokens, decl = par_declaration(tokens)
  table.insert(declarations, decl)
 end
 return declarations
end, ["input"] = "tokenlist", ["output"] = "ast"}
