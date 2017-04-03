-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- quick little informal AST eyeballing tool
-- (which also follows AST specifications,
--  assuming stdio is binary)
local function gla()
 local c = io.read(1)
 local s = ""
 while true do
  if c == "\r" then error("NOPE") end
  if c == "\n" then return s end
  if c == "\t" then return s end
  if c ~= " " then
   s = s .. c
  end
  c = io.read(1)
 end
end
local function gl()
 local t = gla()
 while t:sub(1, 1) == ":" do
  t = gla()
 end
 return t
end

local ti = 0
local mapping = {}
local function dotString(txn)
 local tx = tostring(txn)
 local built = ""
 for i = 1, tx:len() do
  local ch = tx:sub(i, i)
  if ch == "\n" then
   ch = "\\n"
  end
  if ch == "\"" then
   ch = "\\\""
  end
  built = built .. ch
 end
 return "\"" .. built .. "\""
end
local function handle(par, tx)
 local nid = ti
 print("" .. dotString(nid) .. " [label=" .. dotString(tx) .. "];")
 ti = ti + 1
 if par then
  print(" " .. dotString(par) .. " -> " .. dotString(nid) .. ";")
 end
 return nid
end
local function gob(parent, r)
 local rc = r:sub(1, 1)
 if rc == "%" then
  handle(parent, r:sub(2))
  return
 end
 if rc == "$" then
  local t = tonumber(r:sub(2))
  -- let's just hope graphviz doesn't see anything it doesn't like
  local tx = io.read(t)
  io.read(1)
  handle(parent, tx)
  return
 end
 if rc == "{" then
  local tid = handle(parent, "table")
  local stl = gl()
  while stl:sub(1, 1) ~= "}" do
   gob(tid, stl)
   stl = gl()
  end
  return
 end
 if rc == "Y" then
  handle(parent, "Y")
  return
 end
 if rc == "N" then
  handle(parent, "N")
  return
 end
 error("Unk" .. rc)
end

print("digraph tx {")
gob(nil, gl())
print("}")
