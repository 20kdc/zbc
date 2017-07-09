-- I, 20kdc, release this file into the public domain.
-- No warranty is provided, implied or otherwise.

-- IM encoder.
local imenc
imenc = function (i, mask)
 while i < 0 do i = i + 0x100000000 end
 i = i % 0x100000000

 local lower = i % 128
 local upper = math.floor(i / 128)
 local upper_zero = upper == 0
 local upper_one = upper == mask
 -- work out which matters...
 local upper_ext = upper_zero
 if math.floor(lower / 64) ~= 0 then
  upper_ext = upper_one
 end
 local p = 0x80 + lower
 if upper_ext then
  -- sign-extended
  return p
 end
 local t = {imenc(upper, math.floor(mask / 128))}
 table.insert(t, p)
 return table.unpack(t)
end
return function (i) return imenc(i, 0x1FFFFFF) end
