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

-- The Specification On Internal Autos & Such:
-- @<lua module name>@<internal variable name, creator-defined>
-- This format should be used by optimization passes that want to add stuff.

-- What's missing:
--  + missing operators, particularly unary ops ++ and --
--    (practically a nice break after dealing with switch)
--    also trinary op, but it's not a major issue
--  + auto vectors
--    (shouldn't be too difficult,
--     just add a way to indicate how much "vector room" is needed.
--     this can be considered part of PSTK space.
--     by putting in internal autos into those points,
--      marking them as locked & such,
--      it should be easy enough to set the pointers using APTR & ASET.)
--  + *the moment auto vectors are implemented, get the LOADSP/STORESP refactoring in the stack management code happening.*
--  + make access to LOADB/STOREB/LOADH/STOREH happen
--     (using "fake library functions" which don't need to get extrn'd.
--       allows some violation of spec but... whatever.)
--  + refactor some of cnsteval's code into "astwalker" module
--    (this should speed up writing future passes)
--  + some optimization of switch/case if at all possible
--    (do this at the AST transform level to simply things.
--     basically, *avoid the GOTO-like system when possible*,
--     unless a switch-table is usable, in which case stick with it.
--     ...and do this all in one optimization pass.)
--  + optimize GOTO to constant labels (very low priority)
--  + misc. AST optimization passes (ex. rvalue deduplication)

--  + more backends (...announce on apr.1st. not happening.)

return function (args, stmt, autos, lockautos, externs, global_variables, get_unique_label, gen_words, str_term)
 local astlib = require("ast")
 local likeautos = {}
 for _, v in ipairs(args) do
  likeautos[v] = true
 end

 local declared_labels = {}
 local declared_labels_need_resolution = {}
 local function get_label(name)
  if declared_labels[name] then
   return declared_labels[name]
  end
  declared_labels[name] = get_unique_label()
  declared_labels_need_resolution[name] = true
 end

 -- Used by "switch" to map integers to case labels.
 local switch_unique_cases = nil
 local switch_unique_default = nil

 local current_break_label = nil

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
    return get_label(rv[2])
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
   -- Use a null operation, because this general area of stack is going to turn into the call-zone.
   table.insert(code, {"DPOP"})
   table.insert(code, {"DTMP"})
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
   table.insert(code, {"RAW", "CALL"})
  else
   -- if it's an ID, risk setting everything up beforehand
   --  then putting the call address on top and re-sanity-checking,
   --  because this is guaranteed to be relatively OK
   -- (could save an extra instruction LOADSPing the call address
   --   that just got set up, and wasn't usable because of the stack layout)
   -- (note, this only helps anything because ID never burns stack)
   table.insert(code, argholds)

   local can_relpc = false
   if not likeautos[rv[2][2]] then
    if externs[rv[2][2]] then
     if not global_variables[rv[2][2]] then
      can_relpc = true
     end
    end
   end

   if not can_relpc then
    -- Handle the value, hold it, put it at the TOS of the absolute final RELE,
    --  and then actually run the call.
    handle_rval(code, rv[2])

    local finalhold = {}
    table.insert(code, {"HOLD", finalhold})

    -- put call addr. on TOS
    local argholds2 = {}
    for k, v in ipairs(argholds) do argholds2[k] = v end
    table.insert(argholds2, finalhold)
    -- RELE
    table.insert(code, argholds2)
    -- actually run the call
    table.insert(code, {"DPOP"})
    table.insert(code, {"RAW", "CALL"})
   else
    -- absolutely 100% sure this is can be IMRELPC'd so completely avoid stack management
    table.insert(code, {"IMPCREL", rv[2][2]})
    table.insert(code, {"RAW", "CALLPCREL"})
   end
  end
  table.insert(code, {"IST-"})
  if checkpoint_calls then
   table.insert(code, {"ETCK"})
  end
  if not state then
   table.insert(code, {"IM", "_memreg"})
   table.insert(code, {"RAW", "LOAD"})
   table.insert(code, {"DTMP"})
  end
 end
 
 -- RVALs : operators

 -- "nb" is the direction parameter.
 -- For unary ops, this means one thing, for binary ops, another.
 -- If A - B is coming out as B - A, invert it for -.
 local function oph_simple_element(code, n)
  if type(n) == "table" then
   table.insert(code, n)
  else
   table.insert(code, {"RAW", n})
  end
 end
 local function oph_simple(code, n, nb)
  return {function ()
   if type(n) == "table" then
    for _, v in ipairs(n) do
     oph_simple_element(code, v)
    end
   else
    oph_simple_element(code, n)
   end
  end, nb}
 end

 function valcompilers.puop(code, rv, mode, state)
  local simpleops = {}
  simpleops["-"] = oph_simple(code, "NEG", false)
  simpleops["~"] = oph_simple(code, "NOT", false)
  simpleops["!"] = oph_simple(code, {{"IM", "0"}, "EQ"}, false)
  if simpleops[rv[2]] then
   if rv[4] ~= simpleops[rv[2]][2] then
    error("Operation " .. rv[2] .. " not usable in that way @ " .. rv[5])
   end
   if mode then modeerror(rv) end
   handle_rval(code, rv[3])
   table.insert(code, {"DPOP"})
   simpleops[rv[2]][1]()
   table.insert(code, {"DTMP"})
   return
  end
  if not rv[4] then
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

  -- for symmetric ops, use "symmetric", otherwise:
  -- false: Pop A first. true: Pop B first.
  -- Notably symmetric ops *should* default to true in implementation.
  simpleops["+"] = oph_simple(code, "ADD", "symmetric")
  simpleops["*"] = oph_simple(code, "SLOWMULT", "symmetric")

  simpleops["&"] = oph_simple(code, "AND", "symmetric")
  simpleops["|"] = oph_simple(code, "OR", "symmetric")
  simpleops["^"] = oph_simple(code, "XOR", "symmetric")

  simpleops["=="] = oph_simple(code, "EQ", "symmetric")
  simpleops["!="] = oph_simple(code, "NEQ", "symmetric")

  -- non-symmetrics

  simpleops["-"] = oph_simple(code, "SUB", true)
  simpleops["/"] = oph_simple(code, "DIV", false)
  simpleops["%"] = oph_simple(code, "MOD", false)

  -- wow those are long names
  simpleops["<"] = oph_simple(code, "LESSTHAN", false)
  simpleops["<="] = oph_simple(code, "LESSTHANOREQUAL", false)
  simpleops[">"] = oph_simple(code, "LESSTHAN", true)
  simpleops[">="] = oph_simple(code, "LESSTHANOREQUAL", true)

  local function handle_simple_op(opn, goldena, goldenb, lstate)
   local function handlerv3(cod)
    if not lstate then
     handle_rval(cod, rv[3])
    else
     handle_rval(cod, rv[3], "getset", lstate)
    end
   end
   if simpleops[opn][2] == true then
    handlerv3(code)
    table.insert(code, {"HOLD", goldena})
    handle_rval(code, rv[4])
    table.insert(code, {"HOLD", goldenb})
   else
    if simpleops[opn][2] == false then
     handle_rval(code, rv[4])
     table.insert(code, {"HOLD", goldena})
     handlerv3(code)
     table.insert(code, {"HOLD", goldenb})
    else
     local mcode1 = {}
     handlerv3(mcode1)
     table.insert(mcode1, {"HOLD", goldena})
     handle_rval(mcode1, rv[4])
     table.insert(mcode1, {"HOLD", goldenb})

     local mcode2 = {}
     handle_rval(mcode2, rv[4])
     table.insert(mcode2, {"HOLD", goldena})
     handlerv3(mcode2)
     table.insert(mcode2, {"HOLD", goldenb})
     
     -- But before this code is compiled, first we have to talk about parallel universes.
     -- Parallel universes are created by the "PU" pseudoassembly statement.
     -- This statement is used to ask the stack management system to pick the more efficient choice.
     -- By using parallel universes, symmetric operations can be scheduled in whichever way is fastest,
     --  at the small cost of not having a consistent order.
     -- And yes, I called it "PU" to make this joke.
     table.insert(code, {"PU", mcode1, mcode2})
    end
   end
  end

  if simpleops[rv[2]] then
   if mode then modeerror(rv) end
   local goldena = {}
   local goldenb = {}
   handle_simple_op(rv[2], goldena, goldenb)
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
    handle_simple_op(opn, goldena, goldenb, lstate)
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
  if input_term ~= 1 then
   handle_rval(code, stmt[2], nil, true)
  end
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

  local ocbl = current_break_label
  current_break_label = labend
  handle_stmt(code, stmt[3], -1)
  current_break_label = ocbl

  table.insert(code, {"BRKC"})
  table.insert(code, {"IMPCREL", lab})
  table.insert(code, {"RAW", "POPPCREL"})
  table.insert(code, {"RAW", labend .. ":"})
  table.insert(code, {"ETCK"})
  -- If it terminates in the body, it *may* terminate,
  -- if it will not terminate, it may not terminate.
  -- If that makes sense.
  -- (Also, a break counts as terminating. Could fail.)
  return -1
 end

 compilers["if"] = function (code, stmt, input_term)
  local labend = get_unique_label()
  if input_term ~= 1 then
   handle_rval(code, stmt[2])
   table.insert(code, {"DPOP"})
   table.insert(code, {"IMPCREL", labend})
   table.insert(code, {"RAW", "EQBRANCH"})
  end
  table.insert(code, {"STCK"})
  local tm = handle_stmt(code, stmt[3], input_term)
  table.insert(code, {"ETCK"})
  if input_term ~= 1 then
   table.insert(code, {"RAW", labend .. ":"})
  end
  -- If it's terminating, it MAY be terminating,
  --  if it's explicitly nonterminating, it will always be so.
  if tm == 1 then tm = 0 end
  return tm
 end

 -- This needs termination work
 compilers["if_else"] = function (code, stmt, input_term)
  local labend = get_unique_label()
  local labelse = get_unique_label()
  if input_term ~= 1 then
   handle_rval(code, stmt[2])
   table.insert(code, {"DPOP"})
   table.insert(code, {"IMPCREL", labelse})
   table.insert(code, {"RAW", "EQBRANCH"})
  end
  table.insert(code, {"STCK"})
  handle_stmt(code, stmt[3], input_term)
  table.insert(code, {"ETCK"})
  table.insert(code, {"IMPCREL", labend})
  table.insert(code, {"RAW", "POPPCREL"})
  table.insert(code, {"RAW", labelse .. ":"})
  table.insert(code, {"STCK"})
  handle_stmt(code, stmt[4], input_term)
  table.insert(code, {"ETCK"})
  table.insert(code, {"RAW", labend .. ":"})
  return -1
 end

 -- This needs termination work
 compilers["switch"] = function (code, stmt, input_term)
  -- This'll be a fun one, I'm sure.
  local bk_cas = switch_unique_cases
  local bk_def = switch_unique_default
  -- Actually run switch
  switch_unique_cases = {}
  local labend = get_unique_label()
  switch_unique_default = labend
  table.insert(code, {"SBCK"})

  handle_rval(code, stmt[2])

  local tempcode = {}
  local bk_brk = current_break_label
  current_break_label = labend
  local term = handle_stmt(tempcode, stmt[3], 1)
  current_break_label = bk_brk

  -- Order of handling is consistent enough.
  -- For now, the rvalue result just sticks around.

  for kc, v in pairs(switch_unique_cases) do
   table.insert(code, {"RAW", "LOADSP 0"})
   if kc ~= 0 then
    table.insert(code, {"IM", kc})
    table.insert(code, {"RAW", "SUB"})
   end

   local lbl = get_unique_label()
   table.insert(code, {"IMPCREL", lbl})
   table.insert(code, {"RAW", "NEQBRANCH"})
   table.insert(code, {"FSTK"})
   table.insert(code, {"IMPCREL", v})
   table.insert(code, {"RAW", "POPPCREL"})
   table.insert(code, {"RAW", lbl .. ":"})
  end

  if switch_unique_default ~= labend then
   table.insert(code, {"FSTK"})
  else
   table.insert(code, {"BRKC"})
  end
  table.insert(code, {"IMPCREL", switch_unique_default})
  table.insert(code, {"RAW", "POPPCREL"})

  for _, v in ipairs(tempcode) do
   table.insert(code, v)
  end
  if term == -1 then
   table.insert(code, {"TTCK"})
  end
  table.insert(code, {"RAW", labend .. ":"})
  --
  switch_unique_cases = bk_cas
  switch_unique_default = bk_def
  return -1
 end

 function compilers.case(code, stmt, input_term)
  table.insert(code, {"STCK"})
  local caseA = get_unique_label()
  local caseB = get_unique_label()
  if stmt[2][1] ~= "int" then
   error("Case constant not int @ " .. stmt[2][#stmt[2]])
  end
  if input_term ~= 1 then
   table.insert(code, {"IMPCREL", caseB})
   table.insert(code, {"RAW", "POPPCREL"})
  end
  table.insert(code, {"RAW", caseA .. ":"})
  table.insert(code, {"RSTK"})
  table.insert(code, {"RAW", caseB .. ":"})
  table.insert(code, {"ETCK"})
  switch_unique_cases[astlib.parse_int(stmt[2][2])] = caseA
  local tm = -1
  if handle_stmt(code, stmt[3], -1) == 1 then
   tm = 1
  end
  return tm
 end
 function compilers.label(code, stmt, input_term)
  local caseA = get_unique_label()
  local caseB = get_unique_label()

  table.insert(code, {"STCK"})
  if input_term ~= 1 then
   table.insert(code, {"IMPCREL", caseB})
   table.insert(code, {"RAW", "POPPCREL"})
  end

  -- Work out what kind of label this is,
  --  and either replace something else with a generated label,
  --  or replace the generated label with something else.
  if stmt[2] == "default" then
   if not switch_unique_default then
    error("Default outside switch @ " .. stmt[3])
   end
   switch_unique_default = caseA
  else
   caseA = get_label(stmt[2])
   declared_labels_need_resolution[stmt[2]] = nil
  end

  table.insert(code, {"RAW", caseA .. ":"})
  table.insert(code, {"RSTK"})
  table.insert(code, {"RAW", caseB .. ":"})
  table.insert(code, {"ETCK"})

  local tm = -1
  if handle_stmt(code, stmt[3], -1) == 1 then
   tm = 1
  end
  return tm
 end

 compilers["break"] = function (code, stmt, input_term)
  if input_term ~= 1 then
   if not current_break_label then
    error("Break @ " .. stmt[2] .. " not in any breakable block")
   end
   table.insert(code, {"BRKC"})
   table.insert(code, {"IMPCREL", current_break_label})
   table.insert(code, {"RAW", "POPPCREL"})
  end
  return 1
 end

 compilers["goto"] = function (code, stmt, input_term)
  if input_term ~= 1 then
   -- hidden auto used solely for this operation. :(
   -- *avoid operations which can jump about* if you want performance.
   autos["@outputs.zpu.func@goto_var"] = true
   lockautos["@outputs.zpu.func@goto_var"] = true
   handle_rval(code, stmt[2])
   table.insert(code, {"ASET", "@outputs.zpu.func@goto_var"})
   table.insert(code, {"FSTK"}) -- known to zero tstk.
   table.insert(code, {"AGET", "@outputs.zpu.func@goto_var"}) -- #tstk == 1
   table.insert(code, {"DPOP"}) -- #tstk == 0
   table.insert(code, {"RAW", "POPPC"}) -- and this operation makes it happen
  end
  return 1
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

 for k, v in pairs(declared_labels_need_resolution) do
  if v then
   error("Label " .. k .. " went undeclared.")
  end
 end

 return fc, ft == 1
end