-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.
-- This also applies to previous versions of this file which did not have this notice.

-- Used to reduce call stack wastage, but this is suboptimal for perf,
--  because the stack wastage was going to happen anyway - cleaning it up in chunks
--  instead of one big bundle wastes instructions solely on cleaning stack.
local checkpoint_calls = false
-- This is false for now, as some not easily resolved issues mean
--  that autos get stored even when unneeded at checkpoint boundaries.
local checkpoint_all_compounds = false
return function (args, stmt, autos, lockautos, externs, global_variables, get_unique_label, gen_words, str_term)
 local astlib = require("ast")
 local likeautos = {}
 for _, v in ipairs(args) do
  likeautos[v] = true
 end
 -- args: codeTbl, stmt, input_term
 -- returns: termination setting
 -- terminating flags from this can be:
 -- -1: Force non-termination
 --  0: Neutral
 --  1: Force termination
 -- Only -1 and 1 are valid for input_term.
 local compilers = {}
 -- returns: nothing for now
 local valcompilers = {}
 local function handle_stmt(code, stmt, input_term)
  if not compilers[stmt[1]] then
   error("No handler for " .. stmt[1] .. " @ " .. stmt[#stmt])
  end
  return compilers[stmt[1]](code, stmt, input_term)
 end
 -- Mode can be nil (default), "getset", "set", or "ptr".
 -- "getset" must, and "set" can, be provided with a statetable,
 --  getset writes values in it so that set can retrieve them,
 --  this is used to make assignment operations consistent.
 -- As getset is only used in preparation for a set, support is usually optional.
 -- If the nil mode is provided with any value in state,
 --  this means the return can be optimized away, and will not be expected.
 -- For code simplicity purposes,
 --  this should be entirely ignored where it would be easier
 --  to have an AST-level optimizer remove or restructure the 'dead code'.
 local function handle_rval(code, rv, mode, state)
  if not valcompilers[rv[1]] then
   error("No handler for " .. rv[1] .. " @ " .. rv[#rv])
  end
  return valcompilers[rv[1]](code, rv, mode, state)
 end

 local function modeerror(rv)
  error("Unsupported mode for " .. rv[1] .. " @ " .. rv[#rv])
 end

 -- RVAL COMPILERS --

 function valcompilers.id(code, rv, mode, state)
  -- note; yes, IK this doesn't properly follow context rules.
  -- At some point, I think "not caring" may become a valid policy,
  --  since if you have an extern and an auto named the same,
  --  in the same function, then just rename the auto.
  if not likeautos[rv[2]] then
   if not externs[rv[2]] then
    error("Unknown ID " .. rv[2] .. " @ " .. rv[3])
   else
    -- no matter what, this is always first
    table.insert(code, {"IM", rv[2]})
    if global_variables[rv[2]] then
     if mode == "getset" then
      mode = nil
     end
     if mode == "set" then
      table.insert(code, {"RAW", "STORE"})
      table.insert(code, {"DPOP"})
      return
     end
     if mode == "ptr" then
      table.insert(code, {"DTMP"})
      return
     end
     if mode then modeerror(rv) end
     table.insert(code, {"RAW", "LOAD"})
     table.insert(code, {"DTMP"})
     return
    end
    if mode then modeerror(rv) end
    table.insert(code, {"DTMP"})
    return
   end
  end
  if mode == "getset" then
   mode = nil -- nothing special here
  end
  if mode == "set" then
   table.insert(code, {"ASET", rv[2]})
   return
  end
  if mode == "ptr" then
   table.insert(code, {"APTR", rv[2]})
   lockautos[rv[2]] = true
   return
  end
  if mode then modeerror(rv) end
  table.insert(code, {"AGET", rv[2]})
 end

 function valcompilers.int(code, rv, mode, state)
  if mode then modeerror(rv) end
  table.insert(code, {"IM", tostring(astlib.parse_int(rv[2]))})
  table.insert(code, {"DTMP"})
 end

 -- Thanks to... MAGIC! (actually wrapping)
 -- This works with rvalues *and* lvalues.
 valcompilers["arglist("] = function (code, rv, mode, state)
  if #rv[2] ~= 1 then error("Wrapper @ " .. rv[3] .. " had !=1 param.") end
  return handle_rval(code, rv[2][1], mode, state)
 end

 -- RVALs : not-quite-primary general

 function valcompilers.index(code, rv, mode, state)
  if mode == "set" then
   if state then
    -- Don't even bother to go through and gen. basecode
    table.insert(code, {"RELE", state})
    table.insert(code, {"RAW", "STORE"})
    table.insert(code, {"DPOP"})
    table.insert(code, {"DPOP"})
    return
   end
  end
  handle_rval(code, rv[2])
  local baseP = {}
  table.insert(code, {"HOLD", baseP})
  if (#rv[3]) ~= 1 then error("Indexer not the right size @ " .. rv[4]) end
  handle_rval(code, rv[3][1])
  local baseI = {}
  table.insert(code, {"HOLD", baseI})
  table.insert(code, {"RELE", baseP, baseI})
  table.insert(code, {"DPOP"})
  table.insert(code, {"DPOP"})
  table.insert(code, {"RAW", "ADD"})
  table.insert(code, {"DTMP"})
  if mode == "getset" then
   table.insert(code, {"HOLD", state})
   table.insert(code, {"RAW", "LOADSP 0"})
   table.insert(code, {"RAW", "LOAD"})
   table.insert(code, {"DTMP"})
   return
  end
  if mode == "set" then
   -- set w/getset is handled above.
   table.insert(code, {"RAW", "STORE"})
   table.insert(code, {"DPOP"})
   table.insert(code, {"DPOP"})
   return
  end
  if mode then modeerror(rv) end
  -- it's known that TOS is a "useless temp." anyway
  table.insert(code, {"RAW", "LOAD"})
 end

 function valcompilers.call(code, rv, mode, state)
  if mode then modeerror(rv) end
  if checkpoint_calls then
   table.insert(code, {"STCK"})
  end
  table.insert(code, {"IST+"}) -- stack wastage *will* cause more issues than it solves during a call.
  -- There are some calls which need to be handled specially,
  --  since they can be reduced to single instructions without user cost.
  local argholds = {"RELE"}
  for i = 1, #rv[3] do
   local k = (#rv[3] - i) + 1
   local v = rv[3][k]
   local h = {}
   handle_rval(code, v)
   table.insert(code, {"HOLD", h})
   table.insert(argholds, h)
  end
  if rv[2][1] ~= "id" then
   local finalhold = {}
   handle_rval(code, rv[2])
   table.insert(code, {"HOLD", finalhold})
   table.insert(argholds, finalhold)
   -- dump everything in the right place on stack
   table.insert(code, argholds)
  else
   -- if it's an ID, risk setting everything up beforehand
   --  then putting the call address on top and re-sanity-checking,
   --  because this is guaranteed to be relatively OK
   -- (could save an extra instruction LOADSPing the call address
   --   that just got set up, and wasn't usable because of the stack layout)
   -- (note, this only helps anything because ID never burns stack)
   local finalhold = {}
   table.insert(code, argholds)
   local argholds2 = {}
   for k, v in ipairs(argholds) do argholds2[k] = v end
   handle_rval(code, rv[2])
   table.insert(code, {"HOLD", finalhold})
   table.insert(argholds2, finalhold)
   table.insert(code, argholds2)
  end
  table.insert(code, {"RAW", "CALL"})
  table.insert(code, {"DPOP"})
  table.insert(code, {"IST-"})
  if checkpoint_calls then
   table.insert(code, {"ETCK"})
  end
  if not state then
   table.insert(code, {"RAW", "IM _memreg"})
   table.insert(code, {"RAW", "LOAD"})
   table.insert(code, {"DTMP"})
  end
 end
 
 -- RVALs : operators

 function valcompilers.puop(code, rv, mode, state)
  if not rv[4] then
   local simpleops = {}
   simpleops["-"] = "NEG"
   simpleops["~"] = "NOT"
   if simpleops[rv[2]] then
    if mode then modeerror(rv) end
    handle_rval(code, rv[3])
    table.insert(code, {"DPOP"})
    table.insert(code, {"RAW", simpleops[rv[2]]})
    table.insert(code, {"DTMP"})
    return
   end
   if rv[2] == "&" then
    if mode then modeerror(rv) end
    handle_rval(code, rv[3], "ptr")
    return
   end
   if rv[2] == "*" then
    if mode == "getset" then
     handle_rval(code, rv[3])
     -- rather than popping, preserve it & clone
     table.insert(code, {"HOLD", state})
     table.insert(code, {"RAW", "LOADSP 0"})
     table.insert(code, {"RAW", "LOAD"})
     table.insert(code, {"DTMP"})
     return
    end
    if mode == "set" then
     local datao = {}
     local addro = {}
     table.insert(code, {"HOLD", datao})
     if not state then
      handle_rval(code, rv[3])
      table.insert(code, {"HOLD", addro})
     else
      addro = state
     end
     table.insert(code, {"RELE", datao, addro})
     table.insert(code, {"DPOP"})
     table.insert(code, {"DPOP"})
     table.insert(code, {"RAW", "STORE"})
    else
     if mode then modeerror(rv) end
     handle_rval(code, rv[3])
     table.insert(code, {"DPOP"})
     table.insert(code, {"RAW", "LOAD"})
     table.insert(code, {"DTMP"})
    end
    return
   end
  end
  error("Unrecognized PUOP " .. rv[2] .. " @ " .. rv[5])
 end

 function valcompilers.pbop(code, rv, mode, state)
  local simpleops = {}
  -- "nb" is the direction parameter.
  -- If A - B is coming out as B - A, invert it for -.
  local function simple(n, nb)
   return {function ()
    table.insert(code, {"RAW", n})
   end, nb}
  end
  -- for symmetric ops, default to true
  simpleops["+"] = simple("ADD", true)
  simpleops["-"] = simple("SUB", false)
  simpleops["*"] = simple("SLOWMULT", true)
  simpleops["/"] = simple("DIV", true)
  simpleops["%"] = simple("MOD", true)
  if simpleops[rv[2]] then
   if mode then modeerror(rv) end
   local goldena = {}
   local goldenb = {}
   if simpleops[rv[2]][2] then
    handle_rval(code, rv[3])
    table.insert(code, {"HOLD", goldena})
    handle_rval(code, rv[4])
    table.insert(code, {"HOLD", goldenb})
   else
    handle_rval(code, rv[4])
    table.insert(code, {"HOLD", goldena})
    handle_rval(code, rv[3])
    table.insert(code, {"HOLD", goldenb})
   end
   table.insert(code, {"RELE", goldena, goldenb})
   table.insert(code, {"DPOP"})
   table.insert(code, {"DPOP"})
   simpleops[rv[2]][1]()
   table.insert(code, {"DTMP"})
   return
  end
  if rv[2] == "=" then
   -- It doesn't work that way.
   if mode then modeerror(rv) end
   handle_rval(code, rv[4])
   local bk = {}
   if not state then
    table.insert(code, {"RAW", "LOADSP 0"})
    table.insert(code, {"HOLD", bk})
    table.insert(code, {"DTMP"})
   end
   handle_rval(code, rv[3], "set")
   if not state then
    table.insert(code, {"RELE", bk})
   end
   return
  end
  if rv[2]:sub(1, 1) == "=" then
   local opn = rv[2]:sub(2)
   if simpleops[opn] then
    if mode then modeerror(rv) end
    local goldena = {}
    local goldenb = {}
    local lstate = {}
    if simpleops[opn][2] then
     handle_rval(code, rv[3], "getset", lstate)
     table.insert(code, {"HOLD", goldena})
     handle_rval(code, rv[4])
     table.insert(code, {"HOLD", goldenb})
    else
     handle_rval(code, rv[4])
     table.insert(code, {"HOLD", goldena})
     handle_rval(code, rv[3], "getset", lstate)
     table.insert(code, {"HOLD", goldenb})
    end
    table.insert(code, {"RELE", goldena, goldenb})
    table.insert(code, {"DPOP"})
    table.insert(code, {"DPOP"})
    simpleops[opn][1]()
    table.insert(code, {"DTMP"})
    local bk = {}
    if not state then
     table.insert(code, {"RAW", "LOADSP 0"})
     table.insert(code, {"HOLD", bk})
     table.insert(code, {"DTMP"})
    end
    handle_rval(code, rv[3], "set", lstate)
    if not state then
     table.insert(code, {"RELE", bk})
    end
    return
   end
  end
  error("Unrecognized PBOP " .. rv[2] .. " @ " .. rv[5])
 end

 -- Not sure how to handle this, defer to compiler core
 function valcompilers.string(code, rv, mode, state)
  if mode then modeerror(rv) end
  local ps = astlib.parse_str(rv[2], astlib.default_escapes, rv[3]) .. str_term
  ps = astlib.parse_chars(ps, rv[3], true, false)
  table.insert(code, {"IM", gen_words(ps)})
  table.insert(code, {"DTMP"})
 end

 function valcompilers.char(code, rv, mode, state)
  if mode then modeerror(rv) end
  local ps = astlib.parse_str(rv[2], astlib.default_escapes, rv[3])
  local r = astlib.parse_chars(ps, rv[3], true, true)
  if #r ~= 1 then
   error("Badly sized char @ " .. rv[3])
  end
  table.insert(code, {"IM", tostring(r[1])})
  table.insert(code, {"DTMP"})
 end

 -- STMT COMPILERS --

 function compilers.compound(code, stmt, input_term)
  if checkpoint_all_compounds then
   table.insert(code, {"STCK"})
  end
  local terminating = input_term
  for _, v in ipairs(stmt[2]) do
   local t = handle_stmt(code, v, terminating)
   if t ~= 0 then
    terminating = t
   end
  end
  if checkpoint_all_compounds then
   if terminating == 1 then
    -- don't bother
    table.insert(code, {"TTCK"})
   else
    table.insert(code, {"ETCK"})
   end
  end
  return terminating
 end

 function compilers.rvalue(code, stmt, input_term)
  handle_rval(code, stmt[2], nil, true)
  return 0
 end

 compilers["return"] = function (code, stmt, input_term)
  if input_term ~= 1 then
   handle_rval(code, stmt[2])
   table.insert(code, {"RETN"})
  end
  return 1
 end
 function compilers.return_void(code, stmt, input_term)
  if input_term ~= 1 then
   table.insert(code, {"RETV"})
  end
  return 1
 end

 compilers["while"] = function (code, stmt, input_term)
  -- As a while is a loop, it may as well have a label in it at the top.
  -- Currently while loops are just always non-terminating.
  local lab = get_unique_label()
  local labend = get_unique_label()
  table.insert(code, {"RAW", lab .. ":"})
  table.insert(code, {"SBCK"})
  handle_rval(code, stmt[2])
  table.insert(code, {"DPOP"})
  table.insert(code, {"IMPCREL", labend})
  table.insert(code, {"RAW", "EQBRANCH"})
  handle_stmt(code, stmt[3], -1)
  table.insert(code, {"ETCK"})
  table.insert(code, {"IMPCREL", lab})
  table.insert(code, {"RAW", "POPPCREL"})
  table.insert(code, {"RAW", labend .. ":"})
  -- If it terminates in the body, it *may* terminate,
  -- if it will not terminate, it may not terminate.
  -- If that makes sense.
  return -1
 end

 function compilers.extrn(code, stmt, input_term)
  for _, v in ipairs(stmt[2]) do
   externs[v] = true
  end
  return 0
 end

 function compilers.auto(code, stmt, input_term)
  for _, v in ipairs(stmt[2]) do
   if v[2] then
    error("Still need to work out how vector definitions should work @ " .. stmt[3])
   end
   likeautos[v[1]] = true
   autos[v[1]] = true
  end
  return 0
 end

 local fc = {}
 local ft = handle_stmt(fc, stmt, -1)
 return fc, ft == 1
end