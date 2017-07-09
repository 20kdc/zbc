-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- ZPU Assembler.
-- This describes the subset of ZPU/GAS assembly that ZBC uses.
-- (need to add offset-on-global-address, incredibly specific as that is.)

local imenc = require("asm.zpu.imenc")

return {["run"] = function(text, args)
 -- "item" format has type as [1], and then type-specific parameters.
 -- But in particular:
 -- SYM, [string]
 --  Just for symbols
 -- DB, [byte]
 --  byte (most instructions)
 -- ALIGN, [align]
 --  generate alignment
 -- IM, [function], [string]...
 --  IMs. The function takes it's own ID and the resolved symbols and returns an integer.
 --  The function can make any calculation it wants, this way.
 --  The linker will continue to relink until it stabilizes,
 --   and thus addresses are correct.

 -- Stage 2/3 Functions
 
 local items = {}
 -- Provides an upper bound on how long an item will be the first time around.
 -- Generated items have their lengths altered.
 -- Assembly and linking is complete when this stabilizes.
 local item_len = {}
 -- item_adr is prepared by gen_world_machine using get_item_baselen
 local item_adr = {}
 local function get_item_baselen(addr, x, v)
  if item_len[x] then return item_len[x] end
  if v[1] == "DB" then
   return 1
  end
  if v[1] == "SYM" then
   return 0
  end
  if v[1] == "ALIGN" then
   return v[2] - 1
  end
  if v[1] == "IM" then
   return 5
  end
  error("TxD" .. items[x][1])
  return 0
 end
 local symtab_2
 local function gen_item(addr, x, v)
  if v[1] == "DB" then
   return string.char(v[2])
  end
  if v[1] == "SYM" then
   symtab_2[v[2]] = addr
   return ""
  end
  if v[1] == "ALIGN" then
   -- Depends on address...
   local disalign = (v[2] - (addr % v[2])) % v[2]
   return string.rep("\x00", disalign)
  end
  if v[1] == "IM" then
   local extras = {}
   for i = 3, #v do
    extras[i - 2] = v[i]
   end
   return string.char(imenc(v[2](x, table.unpack(extras))))
  end
  error("TyD" .. v[1])
 end
 local function gen_world_machine()
  -- Work out addresses.
  local p = 0
  for i = 1, #items do
   item_adr[i] = p
   p = p + get_item_baselen(p, i, items[i])
  end
  item_adr[#items + 1] = p
  local ns = ""
  local continuer = false
  symtab_2 = {}
  for i = 1, #items do
   local s = gen_item(item_adr[i], i, items[i])
   if s:len() ~= item_len[i] then continuer = true end
   item_len[i] = s:len()
   ns = ns .. s
  end
  return ns, continuer
 end

 -- Stage 2 Functions

 local symtab = {}
 local function symdecl_item(x, v)
  if v[1] == "SYM" then
   symtab[v[2]] = x
  end
 end
 local function resolve_item(x, v)
  if v[1] == "IM" then
   for i = 3, #v do
    local sym = symtab[v[i]]
    if not sym then error("Unresolved sym: " .. v[i]) end
    v[i] = sym
   end
  end
 end

 -- Stage 1.

 local section_text = {}
 local section_data = {}
 local section_bss = {}
 local sections = {
  [".text"] = section_text,
  [".data"] = section_data,
  [".bss"] = section_bss
 }
 local target_section = section_text

 local scope = "UNK "
 -- Scope is not prefixed to these.
 local globals = {}

 local ops = {
  ["breakpoint"] = 0,
  -- (non-IM) opcodes
  ["pushsp"] = 2,
  ["poppc"] = 4,
  ["add"] = 5,
  ["and"] = 6,
  ["or"] = 7,
  ["load"] = 8,
  ["not"] = 9,
  ["flip"] = 10,
  ["nop"] = 11,
  ["store"] = 12,
  ["popsp"] = 13,
  ["loadh"] = 34,
  ["storeh"] = 35,
  ["lessthan"] = 36,
  ["lessthanorequal"] = 37,
  ["ulessthan"] = 38,
  ["ulessthanorequal"] = 39,

  -- 8 missing

  ["mult"] = 41,
  ["lshiftright"] = 42,
  ["ashiftleft"] = 43,
  ["ashiftright"] = 44,

  -- 13 missing

  ["eq"] = 46,
  ["neq"] = 47,
  ["neg"] = 48,

  ["sub"] = 49,
  ["xor"] = 50,

  ["loadb"] = 51,
  ["storeb"] = 52,
  ["div"] = 53,
  ["mod"] = 54,
  ["eqbranch"] = 55,
  ["neqbranch"] = 56,
  ["poppcrel"] = 57,
  -- they apparently ran out of things to do here.
  ["pushspadd"] = 61,
  -- 62 is syscall IIRC...
  ["callpcrel"] = 63,
 }
 for i = 0, 15 do
  ops["addsp_" .. (i * 4)] = i + 0x10
 end
 for i = 0, 31 do
  local p = i
  if i > 15 then p = p - 16 else p = p + 16 end
  ops["storesp_" .. (p * 4)] = i + 0x40
  ops["loadsp_" .. (p * 4)] = i + 0x60
 end
 for t in text:gmatch("[^\n]+") do
  local wordget = t:gmatch("[^ ]+")
  local c = wordget()
  -- transform various
  if c:lower() == "addsp" then
   c = "addsp_" .. wordget()
  end
  if c:lower() == "loadsp" then
   c = "loadsp_" .. wordget()
  end
  if c:lower() == "storesp" then
   c = "storesp_" .. wordget()
  end
  -- main elseif chain
  if c == ".balign" then
   local a = wordget()
   if a:sub(a:len() - 1) ~= ",0" then
    error("The subset requires '.balign' end with ,0 (no offset)")
   end
   table.insert(target_section, {"ALIGN", tonumber(a:sub(1, a:len() - 2))})
  else
   if c == ".long" then
    -- Big-endian number.
    local n = tonumber(wordget())
    while n < 0 do n = n + 0x100000000 end
    local l1 = n % 0x100
    n = math.floor(n / 0x100)
    local l2 = n % 0x100
    n = math.floor(n / 0x100)
    local l3 = n % 0x100
    n = math.floor(n / 0x100)
    local l4 = n % 0x100
    table.insert(target_section, {"DB", l4})
    table.insert(target_section, {"DB", l3})
    table.insert(target_section, {"DB", l2})
    table.insert(target_section, {"DB", l1})
   else
    if c == ".section" then
     target_section = sections[wordget()]
    else
     if c == ".extern" then
      globals[wordget()] = true
     else
      if c:lower() == "im" or c:lower() == "impcrel" then
       local ipr = c:lower() == "impcrel"
       local val = wordget()
       local vlk = val
       if tonumber(val) then
        vlk = nil
       else
        if not globals[vlk] then
         vlk = scope .. vlk
        end
       end
       -- oh, this'll be fun.
       table.insert(target_section, {"IM", function (mx, tx)
        local v2 = tonumber(val)
        if tx then v2 = item_adr[tx] end
        if ipr then
         return v2 - item_adr[mx + 1]
        end
        return v2
       end, vlk})
      else
       if c == ".globl" then
        globals[wordget()] = true
       else
        if c == ".scope" then
         globals = {}
         scope = ""
         local w = wordget()
         while w do
          scope = scope .. w .. " "
          w = wordget()
         end
        else
         local op = ops[c:lower()]
         if not op then
          if c:sub(c:len(), c:len()) == ":" then
           local vlk = c:sub(1, c:len() - 1)
           if not globals[vlk] then
            vlk = scope .. vlk
           end
           table.insert(target_section, {"SYM", vlk})
          else
           if c ~= "//" then
            error("Unrecognized: " .. c)
           end
          end
         else
          table.insert(target_section, {"DB", op})
         end
        end
       end
      end
     end
    end
   end
  end
 end
 -- Prepared! Now dump all sections to items... (Stage 2)
 for _, v in ipairs(section_text) do table.insert(items, v) end
 for _, v in ipairs(section_data) do table.insert(items, v) end
 for _, v in ipairs(section_bss) do table.insert(items, v) end
 -- Resolve symbols to items
 for k, v in ipairs(items) do
  symdecl_item(k, v)
 end
 for k, v in ipairs(items) do
  resolve_item(k, v)
 end

 -- Stage 3

 for i = 1, 128 do
  local wm, c = gen_world_machine()
  -- If all lengths are unchanged, all is well.
  if not c then
   --for pos = 1, wm:len() do
   -- for k, v in pairs(symtab_2) do
   --  if pos == v then
   --   io.stderr:write(k .. " " .. v .. "\n")
   --  end
   -- end
   --end
   return wm
  end
 end
 error("Tried 128 linking iterations. Linking unresolvable.")
end, ["input"] = "string", ["output"] = "string"}
