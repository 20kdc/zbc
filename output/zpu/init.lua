-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- Zylin ZPU backend for ZBC.
-- (i.e. "Finally some workable output!")

-- It is advisable to run through cnsteval before usage.
-- Parameters should be "-C -B -DWORD_CHARS 4",
--  to enable converting character constants,
--  make sure they come out big-endian,
--  and change references to WORD_CHARS to 4.
-- (This backend can handle character constants fine,
--   but things like ('a' - 'A') get resolved this way.)

local astlib = require("ast")
local ast = astlib.read_mshl(io.stdin)

-- By specification, this should be \x04
local string_terminator = "\x00"

local uniqueid = 0
local function get_unique_label()
 local p = uniqueid
 uniqueid = uniqueid + 1
 return "L" .. uniqueid
end

-- By default, an extern will be considered a vector,
--  which means the address will be returned.
-- (Note: Not sure if this is to-spec or not.
--  Some stuff in the Honeywell tutorial suggests that for auto vectors,
--   an additional auto is created as a pointer to the rest.
--  Unsure how relevant that is here.)
local global_variables = {}
-- this is used later
local global_externs = {}
local global_flist = {}
for k, v in ipairs(ast) do
 if v[1] == "vardef" then
  print(".globl " .. v[2])
  global_variables[v[2]] = true
 end
 if v[1] == "vecdef" then
  print(".globl " .. v[2])
 end
 if v[1] == "function" then
  print(".globl " .. v[2])
 end
end

print(".section .text")

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
 if not fake then
  io.write("// " .. chks .. ";")
  for _, v in ipairs(tstk) do
   local ls = "<T>"
   if v ~= "" then
    ls = v
   end
   io.write(" " .. ls)
  end
  print(" <pv0> <pv1> <pv2>...")
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
   if heavyduty then
    if not fake then print("LOADSP " .. (4 * (i - 1))) end
    ofs = ofs + 4
   end
   if not fake then print("STORESP " .. ofs) end
   if pv then
    -- No longer stale.
    pstk[v][2] = false
   else
    if chks[dofs - chks] ~= v then error("consistency failure") end
    tstk[dofs] = v
   end
  else
   if not heavyduty then
    if not fake then print("STORESP 0") end
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
  end
 end
 -- Now the length is the same, finish off the revert.
 for i = 1, #chkp do
  tstk[i] = chkp[i]
 end
end

-- Function code is written via a multi-stage process:
-- 1. The function code is written with a wrapping assembly,
--     used to drive the stack management routines.
--    The available instructions are:
--    IM: May as well be RAW, "IM <arg>" if not for the automatic NOP insertion.
--    AGET: Pull an automatic.
--          This may or may not alter stack.
--    APTR: Pull the address of an automatic from pstk.
--          The automatic SHOULD be set as a direct automatic.
--    DTMP: Define a useless temporary.
--          You should use this whenever something is pushed to stack for any meaningful length.
--          Intermediates as part of one statement don't count.
--    DPOP: Remove the top of the temporary stack.
--          If the top of stack is the only copy of the current value of an automatic,
--           this will bring the automatic out of play until it is reset via another value.
--    ASET: Define a temporary containing the new value of an automatic.
--          This consistently leaves the result value on stack in position.
--    FSTK: Write code for a complete stack flush. Does not actually affect stack management.
--          Used for "GOTO"-like constructs.
--    RSTK: Write code that, assuming FSTK was 'just' run execution-wise, rebuilds stack.
--    RETN: Write return code. Assumes the return value has been marked as a temporary.
--    RETV: Write return-void code.
--    STCK: Set temporary stack checkpoint.
--    SBCK: Set temporary stack checkpoint, also setting the previous checkpoint as the 'break target checkpoint'
--    ETCK: Write code to return to stack checkpoint,
--           and exit the stack checkpoint.
--    TTCK: ETCK, but without writing code.
--    BRKC: Write code to return to the break target checkpoint without affecting the working model of the stack.
--          Used for break.
--    RAW: Raw ZPU assembly.
--    AUTO: Assign pstk variable. (stale)
--    ARG: Assign pstk variable. (not stale)
--    HOLD: Put the current length of the temporary stack into cmd[2][1].
--    RELE: The arguments to this are "cmd[2]" objects passed to HOLD, from BOS to TOS.
--          This will ensure the stack layout is correct, *potentially* generating stack objects in the process.
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
-- 'if':
-- RAW IMPCREL .L.1
-- RAW EQBRANCH
-- STCK
--  <run code>
-- ETCK
-- RAW .L.1:
-- 'if/else':
-- RAW IMPCREL .L.1
-- RAW EQBRANCH
-- STCK
--  <run code 2>
-- ETCK
-- RAW IM .L.2
-- RAW POPPCREL
-- RAW .L.1:
-- STCK
--  <run code 2>
-- ETCK
-- RAW .L.2:

-- 'while':
-- RAW .L.1:
-- RAW IMPCREL .L.2
-- RAW EQBRANCH
-- SBCK
--  <run code>
-- ETCK
-- RAW IMPCREL .L.1
-- RAW POPPCREL
-- RAW .L.2:

-- 'break':
-- BRKC
-- RAW IMPCREL .L.2
-- RAW POPPCREL

-- 'label':
-- RAW IMPCREL .L.1
-- RAW .LAB.labelid:
-- RSTK
-- RAW .L.1:

-- 'goto':
-- FSTK
-- RAW POPPCREL

-- "lockautos" is used for cases where pointers to an auto are used.
-- In this case, the auto has to be consistently read from the same place.
local function handle_fc(fc, autocount, lockautos)
 local pstk = {}
 local tstk = {}
 local envstk = {}
 local breaking = nil
 local lastwasim = false
 local function dpop()
  if not tstk[1] then error("internal dpop underflow") end
  table.remove(tstk, 1)
 end
 local function handle_sc(k, v)
  if v[1] == "IM" then
   if lastwasim then
    print("NOP")
   end
   print("IM " .. v[2])
   lastwasim = true
   return
  end
  lastwasim = false
  if v[1] == "RAW" then
   print(v[2])
   return
  end
  print("// " .. (#tstk) .. " " .. v[1])
  if v[1] == "ARG" then
   pstk[v[2]] = {v[3], false}
   return
  end
  if v[1] == "AUTO" then
   pstk[v[2]] = {v[3], true}
   return
  end
  if v[1] == "STCK" then
   table.insert(envstk, 1, {tstk, breaking})
   local nstk = {}
   for k, v in ipairs(tstk) do
    nstk[k] = v
   end
   tstk = nstk
   return
  end
  if v[1] == "SBCK" then
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
   if not ps then
    if pos == 0 then
     print("// Potential.opt: maybe possible to bring auto out of play")
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
   return
  end
  if v[1] == "ASET" then
   -- This is a stack management command, basically.
   pstk[v[2]][2] = true
   for i = 1, #tstk do
    if tstk[i] == v[2] then
     tstk[i] = ""
    end
   end
   if lockautos[v[2]] then
    table.insert(tstk, 1, "")
    -- In this case, the root must be kept up to date.
    print("LOADSP 0")
    local np = (#tstk) + pstk[v[2]][1] + 1
    print("STORESP " .. (np * 4))
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
    dpop()
   end
   local vp = (#tstk) + autocount
   if vp > 0 then
       print("// tstk " .. #tstk .. " ; ac " .. autocount)
       print("IM " .. (vp + 1)) -- +1 occupational hazard PUSHSPADD
       print("PUSHSPADD")
       print("POPSP")
   end
   print("POPPC")
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
    table.insert(tstk, 1, "")
   end
   return
  end
  if v[1] == "APTR" then
   -- The +1 is an occupational hazard of using PUSHSPADD rather than PUSHSP IM <num> ADD.
   print("IM " .. (((#tstk) + pstk[v[2]][1]) + 1))
   print("PUSHSPADD")
   table.insert(tstk, 1, "")
   return
  end
  error("cannot handle " .. v[1])
 end
 for k, v in ipairs(fc) do
  handle_sc(k, v)
 end
end

local handle_fstmt = require("output.zpu.func")

local function handle_function(f)
 -- A function is caller-cleanup.
 -- Which is fine, since this exactly matches default ZPU calling convention.
 -- f[3] is the arguments list, f[4] the statement.
 local autos2 = {}
 local lockautos = {}
 local externs = {}
 local body, terminating = handle_fstmt(f[3], f[4], autos2, lockautos, externs, global_variables, get_unique_label)
 for k, _ in pairs(externs) do
  global_externs[k] = true
 end
 local autos = {}
 for k, _ in pairs(autos2) do
  table.insert(autos, k)
 end
 local fincode = {
  {"IM", tostring(1 - #autos)},
  {"RAW", "PUSHSPADD"},
  {"RAW", "POPSP"}
 }
 if #autos < 3 then
  fincode = {}
  for i = 1, #autos do
   -- Doesn't exactly matter *what* is pushed, only that it is.
   -- There are no initialization values for autos.
   table.insert(fincode, {"RAW", "PUSHSP"})
  end
 end
 for k, v in ipairs(f[3]) do
  -- notably, the "+ k" includes the 1-offset for avoiding the return address.
  table.insert(fincode, {"ARG", v, (#autos) + k})
 end
 for k, v in ipairs(autos) do
  table.insert(fincode, {"AUTO", v, k - 1})
 end
 for _, v in ipairs(body) do
  table.insert(fincode, v)
 end
 -- for now just insert this at the end.
 if not terminating then
  table.insert(fincode, {"RETV"})
 end
 table.insert(global_flist, {f[2], fincode, #autos, lockautos})
end

for k, v in ipairs(ast) do
 if v[1] == "function" then
  handle_function(v)
 end
end

for k, _ in pairs(global_externs) do
 print(".extern " .. k)
end

for _, v in ipairs(global_flist) do
 print(v[1] .. ":")
 handle_fc(v[2], v[3], v[4])
end

-- Now just deal with all that data.

print(".section .data")
print(".balign 4,0")

local function spit_ivals(ic, il)
 for i = 1, ic do
  local v = il[i]
  local vi = 0
  if v then
   if v[1] ~= "int" then
    -- If you want anything else, *use the constant evaluator.*
    -- That's what it's there for.
    error("Vector size must be const. int @ line " .. v[#v])
   end
   vi = astlib.parse_int(v[2])
  end
  print(".long " .. vi)
 end
end

for k, v in ipairs(ast) do
 if v[1] == "vardef" then
  print(v[2] .. ":")
  local mz = 1
  local ivl = #v[3]
  if ivl > mz then
   mz = ivl
  end
  spit_ivals(mz, v[3])
 end
 if v[1] == "vecdef" then
  print(v[2] .. ":")
  if v[3][1] ~= "int" then
   -- If you want anything else, *use the constant evaluator.*
   -- That's what it's there for.
   error("Vector size must be const. int @ line " .. v[3][#(v[3])])
  end
  local mz = astlib.parse_int(v[3][2])
  local ivl = #v[4]
  if ivl > mz then
   mz = ivl
  end
  spit_ivals(mz, v[4])
 end
end
