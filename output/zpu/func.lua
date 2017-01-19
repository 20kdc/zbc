return function (args, stmt, autos, lockautos, global_variables, get_unique_label)
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
  if not likeautos[rv[2]] then
   error("Unknown ID " .. rv[2] .. " @ " .. rv[3])
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
  table.insert(code, {"RAW", "IM " .. astlib.parse_int(rv[2])})
  table.insert(code, {"DTMP"})
 end

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
  simpleops["+"] = {"ADD", true}
  simpleops["-"] = {"SUB"}
  simpleops["*"] = {"SLOWMULT"}
  simpleops["/"] = {"DIV", true}
  simpleops["%"] = {"MOD", true}
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
   table.insert(code, {"RAW", simpleops[rv[2]][1]})
   table.insert(code, {"DTMP"})
   return
  end
  if rv[2] == "=" then
   -- It doesn't work that way.
   if mode then modeerror(rv) end
   handle_rval(code, rv[4])
   handle_rval(code, rv[3], "set")
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
    table.insert(code, {"RAW", simpleops[opn][1]})
    table.insert(code, {"DTMP"})
    handle_rval(code, rv[3], "set", lstate)
    return
   end
  end
  error("Unrecognized PBOP " .. rv[2] .. " @ " .. rv[5])
 end

 -- STMT COMPILERS --

 function compilers.compound(code, stmt, input_term)
  table.insert(code, {"STCK"})
  local terminating = input_term
  for _, v in ipairs(stmt[2]) do
   local t = handle_stmt(code, v, terminating)
   if t ~= 0 then
    terminating = t
   end
  end
  if terminating == 1 then
   -- don't bother
   table.insert(code, {"TTCK"})
  else
   table.insert(code, {"ETCK"})
  end
  return terminating
 end

 function compilers.rvalue(code, stmt, input_term)
  handle_rval(code, stmt[2])
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

 local fc = {}
 local ft = handle_stmt(fc, stmt, -1)
 return fc, ft == 1
end