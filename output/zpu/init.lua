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
local global_local_externs = {}
local global_flist = {}
local data_footer = {}

for k, v in ipairs(ast) do
 if v[1] == "vardef" then
  print(".globl " .. v[2])
  global_variables[v[2]] = true
  global_local_externs[v[2]] = true
 end
 if v[1] == "vecdef" then
  print(".globl " .. v[2])
  global_local_externs[v[2]] = true
 end
 if v[1] == "function" then
  print(".globl " .. v[2])
  global_local_externs[v[2]] = true
 end
end

print(".section .text")

local create_blank_stack_system = require("output.zpu.stmg")
local handle_fstmt = require("output.zpu.func")

local function gen_words(barr)
 local lab = get_unique_label()
 table.insert(data_footer, lab .. ":")
 for _, v in ipairs(barr) do
  table.insert(data_footer, ".long " .. string.format("0x%08x", v))
 end
 return lab
end

local function handle_function(f)
 -- A function is caller-cleanup.
 -- Which is fine, since this exactly matches default ZPU calling convention.
 -- f[3] is the arguments list, f[4] the statement.
 local autos2 = {}
 local lockautos = {}
 local externs = {}
 local body, terminating = handle_fstmt(f[3], f[4], autos2, lockautos, externs, global_variables, get_unique_label, gen_words, string_terminator)
 for k, _ in pairs(externs) do
  if not global_local_externs[k] then
   global_externs[k] = true
  end
 end
 local autos = {}
 for k, _ in pairs(autos2) do
  table.insert(autos, k)
 end
 local fincode = {
  {"IM", tostring(1 - #autos)}, -- NOTE: PUSHSPADD does an implicit *4
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
 local system = create_blank_stack_system(v[3], v[4])
 system.handle_fc(v[2])
end

-- Now just deal with all that data.

print(".section .data")
print(".balign 4,0")

for _, v in ipairs(data_footer) do
 print(v)
end

local function spit_ivals(ic, il)
 for i = 1, ic do
  local v = il[i]
  local vi = ""
  if v then
   if v[1] ~= "id" then
    if v[1] ~= "int" then
     -- If you want anything else, *use the constant evaluator.*
     -- That's what it's there for.
     error("Vector val. must be const. @ " .. v[#v])
    else
     vi = astlib.parse_int(v[2])
    end
   else
    if global_local_externs[v[2]] then
     if not global_variables[v[2]] then
      -- this is probably in "extension" territory
      vi = v[2]
     else
      error("Vector val. ID " .. v[2] .. " variable @ " .. v[3])
     end
    else
     error("Vector val. ID " .. v[2] .. " unknown @ " .. v[3])
    end
   end
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
