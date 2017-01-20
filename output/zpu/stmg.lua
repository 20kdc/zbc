-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- Function code is written via a multi-stage process:
-- 1. The function code is written with a wrapping assembly,
--     used to drive the stack management routines.
--    The available instructions are:
--    IM: May as well be RAW, "IM <arg>" if not for the automatic NOP insertion.
--    AGET: Pull an automatic.
--          This may or may not alter stack.
--          Some instructions are "flow breakers",
--           and if a ASET is not found before one,
--           then some optimizations cannot safely be performed.
--          (Note that another "AGET" *can* be a flow breaker under certain conditions.)
--          Should the compiler fail with the message "Auto <name> has been lost.",
--           this is one of the things which may be critical to fixing the issue.
--          The instructions marked as "flow breakers" are:
local aget_flow_breakers = {}
aget_flow_breakers["BRKC"] = true
aget_flow_breakers["FSTK"] = true
aget_flow_breakers["STCK"] = true
aget_flow_breakers["SBCK"] = true
-- RSTK is safe because the stack will be reassembled with the AGET in mind.

--    APTR: Pull the address of an automatic from pstk.
--          The automatic SHOULD be set as a direct automatic.
--    DTMP: Define a useless temporary.
--          You should use this whenever something is pushed to stack for any meaningful length.
--          Intermediates as part of one statement don't count.
--    DPOP: Remove the top of the temporary stack.
--          If the top of stack is the only copy of the current value of an automatic,
--           this will bring the automatic out of play until it is reset via another value.
--    ASET: Define a temporary containing the new value of an automatic.
--          This will either pop the result value or leave it there.
--          If it does or does not depends on if it's determined to be more optimal.
--    FSTK: Write code for a complete stack flush. Does not actually affect stack management.
--          Used for "GOTO"-like constructs.
--    RSTK: Write code that, assuming FSTK was 'just' run execution-wise, rebuilds stack.
--    RETN: Write return code. Assumes the return value has been marked as a temporary.
--    RETV: Write return-void code.
--    STCK: Set temporary stack checkpoint.
--    SBCK: Set temporary stack checkpoint, also setting the previous checkpoint as the 'break target checkpoint'
--    BRKC: Write code to return to the break target checkpoint without affecting the working model of the stack.
--          Used for break.
--    ETCK: Write code to return to stack checkpoint,
--           and exit the stack checkpoint.
--    TTCK: ETCK, but without writing code.
--    RAW: Raw ZPU assembly.
--    AUTO: Assign pstk variable. (stale)
--    ARG: Assign pstk variable. (not stale)
--    HOLD: Put the current length of the temporary stack into cmd[2][1].
--    RELE: The arguments to this are "cmd[2]" objects passed to HOLD, from BOS to TOS.
--          This will ensure the stack layout is correct, *potentially* generating stack objects in the process.
--    IST+: Increase the Instant number by 1.
--          This number is used as a hint in order to avoid stack wastage that would lower performance.
--    IST-: Decrease the Instant number by 1, unless it's 0, in which case error.
--    PU: Ask the stack management system to guess which of two paths is more efficient,
--         and it will write out the more efficient path.
--        Useful when the code's only difference is the ordering of things.
--        (Was really annoying to implement.)

-- The general point of this is that if stack accesses are well-timed,
--  a situation like:
--   auto a;
--   a = somefunc();
--   a += 2;
--  will result in efficient code.
-- The RETN and RETV pseudo-instructions exist as a "cheat", to end the stack as soon as possible.
-- As it takes 4 instructions to advance SP by an arbitrary amount,
-- and 6 instructions to store a stackframe pointer, then load it later,
--  (*before* adding in the cost of holding the last stackframe pointer)
-- it is pretty clear that this method, though requiring further analysis of the code,
--  will result in more efficient code overall.

-- Example notes;
-- Note that all conditionals have stack checkpointing immediately after the the branch.
-- This serves two purposes:
-- 1. Alerting any optimization code that something important is about to happen,
--     and it shouldn't try anything clever crossing one of these boundaries,
--     since it could generate invalid code that way
-- 2. Cleaning up after whatever happens in the conditional so code flow makes sense.
-- Note that there is also a legitimate reason for stack checkpoints to, by themselves, be "important":
--  it is expected that anything done to the core stack within a stack checkpoint will be reverted.
-- 'if':
-- <condition code>
-- DPOP
-- IMPCREL .L.1
-- RAW EQBRANCH
-- STCK
--  <run code>
-- ETCK
-- RAW .L.1:

-- 'if/else':
-- <condition code>
-- DPOP
-- IMPCREL .L.1
-- RAW EQBRANCH
-- STCK
--  <run code 2>
-- ETCK
-- IMPCREL .L.2
-- RAW POPPCREL
-- RAW .L.1:
-- STCK
--  <run code 2>
-- ETCK
-- RAW .L.2:

-- 'while':
-- RAW .L.1:
-- SBCK
-- <condition code>
-- DPOP
-- IMPCREL .L.2
-- RAW EQBRANCH
--  <run code>
-- ETCK
-- IMPCREL .L.1
-- RAW POPPCREL
-- RAW .L.2:

-- 'break':
-- BRKC
-- IMPCREL .L.2
-- RAW POPPCREL

-- 'label': (note that the stack checkpoint causes a duplicate-clean to make RSTK faster)
-- STCK
-- IMPCREL .L.1
-- RAW .LAB.labelid:
-- RSTK
-- RAW .L.1:
-- ETCK

-- 'goto' (known label ID):
-- FSTK
-- IMPCREL <label>
-- RAW POPPCREL

-- The actual system, helper function for PU cloning.
local function cloner(t, map)
 local root = false
 if not map then map = {} root = true end
 if t == nil then return nil end
 local tp = type(t)
 if tp == "string" then return t end
 if tp == "number" then return t end
 if tp == "boolean" then return t end
 if tp == "table" then
  if map[t] then return map[t] end
  local nt = {}
  map[t] = nt
  for k, v in pairs(t) do
   nt[cloner(k, map)] = cloner(v, map)
  end
  return nt
 end
 error("Cannot handle cloning of " .. tp)
end

-- "lockautos" is used for cases where pointers to an auto are used.
-- In this case, the auto has to be consistently read from the same place.
local create_stack_system = nil
create_stack_system = function (pstk, tstk, envstk, breaking, instant, lastraw, global_last_was_im, annotate_fc, autocount, lockautos, print)
 -- Stack System Brief

 -- pstk is "permanent context".
 -- It maps auto IDs to LOADSP targets assuming an empty tstk.
 -- For example, pstk["arg0"] = {4, false},
 --  assuming a function (arg0) with no automatics.
 -- The boolean value indicates if this value is currently stale.

 -- tstk is "temporary context".
 -- Temporary context is used to reduce the amount of stack management work.
 -- Rather than ensure all "leftover" stack is cleaned up,
 --  and storing automatics properly,
 --  instead everything is held in the current temporary context.
 -- This has the beneficial effect of making "useless autos" only take up an 
 --  additional instruction upon function entry.
 -- It also allows a "stack flush" operation
 --   to skip over any leftover stack in a maximum of 4 instructions.

 -- The first entry in tstk is the top of stack, last is bottom of stack.
 -- tstk entries are autonames, with "" meaning useless temp.
 -- tstk entries get blanked out if needed.

 -- Via this system, designed with a stack machine in mind,
 --  more efficient code should be produced.

 -- Finds an auto.
 local function find_on_stack(pstk, tstk, aid)
  for i = 1, #tstk do
   if tstk[i] == aid then
    return false, (i - 1) * 4, false
   end
  end
  if not pstk[aid] then
   error("Could not find " .. aid .. " anywhere")
  end
  return true, (pstk[aid][1] + #tstk) * 4, pstk[aid][2]
 end

 -- Flushes stack to a given length.
 -- tstk is the current stack, while chkp is the stack as it was.
 -- It is assumed that chkp is a subset of tstk,
 --  but with some useless temps being autonames.
 -- In this case, the values must be returned there so everything
 --  checks out properly.
 local function stack_flush(pstk, tstk, chkp, fake)
  local chks = (#tstk - #chkp)
  -- tstk 2, chkp 1, result is 1, so indexes > 1 are in checkpoint.
  if (not fake) and annotate_fc then
   local building = "// " .. chks .. ";"
   for _, v in ipairs(tstk) do
    local ls = "<T>"
    if v ~= "" then
     ls = v
    end
    building = building .. " " .. ls
   end
   print(building .. " <pv0> <pv1> <pv2>...")
  end
  local heavyduty = #tstk > 6
  for i = 1, chks do
   local v = tstk[1]
   if heavyduty then
    v = tstk[i]
   end
   if v ~= "" then
    -- Important thing
    local pv, ofs, st = find_on_stack(pstk, chkp, v)
    ofs = ofs + (4 * (#tstk - #chkp))
    local dofs = math.floor(ofs / 4) + 1
    -- if it's already fine on this stack, don't bother
    if tstk[dofs] ~= v then
     if heavyduty then
      if not fake then
       print("LOADSP " .. (4 * (i - 1)))
       global_last_was_im = false
      end
      ofs = ofs + 4
     end
     if not fake then
      print("STORESP " .. ofs)
      global_last_was_im = false
     end
     if pv then
      -- No longer stale.
      pstk[v][2] = false
     else
      if chkp[dofs - chks] ~= v then error("consistency failure") end
      tstk[dofs] = v
     end
    else
     -- can be discarded
     if not heavyduty then
      if not fake then
       print("STORESP 0")
       global_last_was_im = false
      end
     end
    end
   else
    -- can be discarded
    if not heavyduty then
     if not fake then
      print("STORESP 0")
      global_last_was_im = false
     end
    end
   end
   if not heavyduty then
    table.remove(tstk, 1)
   end
  end
  -- commence flush
  if heavyduty then
   while #tstk > #chkp do
    table.remove(tstk, 1)
   end
   if not fake then
    -- +1 is occupational hazard of using PUSHSPADD
    print("IM " .. (chks + 1))
    print("PUSHSPADD")
    print("POPSP")
    global_last_was_im = false
   end
  end
  -- Now the length is the same, finish off the revert.
  for i = 1, #chkp do
   tstk[i] = chkp[i]
  end
 end

 local function dpop()
  if not tstk[1] then error("internal dpop underflow") end
  table.remove(tstk, 1)
 end
 local function clean_duplicates()
  local seen = {}
  for k, v in ipairs(tstk) do
  if v ~= "" then
    if seen[v] then
     tstk[k] = ""
    end
    seen[v] = true
   end
  end
 end
 local system = nil
 system = {["handle_sc"] = function (lookahead, v)
   if v[1] == "IM" then
    if global_last_was_im then
     print("NOP")
    end
    print("IM " .. v[2])
    global_last_was_im = true
    lastraw = false
    return
   end
   if v[1] == "IMPCREL" then
    if global_last_was_im then
     print("NOP")
    end
    print("IMPCREL " .. v[2])
    global_last_was_im = true
    lastraw = false
    return
   end
   if v[1] == "RAW" then
    if (not lastraw) and annotate_fc then
     print("// RAW:")
    end
    print(v[2])
    global_last_was_im = false
    lastraw = true
    return
   end
   lastraw = false
   if annotate_fc then print("// " .. (#tstk) .. " " .. v[1]) end
   if v[1] == "ARG" then
    pstk[v[2]] = {v[3], false}
    return
   end
   if v[1] == "AUTO" then
    pstk[v[2]] = {v[3], true}
    return
   end
   if v[1] == "STCK" then
    -- Before beginning, make "duplicate" tstk auto copies useless.
    -- This is because only the first copy will be restored by the stack flusher if required.
    -- ex.
    -- ASET test
    -- loop{
    -- STCK
    -- AGET test
    -- ETCK
    -- }
    -- would cause a not-entirely-required restore of the original test?
    -- ...no, because the AGET would presumably get dealt with by whatever's using it
    -- unless the AGET managed to somehow enter another checkpoint boundary,
    --  in which case all bets are off, but at that point...
    -- but OTOH
    -- ASET test
    -- loop{
    -- STCK
    -- AGET test
    -- ETCK
    -- }
    clean_duplicates()
    table.insert(envstk, 1, {tstk, breaking})
    local nstk = {}
    for k, v in ipairs(tstk) do
     nstk[k] = v
    end
    tstk = nstk
    return
   end
   if v[1] == "SBCK" then
    clean_duplicates()
    table.insert(envstk, 1, {tstk, breaking})
    breaking = tstk
    local nstk = {}
    for k, v in ipairs(tstk) do
     nstk[k] = v
    end
    tstk = nstk
    return
   end
   if v[1] == "AGET" then
    local ps, pos, stale = find_on_stack(pstk, tstk, v[2], lockautos[v[2]])
    if stale then
     error("Auto " .. v[2] .. " has been lost.")
    end
    -- This should never happen if a locked auto is in use,
    --  but not a good reason to find out.
    if (not ps) and (not lockautos[v[2]]) then
     if pos == 0 then
      local function canopt()
       local w = "// OPTTRACE:"
       local t = lookahead()
       local puc = 0
       while t do
        local tp = t[1]
        w = w .. " " .. tp
        if aget_flow_breakers[tp] then
         return false, w
        end
        if tp == "AGET" then
         if t[2] == v[2] then
          return false, w
         end
        end
        if tp == "ASET" then
         if puc == 0 then
          if t[2] == v[2] then
           return true, w
          end
         end
        end
        if tp == "RETV" then
         if puc == 0 then
          return true, w
         end
        end
        if tp == "RETN" then
         if puc == 0 then
          return true, w
         end
        end
        if tp == "PU" then
         -- Note: This way of handling things is a bit flawed in that
         --  it won't accept a case in which all universes allow the optimization to work.
         -- However, I haven't even yet managed to get a case
         --  in which half this code legitimately runs, so, deal with that later.
         -- (The majority of situations are "ASET PU AGET", running from *within* the chosen PU.)
         puc = puc + 1
         local uind = 2
         local ind = 1
         local nt = t
         local last = lookahead
         lookahead = function ()
          while not nt[uind][ind] do
           uind = uind + 1
           ind = 1
           if not nt[uind] then
            w = w .. " endPU"
            lookahead = last
            puc = puc - 1
            return lookahead()
           else
            w = w .. " |"
           end
          end
          local r = nt[uind][ind]
          ind = ind + 1
          return r
         end
        end
        t = lookahead()
       end
       return false, w
      end
      local canoptr, canoptt = canopt()
      if annotate_fc then print(canoptt) end
      if canoptr then
       if lockautos[v[2]] then
        -- make absolutely sure
        dpop()
        table.insert(tstk, 1, "")
       end
       return
      end
     end
    end
    print("LOADSP " .. pos)
    -- There are now multiple copies of the auto,
    --  but all are currently valid.
    if lockautos[v[2]] then
     -- If locked, the auto must never be referred to via another pointer.
     table.insert(tstk, 1, "")
    else
     table.insert(tstk, 1, v[2])
    end
    global_last_was_im = false
    return
   end
   if v[1] == "ASET" then
    -- This is a stack management command, basically.
    dpop()
    pstk[v[2]][2] = true
    for i = 1, #tstk do
     if tstk[i] == v[2] then
      tstk[i] = ""
     end
    end
    if lockautos[v[2]] or (instant ~= 0) then
     -- In this case, the root must be kept up to date.
     local np = (#tstk) + pstk[v[2]][1] + 1
     print("STORESP " .. (np * 4))
     global_last_was_im = false
     pstk[v[2]][2] = false
    else
     table.insert(tstk, 1, v[2])
    end
    return
   end
   if (v[1] == "BRKC") or (v[1] == "FSTK") then
    local tmpk = {}
    local tmps = {}
    for k, v in ipairs(tstk) do
     tmpk[k] = v
    end
    for k, v in pairs(pstk) do
     tmps[k] = {v[1], v[2]}
    end
    if v[1] == "FSTK" then
     stack_flush(tmps, tmpk, {}) -- about to jump, so do all work in clones
    else
     stack_flush(tmps, tmpk, breaking) -- etc.
    end
    return
   end
   if v[1] == "ETCK" then
    local otk = table.remove(envstk, 1)
    stack_flush(pstk, tstk, otk[1])
    breaking = otk[2]
    return
   end
   if v[1] == "TTCK" then
    local otk = table.remove(envstk, 1)
    stack_flush(pstk, tstk, otk[1], true)
    breaking = otk[2]
    return
   end
   if (v[1] == "RETV") or (v[1] == "RETN") then
    if v[1] == "RETN" then
     print("IM _memreg")
     print("STORE")
     global_last_was_im = false
     dpop()
    end
    local vp = (#tstk) + autocount
    if vp > 0 then
     if annotate_fc then print("// tstk " .. #tstk .. " ; ac " .. autocount) end
     if vp > 3 then
      print("IM " .. (vp + 1)) -- +1 occupational hazard PUSHSPADD
      print("PUSHSPADD")
      print("POPSP")
     else
      for i = 1, vp do
       print("STORESP 0")
      end
     end
    end
    print("POPPC")
    global_last_was_im = false
    return
   end
   if v[1] == "DTMP" then
    table.insert(tstk, 1, "")
    return
   end
   if v[1] == "DPOP" then
    dpop()
    return
   end
   if v[1] == "HOLD" then
    v[2][1] = #tstk
    return
   end
   if v[1] == "RELE" then
    -- The optimal case is where the stack is:
    -- <TOS> A B C D <BOS>
    -- and A B C D is wanted.
    -- RELE goes from BOS to TOS.
    -- As it is, only the bottom half of a stack can be safely copied.
    local matchc = 0
    for m = 1, (#v - 1) do
     local ok = true
     for i = 1, m do
      -- m is the expected stack size
      local eofs = m - i
      local r = v[i + 1][1]
      local ofs = (#tstk) - r
      if ofs ~= eofs then
       ok = false
      end
     end
     if ok then
      matchc = m
     end
    end
    for i = 2 + matchc, #v do
     local r = v[i][1]
     local ofs = ((#tstk) - r) * 4
     print("LOADSP " .. ofs)
     global_last_was_im = false
     table.insert(tstk, 1, "")
    end
    return
   end
   if v[1] == "APTR" then
    -- The +1 is an occupational hazard of using PUSHSPADD rather than PUSHSP IM <num> ADD.
    print("IM " .. (((#tstk) + pstk[v[2]][1]) + 1))
    print("PUSHSPADD")
    global_last_was_im = false
    table.insert(tstk, 1, "")
    return
   end
   if v[1] == "IST+" then
    instant = instant + 1
    return
   end
   if v[1] == "IST-" then
    if instant == 0 then error("IST imbalance") end
    instant = instant - 1
    return
   end
   if v[1] == "PU" then
    -- For now, just go with the first universe.
    -- This will be properly implemented if/when the stack management system is properly refactored.
    -- (NOTE: Other commands that are checking for optimization barriers
    --   should look at all universes, as they are all possible by specification.)
    local target = 2
    -- a lot of lines
    local targetlines = 0xFFFFFFF

    local backlook = {}
    local bkv = lookahead()
    while bkv do
     table.insert(backlook, bkv)
     bkv = lookahead()
    end

    local function makelookahead(k, tgt)
     local pk = k
     local rk = 0
     return function ()
      pk = pk + 1
      if not v[tgt][pk] then
       rk = rk + 1
       return backlook[rk]
      end
      return v[tgt][pk]
     end
    end

    for i = 2, #v do
     local l = 0
     local ns = system.clone(function () l = l + 1 end)
     for k, sv in ipairs(v[i]) do
      ns.handle_sc(makelookahead(k, i), sv)
     end
     if l < targetlines then
      target = i
      targetlines = l
     end
    end
    for k, sv in ipairs(v[target]) do
     system.handle_sc(makelookahead(k, target), sv)
    end
    if annotate_fc then print("// [/PU (used U" .. (target - 1) .. "@" .. targetlines .. ")]") end
    return
   end
   error("cannot handle " .. v[1])
  end, ["clone"] = function(printer)
   local unpack = unpack or table.unpack
   local r = cloner({pstk, tstk, envstk, breaking, instant, lastraw, global_last_was_im, false, autocount, lockautos})
   r[#r + 1] = printer
   return create_stack_system(unpack(r))
  end, ["handle_fc"] = function (fc)
   for k, v in ipairs(fc) do
    local pk = k
    system.handle_sc(function ()
     pk = pk + 1
     return fc[pk]
    end, v)
   end
  end}
 return system
end
local function create_blank_stack_system(autocount, lockautos)
 local pstk = {}
 local tstk = {}
 local envstk = {}
 local breaking = nil
 local instant = 0
 local lastraw = false
 local global_last_was_im = false

 local annotate_fc = false

 return create_stack_system(pstk, tstk, envstk, breaking, instant, lastraw, global_last_was_im, annotate_fc, autocount, lockautos, print)
end
return create_blank_stack_system