return function (args, stmt, autos, lockautos, global_variables, get_unique_label)
 -- returns: termination setting
 -- terminating flags from this can be:
 -- -1: Force non-termination
 --  0: Neutral
 --  1: Force termination
 local compilers = {}
 -- returns: nothing for now
 local valcompilers = {}
 local function handle_stmt(code, stmt)
  if not compilers[stmt[1]] then
   error("No handler for " .. stmt[1] .. " @ " .. stmt[#stmt])
  end
  return compilers[stmt[1]](code, stmt)
 end
 -- Mode can be nil (default), "set", or "ptr".
 local function handle_rval(code, rv, mode)
  if not valcompilers[rv[1]] then
   error("No handler for " .. rv[1] .. " @ " .. rv[#rv])
  end
  return valcompilers[rv[1]](code, rv, mode)
 end

 -- RVAL COMPILERS --

 function valcompilers.id(code, rv, mode)
  if mode then error("Mode not acceptable") end
  table.insert(code, {"AGET", rv[2]})
 end

 function valcompilers.puop(code, rv, mode)
  if not rv[4] then
   if rv[2] == "-" then
    if mode then error("Mode not acceptable") end
    handle_rval(code, rv[3])
    table.insert(code, {"DPOP"})
    table.insert(code, {"RAW", "NEG"})
    table.insert(code, {"DTMP"})
    return
   end
  end
  error("Unrecognized PUOP " .. rv[2] .. " @ " .. rv[5])
 end

 -- STMT COMPILERS --

 function compilers.compound(code, stmt)
  table.insert(code, {"STCK"})
  local terminating = 0
  for _, v in ipairs(stmt[2]) do
   local t = handle_stmt(code, v)
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

 function compilers.rvalue(code, stmt)
  handle_rval(code, stmt[2])
  return 0
 end

 local fc = {}
 local ft = handle_stmt(fc, stmt)
 return fc, ft == 1
end