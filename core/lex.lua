-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- B Lexer (more lenient than the original)

local patterns = {
 -- These get filtered out before they even touch the parser.
 {"%/%*.-%*%/", "wsc"},
 {"[\t\r\n ]+", "ws"},
 {"%/%/.-\n", "wsl"},

 -- this hits a special case
 {"\"", "STRING"},
 -- turns out a 'character' can be any number
 --  of characters up to the machine word size.
 {"'", "STRING"},

 {"[0-9]+", "int"},

 {"[a-zA-Z_%.\x80-\xFF][a-zA-Z_%.\x80-\xFF0-9]*", "id"},

 {"%:", "colon"},
 {"%;", "semicolon"},
 {"%(", "lp"},
 {"%)", "rp"},
 {"%,", "comma"},
 {"%{", "lb"},
 {"%}", "rb"},
 {"%[", "ls"},
 {"%]", "rs"},

 {"%+%+", "op"},
 {"%-%-", "op"},

 -- assign ops
 {"%=%=%=", "op"},
 {"%=%!%=", "op"},
 {"%=%<%=", "op"},
 {"%=%>%=", "op"},
 {"%=%<%<", "op"},
 {"%=%>%>", "op"},

 {"%=%|", "op"},
 {"%=%&", "op"},
 {"%=%<", "op"},
 {"%=%>", "op"},
 {"%=%+", "op"},
 {"%=%-", "op"},
 {"%=%%", "op"},
 {"%=%*", "op"},
 {"%=%/", "op"},

 -- two-char ops
 {"%=%=", "op"},
 {"%!%=", "op"},
 {"%<%=", "op"},
 {"%>%=", "op"},
 {"%<%<", "op"},
 {"%>%>", "op"},

 {"%+", "op"},
 {"%-", "op"},
 {"%%", "op"},
 {"%*", "op"},
 {"%/", "op"},

 {"%|", "op"},
 {"%^", "op"}, -- honeywell, XOR
 {"%&", "op"},

 {"%?", "op"},

 -- unary ops which do NOT double as binary ops
 {"%!", "op"},
 {"%~", "op"}, -- honeywell, NOT

 {"%=", "op"},
 {"%<", "op"},
 {"%>", "op"},
}

local function strmatch(str)
 local tp = str:sub(1, 1)
 local built = tp
 local working = str:sub(2)
 while true do
  if working == "" then error("Early EOF") end
  local ch = working:sub(1, 1)
  local r = ch
  if ch == tp then
   return built .. r
  end
  if ch == "*" then
   r = working:sub(1, 2)
  end
  built = built .. r
  working = working:sub(r:len() + 1)
 end
end

local function trymatch(str)
 for _, v in ipairs(patterns) do
  local t = str:match("^" .. v[1])
  if t then
   if v[2] == "STRING" then
    -- String has to have specific handling.
    local tstr = strmatch(str)
    local r = "string"
    if v[1] == "'" then
     r = "char"
    end
    return str:sub(tstr:len() + 1), tstr, r
   else
    return str:sub(t:len() + 1), t, v[2]
   end
  end
 end
end

return {["run"] = function (str, args)
 local line = 1
 local tbl = {}
 while str:len() > 0 do
  str, tkn, tkt = trymatch(str)
  if not tkn then
   error("Unable to identify token @ line " .. line)
  end
  local ignore = false
  if tkt == "wsl" then ignore = true end
  if tkt == "wsc" then ignore = true end
  if tkt == "ws" then ignore = true end
  if not ignore then
   table.insert(tbl, {tkt, tkn, line})
  end
  local nl = tkn:find("\n")
  while nl do
   line = line + 1
   nl = tkn:find("\n", nl + 1)
  end
 end
 return tbl
end, ["input"] = "string", ["output"] = "tokenlist"}
