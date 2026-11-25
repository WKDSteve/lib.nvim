---@module 'lib.nvim.bindings.usercmd.prefix'
--- The candidates that start with what the user has typed: the filter every `-complete=customlist`
--- function ends with. An empty lead returns `cands` itself (not a copy), so a caller must not
--- change the result.

---@param cands string[]
---@param lead string
---@return string[]
return function(cands, lead)
  if lead == "" then
    return cands
  end
  local out = {}
  for _, c in ipairs(cands) do
    if c:sub(1, #lead) == lead then
      out[#out + 1] = c
    end
  end
  return out
end
