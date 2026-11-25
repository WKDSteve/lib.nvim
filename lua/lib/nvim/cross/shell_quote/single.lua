---@module 'lib.nvim.cross.shell_quote.single'
--- One word as a POSIX single-quoted string, always: a `'` inside becomes `'\''`. No refusals and no
--- bare words (`lib.nvim.cross.shell_quote.word` does both); for a caller that builds the line
--- itself and checks for NUL and line breaks on its own.

---@param s string
---@return string
return function(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
