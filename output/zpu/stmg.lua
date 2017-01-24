-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- Should the PU command actually do it's job?
-- (Disable for easier debugging, as it won't run the potentially erroring simulations.)
local pu_run_simulations = true

-- Should the PU command look far into the future to thus determine the absolute best configuration?
-- Warning: This can increase CPU time used by the compiler by a lot,
--  as a full run of the stack manager into the future is performed, and it doesn't actually remember the choices made right now.
-- So it will end up being cpu_time_of_first_PU + (cpu_time_of_second_PU * 4) + (cpu_time_of_third_PU * 4 * 4)...
-- If you are encountering errors on a PU, you should disable this,
--  as the errors may be somewhere "inner".
local pu_look_farfuture = false
-- Debugging feature, annotates output code with information about AGET/ASET/etc.
local blank_annotate = true

-- Function code is written via a multi-stage process:
-- 1. The function code is written with a wrapping assembly,
--     used to drive the stack management routines.
--    The available instructions are:
--    IM: May as well be RAW, "IM <arg>" if not for the automatic NOP insertion.
--    IMPCREL: see IM
--    RAW: Raw ZPU assembly. Will turn off the IM concatenation prevention flag.
--    RAWLB: Raw ZPU assembly. Will turn off the IM concatenation prevention flag,
--                              but prepends a NOP before the RAW to do so (so the NOP stays outside of loops)
--    AUTO: Assign pstk variable. (stale)
--    ARG: Assign pstk variable. (not stale)
--    
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

aget_flow_breakers["FSTK"] = true
aget_flow_breakers["BRKC"] = true
aget_flow_breakers["RSTK"] = true

aget_flow_breakers["STCK"] = true
aget_flow_breakers["SBCK"] = true

aget_flow_breakers["ETCK"] = true
aget_flow_breakers["TTCK"] = true

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

--    IM/IMPCREL: Used for automatic insertion of NOPs where needed.
--                (NOTE: These do not count from a stack-management perspective,
--                       just assume you wrote RAW IM/RAW IMPCREL, only it adds a NOP if needed.)

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
-- Note the two-container strategy used to ensure no actual 'conditional' stuff happens
-- RAW .L.1:
-- SBCK
-- <condition code> <-- CANNOT safely break!
-- DPOP
-- IMPCREL .L.2
-- RAW EQBRANCH
-- SBCK
--  <run code>
-- ETCK
-- BRKC
-- IMPCREL .L.1
-- RAW POPPCREL
-- RAW .L.2: <-- Break in while does a BRKC (taking it out of the inner code container) and jumps here for conditional code cleanup
-- ETCK

-- 'break':
-- BRKC
-- IMPCREL .L.2
-- RAW POPPCREL

-- 'label': eeek this is bad
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

 local function printstack(tstk, prefix)
  local building = "// " .. prefix .. ";"
  for _, v in ipairs(tstk) do
   local ls = "<T>"
   if v ~= "" then
    ls = v
   end
   building = building .. " " .. ls
  end
  print(building .. " <pv0> <pv1> <pv2>...")
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
   printstack(tstk, tostring(chks))
  end
  local heavyduty = #tstk > 6
  for i = 1, chks do
   local k = 1
   local v = tstk[1]
   if heavyduty then
    k = i
    v = tstk[i]
   end
   if v ~= "" then
    -- Important thing
    local pv, ofs, st = find_on_stack(pstk, chkp, v)
    local chksC = (#tstk - #chkp)
    ofs = ofs + (4 * chksC)
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
      --print("// Factors " .. chksC .. ";" .. dofs .. ";" .. tostring(pv))
      print("STORESP " .. ofs)
      global_last_was_im = false
     end
     if pv then
      -- No longer stale.
      pstk[v][2] = false
     else
      if chkp[dofs - chksC] ~= v then error("consistency failure") end
      tstk[dofs] = v
      --if not fake then
      -- print("// CHECKME, " .. dofs .. " wanted, " .. (dofs - chksC) .. " tIdx, " .. chkp[dofs - chksC])
      --end
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
    -- Here all cases result in the first entry being removed
    table.remove(tstk, 1)
   end
  end
  -- commence flush
  local chksCF = (#tstk - #chkp)
  if chksCF > 0 then
   if not heavyduty then
    error("Stack not being managed properly?")
   end
   while #tstk > #chkp do
    table.remove(tstk, 1)
   end
   if not fake then
    -- +1 and the lack of a *4 is occupational hazard of using PUSHSPADD
    print("IM " .. (chksCF + 1))
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
   if v[1] == "RAWLB" then
    if (not lastraw) and annotate_fc then
     print("// RAWLB:")
    end
    if global_last_was_im then
     print("NOP")
    end
    print(v[2])
    global_last_was_im = false
    lastraw = true
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
   if annotate_fc then print("// " .. (#tstk) .. " " .. tostring(global_last_was_im) .. " " .. v[1]) end
   if v[1] == "ARG" then
    pstk[v[2]] = {v[3], false}
    if annotate_fc then print("// " .. v[2] .. "@" .. v[3]) end
    return
   end
   if v[1] == "AUTO" then
    pstk[v[2]] = {v[3], true}
    if annotate_fc then print("// " .. v[2] .. "@" .. v[3]) end
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
   if v[1] == "RSTK" then
    -- FSTK was just called. You have A SHORT AMOUNT OF TIME to rebuild the stack.
    -- What do you do?
    -- (NOTE: RSTK is inefficient because it's rebuilding the stack under ridiculous conditions.
    --        This is why anything resembling a GOTO is a pain to work with for compilers.
    --        I suggest avoiding GOTO.)
    local vstk = {}
    if annotate_fc then printstack(tstk, "rstk") end
    -- This has to account for checkpoints properly.
    -- Checkpoints phase out variables and then return them at the end,
    --  which means every checkpoint level needs to be satisfied.
    local stacks = {tstk}
    for _, v in ipairs(envstk) do
     table.insert(stacks, 1, v[1])
    end
    for _, v in ipairs(stacks) do
     local wanted = #v - #vstk
     for i = 1, wanted do
      local ri = (#v + 1) - i
      local rv = v[ri]
      if rv == "" then
       print("PUSHSP")
       global_last_was_im = false
      else
       -- Note: The "stale" flag is ignored since it's the stack flusher's job to fix that.
       -- However, it can't be explicitly turned off since it's conditional if RSTK runs or not.
       local ps, pos, stale = find_on_stack(pstk, vstk, rv, lockautos[rv])
       if annotate_fc then print("// " .. rv .. "@" .. pos) end
       print("LOADSP " .. pos)
       global_last_was_im = false
      end
      table.insert(vstk, 1, rv)
     end
    end
    return
   end
   if v[1] == "AGET" then
    local ps, pos, stale = find_on_stack(pstk, tstk, v[2], lockautos[v[2]])
    if stale then
     error("Auto " .. v[2] .. " has been lost. TSTK: " .. (#tstk) .. ", LOCK: " .. tostring(not not lockautos[v[2]]))
    end
    -- This should never happen if a locked auto is in use,
    --  but not a good reason to find out.
    if (not ps) and (not lockautos[v[2]]) then
     local barecheck = false
     if envstk[1] then
      if #tstk == #(envstk[1][1]) then
       barecheck = true
      end
     end
     if (pos == 0) and not barecheck then
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
     if global_last_was_im then
      print("NOP")
     end
     print("IM _memreg")
     print("STORE")
     global_last_was_im = false
     dpop()
    end
    local vp = (#tstk) + autocount
    if vp > 0 then
     if annotate_fc then print("// tstk " .. #tstk .. " ; ac " .. autocount) end
     if vp > 3 then
      if global_last_was_im then
       print("NOP")
      end
      print("IM " .. (vp + 1)) -- +1 and the lack of a *4 occupational hazard PUSHSPADD
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
    -- The +1 and the lack of a *4  is an occupational hazard of using PUSHSPADD rather than PUSHSP IM <num> ADD.
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
    -- This is a complicated command.

    local backlook = {}
    local bkv = lookahead()
    while bkv do
     table.insert(backlook, bkv)
     bkv = lookahead()
    end

    local function makelookahead(ref, k, tgt)
     local pk = k
     local rk = 0
     return function ()
      pk = pk + 1
      if not tgt[pk] then
       rk = rk + 1
       return ref[rk]
      end
      return tgt[pk]
     end
    end

    local target = 2
    -- a lot of lines
    local targetlines = 0xFFFFFFF
    local targetinner = 0xFFFFFFF

    -- Used to see if it was worth bothering to look deep into the future
    local target_optinner = 2
    local target_optinnerlines = 0xFFFFFFF

    if pu_run_simulations then
     local universe_debug = false
     for i = 2, #v do
      local l = 0
      local li = 0
      local ns = nil
      local innercount = true
       if universe_debug then
       print("// PU ID " .. i)
       ns = system.clone(function (s) l = l + 1 if innercount then li = li + 1 end print(s) end, true)
      else
       ns = system.clone(function (s) l = l + 1 if innercount then li = li + 1 end end, false)
      end
      local lookahead_prime = makelookahead(backlook, 0, v[i])
      local lap_data = {}
      local lkv = lookahead_prime()
      while lkv do
       table.insert(lap_data, lkv)
       lkv = lookahead_prime()
      end
      for k, sv in ipairs(lap_data) do
       if k > #(v[i]) then innercount = false end
       if innercount or pu_look_farfuture then
        ns.handle_sc(makelookahead({}, k, lap_data), sv)
       end
      end
      if l < targetlines then
       target = i
       targetlines = l
       targetinner = li
      end
      if li < target_optinnerlines then
       target_optinner = i
       target_optinnerlines = li
      end
      if universe_debug then print("// End Virtual Consideration") end
     end
    end
    -- Worked out the best target, use it
    for k, sv in ipairs(v[target]) do
     system.handle_sc(makelookahead(backlook, k, v[target]), sv)
    end
    if annotate_fc then print("// [/PU (used U" .. (target - 1) .. "@" .. targetlines .. " lines, " .. targetinner .. " inner.)]") end
    if annotate_fc and (target_optinner ~= target) then print("// The above PU was improved by far-future checks.") end
    return
   end
   error("cannot handle " .. v[1])
  end, ["clone"] = function(printer, annotate)
   local unpack = unpack or table.unpack
   local r = cloner({pstk, tstk, envstk, breaking, instant, lastraw, global_last_was_im, annotate, autocount, lockautos})
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
  end, ["ensure_safe_termination"] = function ()
   if #envstk > 0 then
    error("Left-over environment stack")
   end
  end}
 return system
end
local function create_blank_stack_system(autocount, lockautos, printer)
 local pstk = {}
 local tstk = {}
 local envstk = {}
 local breaking = nil
 local instant = 0
 local lastraw = false
 local global_last_was_im = false

 return create_stack_system(pstk, tstk, envstk, breaking, instant, lastraw, global_last_was_im, blank_annotate, autocount, lockautos, printer)
end
return create_blank_stack_system