---@module 'lib.nvim.cross.shell_quote'
--- Pure shell quoting for text that is typed into a terminal.
---
--- Anything that reaches a shell as one *line* must be quoted for **that** shell: a name with a
--- space, `;`, `$(...)`, a backtick or a quote would otherwise be interpreted instead of passed.
--- The shells covered: POSIX (`sh`, `bash`, `zsh`), `fish` (its own single-quote rules: a backslash
--- is an escape inside '...'), PowerShell (`powershell`, `pwsh`) and `cmd.exe`. A shell that is none
--- of them (`nu`, `csh`, ...) is NOT covered and is treated as POSIX -- name it in the `shell`
--- config and the quoting is a guess for it; the "portable" kind (see below) is the safe choice.
---
--- `argv_to_line` and `shell_kind` are the entries callers use (`word`, the quoting
--- of a single word, is only reached through `argv_to_line`); the caller never builds a line from
--- an unquoted string. The first word of a line is the program: POSIX shells and fish quote it
--- unless it is a plain program name (a bare `NAME=value` there is an assignment, `.` is `source`).
--- A word that cannot be represented safely for the shell is **refused**
--- (`nil, err`), never guessed at. What is refused, by family:
---
---   - every family: a control character (line break, TAB, NUL, ESC, ...);
---   - cmd.exe: a `%` (it has no way to quote it);
---   - PowerShell: a word with a double quote, a word with white space that ends in a backslash,
---     the empty word and the word `--%`. How a program started from PowerShell receives the first
---     two differs between Windows PowerShell 5.1, pwsh before 7.3 (legacy argument passing) and
---     later (5.1 splits a word at the quote, drops it, or lets the trailing backslash swallow the
---     NEXT argument), and the other two never arrive (the empty word is dropped by 5.1 and by
---     legacy passing, `--%` by every version, quoted or not), so no single quoting is right;
---     `direct = true` passes the argument without a shell;
---   - "portable" (a multiplexer's unknown shell): anything beyond letters, digits and `. _ / : -`,
---     and a word that starts with a dash and holds a `:` or a `.`;
---   - an argv with a hole (`nil` between two words) in every family: the words after it would be
---     lost without a sound, so it is not a list of words.

local M = {}

---@alias Lib.ShellKind "posix"|"fish"|"powershell"|"cmd"|"portable"

--- Which quoting family a shell belongs to. Unknown shells are treated as POSIX.
---
--- Takes an executable name, a path (spaces allowed) or a command string with arguments
--- (`pwsh -NoLogo`): the family is found by looking for the shell's name as a whole path
--- component or word.
---@param shell string|nil
---@return Lib.ShellKind
function M.shell_kind(shell)
  local normalized = (shell or ""):gsub("\\", "/"):lower()
  local padded = " " .. normalized .. " "
  if padded:find('[/%s"]pwsh[%.%s"]') or padded:find('[/%s"]powershell[%.%s"]') then
    return "powershell"
  end
  if padded:find('[/%s"]cmd[%.%s"]') then
    return "cmd"
  end
  if padded:find('[/%s"]fish[%.%s"]') then
    return "fish"
  end
  return "posix"
end

---@internal
--- Words that are syntax, not a program, when they stand first on a line: the reserved words of
--- POSIX shells (`time -v make` is the `time` keyword, `if x` opens a block), of zsh and of fish.
--- One list for both families: quoting a word that is no keyword in a shell changes nothing there.
local RESERVED = {}
for word in
  ([[and always begin case coproc do done elif else end esac fi for foreach function if in
  nocorrect not or repeat select switch then time until while]]):gmatch("%S+")
do
  RESERVED[word] = true
end

---@internal
--- Whether a word may stand BARE as the program word (the first word of a line) in a POSIX shell
--- or fish. The set is much smaller than the one for an argument: a first word `NAME=value` is an
--- environment assignment (the NEXT word then runs as the command and the program word is eaten),
--- a lone `.` is `source`, `:` the null command, `%1` a job spec, `-` a precommand modifier in
--- zsh, and a reserved word is syntax. A program name is made of letters, digits and `_ / . + -`
--- and starts with a letter, a digit, `_`, `/` or `.` (`./run.sh`); `=` never belongs to it.
--- Anything else is quoted, which stops an assignment and a reserved word from being read as one;
--- what is left, the shell's own builtins of those names (`'.'`, `':'`), it still finds.
---@param s string
---@return boolean
local function bare_program(s)
  return s ~= "." and not RESERVED[s] and s:find("^[%w_/.][%w_/.+-]*$") ~= nil
end

---@internal
---@param s string
---@param program? boolean The word is the program word (first word of the line)
---@return string
local function posix(s, program)
  if s == "" then
    return "''"
  end
  -- Safe characters need no quotes; keeps simple commands readable in the terminal. A leading
  -- dash stays bare on purpose: quoting cannot stop a program from reading a word as an option
  -- (that needs `--`, the caller's business) and `-m` is how an option is written.
  -- `=` is safe everywhere EXCEPT as the first character: zsh (the macOS default shell, same
  -- family here) replaces a word `=ls` by the path of that command, or aborts the line when there
  -- is none. bash and fish read it literally, but the quoted form means the same to all of them.
  -- The program word has its own, smaller set (see `bare_program`).
  if program then
    if bare_program(s) then
      return s
    end
  elseif s:find("^[%w%._/:@%%+,-][%w%._/:=@%%+,-]*$") then
    return s
  end
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

---@internal
--- fish: inside '...' a backslash escapes `\` and `'` (anything else after a backslash stays
--- literal), so both are escaped; the POSIX form `'\''` would leave a lone backslash in front of
--- the next character. Bare words: a deliberately small set (`%` starts a process expansion at the
--- front of a word in fish, `~` expands, `{}` and `*` glob). A leading `=` is literal in fish
--- (unlike zsh, see `posix`), so `=` stays in the set at every position of an argument; the
--- program word has the smaller set of `bare_program` (fish 3.1+ reads `NAME=value` in front of a
--- command as an assignment too).
---@param s string
---@param program? boolean The word is the program word (first word of the line)
---@return string
local function fish(s, program)
  if s == "" then
    return "''"
  end
  if program then
    if bare_program(s) then
      return s
    end
  elseif s:find("^[%w%._/:=@+,-]+$") then
    return s
  end
  local escaped = s:gsub("\\", "\\\\"):gsub("'", "\\'")
  return "'" .. escaped .. "'"
end

---@internal
--- PowerShell treats the typographic single quotes U+2018..U+201B (UTF-8 below) as quote
--- characters too: one inside a '...' string would end it. Each is doubled like the ASCII one.
local CURLY = { "\226\128\152", "\226\128\153", "\226\128\154", "\226\128\155" }

---@internal
--- The white space Windows PowerShell 5.1 looks for (.NET `char.IsWhiteSpace`) when it decides
--- whether a native argument gets wrapped in double quotes: the ASCII blanks, NEXT LINE, NBSP and
--- the Unicode space separators, as UTF-8 patterns. Spelled out because Lua's `%s` knows only the
--- ASCII ones (and depends on the locale for bytes above 127).
local WHITE_SPACE = {
  "[ \t\n\v\f\r]",
  "\194[\133\160]", -- U+0085, U+00A0
  "\225\154\128", -- U+1680
  "\226\128[\128-\138\168\169\175]", -- U+2000..U+200A, U+2028, U+2029, U+202F
  "\226\129\159", -- U+205F
  "\227\128\128", -- U+3000
}

---@internal
---@param s string
---@return boolean
local function has_white_space(s)
  for _, pattern in ipairs(WHITE_SPACE) do
    if s:find(pattern) then
      return true
    end
  end
  return false
end

---@internal
--- PowerShell's language keywords: first on a line they are syntax, not a program.
local POWERSHELL_KEYWORDS = {}
for word in
  ([[begin break catch class clean continue data define do dynamicparam else elseif end enum exit
  filter finally for foreach from function hidden if in param process return static switch throw
  trap try until using var while workflow]]):gmatch("%S+")
do
  POWERSHELL_KEYWORDS[word] = true
end

---@internal
--- The way out the refusals of `powershell` name: `direct` hands the argument to the program
--- itself, so no shell reads it.
local POWERSHELL_HINT =
  "; run it with `direct = true` (the argument is then passed without a shell)"

---@internal
--- PowerShell's single quotes are its own: they are gone before a program sees the word. What the
--- program receives then depends on the PowerShell version. Windows PowerShell 5.1 and pwsh before
--- 7.3 (legacy argument passing) wrap a word in double quotes WITHOUT escaping what is inside: a
--- `"` ends the argument early (`x" --evil "y` becomes three arguments, `a"b` loses its quote),
--- and `C:\my dir\` makes the last backslash escape the closing quote, which swallows the NEXT
--- argument. pwsh 7.3+ gets both right for a program (not for a .bat / .cmd). No single quoting is
--- right for all of them, so a word with a `"`, and a word with white space that ends in a
--- backslash, are refused (same principle as `portable`). The empty word and `--%` are refused for
--- the same reason: they are lost on the way to the program in some or all versions, so every word
--- after them would move up one place.
---@param s string
---@param program? boolean The word is the program word (first word of the line)
---@return string|nil
---@return string|nil err
local function powershell(s, program)
  if s == "" then
    return nil,
      "PowerShell drops an empty argument when it starts a program (Windows PowerShell 5.1 and "
        .. "pwsh with legacy argument passing), so every argument after it would move up one place"
        .. POWERSHELL_HINT
  end
  if s == "--%" then
    return nil,
      "PowerShell reads the word `--%` as its stop-parsing token and removes it, quoted or not, "
        .. "so a program never receives it"
        .. POWERSHELL_HINT
  end
  if s:find('"', 1, true) then
    return nil,
      "PowerShell hands a word with a double quote to a program differently in every version "
        .. "(Windows PowerShell 5.1 splits or drops it), so no quoting is right for it"
        .. POWERSHELL_HINT
  end
  if s:sub(-1) == "\\" and has_white_space(s) then
    return nil,
      "PowerShell hands a word with white space that ends in a backslash to a program "
        .. "differently in every version (Windows PowerShell 5.1 lets the backslash swallow the "
        .. "next argument), so no quoting is right for it"
        .. POWERSHELL_HINT
  end
  -- A deliberately small bare-word set: `@` starts splatting, `,` builds an array, `%` and `+`
  -- can read as an alias or operator, `=` and `$` have meaning. A leading dash stays bare (an
  -- option is written that way) -- except when the word also holds a colon or a dot: once a bare
  -- `--` is on the line, PowerShell reads `-name:value` and `-name.ext` as a parameter with an
  -- attached value and hands the program TWO arguments (`-x:` and `y`, `-I` and `./include`; every
  -- version does, found by sending every such word of up to four characters to the real shells).
  -- In single quotes the word arrives whole. (The consequence for a script or cmdlet that takes
  -- `-Name:Value`: argv words are data, so the word reaches it as one string; write the parameter
  -- and its value as two words, `-Name`, `Value`.)
  -- The program word is read as syntax when it is a keyword (`if`, `while`) or looks like a number
  -- (`7`, `0x10`, `1kb`): quoted, with the call operator in front, it runs the program.
  local syntax = program and (POWERSHELL_KEYWORDS[s:lower()] or s:find("^%d") ~= nil)
  if s:find("^[%w%._/:\\-]+$") and not s:find("^%-.*[:.]") and not syntax then
    return s, nil
  end
  local out = s:gsub("'", "''")
  for _, q in ipairs(CURLY) do
    out = out:gsub(q, q .. q)
  end
  return "'" .. out .. "'", nil
end

---@internal
--- cmd.exe has no way to quote `%VAR%` inside a word (`^` is a literal inside double quotes), so
--- a word containing `%` is refused. A run of backslashes before the closing quote is doubled
--- (otherwise the last one escapes the quote for the C runtime).
---@param s string
---@param program? boolean The word is the program word (first word of the line)
---@return string|nil
---@return string|nil err
local function cmd(s, program)
  if s == "" then
    return '""', nil
  end
  if s:find("%%") then
    return nil, "cmd.exe cannot quote a word containing '%'"
  end
  -- As the program word, `/` and `,` separate (`./tool.exe` runs `.` with the argument `/tool.exe`)
  -- and a leading `@` is the echo prefix: such a word is quoted, which cmd.exe runs as a path.
  local separated = program and (s:find("[/,]") ~= nil or s:sub(1, 1) == "@")
  if s:find("^[%w%._/:\\@+,-]+$") and not separated then
    return s, nil
  end
  -- A run of backslashes in front of an embedded quote is doubled (otherwise the C runtime reads
  -- `\"` as a literal quote and the next quote ends the word: argument injection into the target
  -- program), the quote itself becomes `""`, and a run at the very end is doubled too (it sits in
  -- front of the closing quote). One pass over the bytes: the pattern forms of this
  -- (`(\\*)"`, `(\\+)$`) are quadratic on a long run of backslashes.
  local parts, run = {}, 0
  for i = 1, #s do
    local byte = s:byte(i)
    if byte == 92 then
      run = run + 1
    else
      if byte == 34 then
        parts[#parts + 1] = ("\\"):rep(run * 2) .. '""'
      else
        parts[#parts + 1] = ("\\"):rep(run) .. string.char(byte)
      end
      run = 0
    end
  end
  parts[#parts + 1] = ("\\"):rep(run * 2)
  local body = table.concat(parts)
  return '"' .. body .. '"', nil
end

---@internal
--- For a shell that is not known (a multiplexer pane's default shell): a word is accepted only
--- when it means the same in POSIX shells, PowerShell and cmd.exe -- letters, digits and
--- `. _ / : -`, except a word that starts with a dash and holds a `:` or a `.` (PowerShell splits
--- `-a:b` and `-I./include` in two). There is no quoting that is right for all three, so anything
--- else is refused. One difference stays, because it cannot be told from the pane: a program word
--- with a `/` is a path in POSIX shells and PowerShell but a switch to cmd.exe -- name the `shell`
--- when the pane runs cmd.exe.
---@param s string
---@return string|nil
---@return string|nil err
local function portable(s)
  if s:find("^[%w%._/:-]+$") and not s:find("^%-.*[:.]") then
    return s, nil
  end
  return nil,
    "the terminal runs its multiplexer's default shell, which is unknown here, so this word "
      .. "cannot be quoted for it (set `shell` in the config, or use `direct`)"
end

--- How many words an argv list has: its highest positive integer index. `#` and `ipairs` stop at
--- the first hole, so `{ "git", "clean", "-fd", nil, "--dry-run" }` would lose its last word
--- without a trace -- and the safety flag with it. A hole is then found by the caller as "word N is
--- not a string" and refused.
---@param argv any
---@return integer
function M.arg_count(argv)
  if type(argv) ~= "table" then
    return 0
  end
  local n = 0
  for k in pairs(argv) do
    if type(k) == "number" and k > n and k % 1 == 0 then
      n = k
    end
  end
  return n
end

--- Quote one word for the given shell family.
---
--- `program` says the word is the first word of a line, the one a shell runs: POSIX shells and fish
--- read a bare `NAME=value` there as an environment assignment (and `.`, `:`, `%1` as a builtin or a
--- job) and a reserved word (`time`, `if`) as syntax, so only a plain program name stays bare in
--- that place; PowerShell does the same for its keywords and for a word that reads as a number, and
--- cmd.exe quotes a program word that holds a `/` or `,` or starts with `@`.
---@param s string
---@param kind Lib.ShellKind
---@param program? boolean The word is the program word (first word of the line)
---@return string|nil word
---@return string|nil err # Set when the word cannot be represented safely for this shell
function M.word(s, kind, program)
  if kind == "powershell" then
    return powershell(s, program)
  elseif kind == "cmd" then
    return cmd(s, program)
  elseif kind == "portable" then
    return portable(s)
  elseif kind == "fish" then
    return fish(s, program), nil
  end
  return posix(s, program), nil
end

--- A command line for `argv`, every word quoted for the shell family.
---
--- PowerShell needs the call operator when the program word itself is quoted
--- (`& 'C:\Program Files\x.exe' ...`); it is added only then. POSIX shells and fish quote the
--- program word unless it is a plain program name (`NAME=value` would be an assignment there, see
--- `bare_program`). Every control character is refused (line breaks, NUL, ESC, ... and TAB): a
--- line break would end the command line, the others are interpreted by the terminal's line editor
--- -- a TAB makes readline / PSReadLine / cmd.exe complete INSIDE the quotes and close them, which
--- breaks the quoting.
---@param argv string[] Non-empty; every element a string
---@param kind Lib.ShellKind
---@return string|nil line
---@return string|nil err
function M.argv_to_line(argv, kind)
  local n = M.arg_count(argv)
  if n == 0 then
    return nil, "empty command"
  end
  local words = {}
  for i = 1, n do
    local a = argv[i]
    if type(a) ~= "string" then
      return nil, ("argument %d is not a string"):format(i)
    end
    if a:find("[%z\1-\31\127]") then
      return nil,
        ("argument %d contains a control character (line break, TAB, NUL, ESC, ...)"):format(i)
    end
    local w, err = M.word(a, kind, i == 1)
    if not w then
      return nil, ("argument %d: %s"):format(i, err)
    end
    words[i] = w
  end
  local line = table.concat(words, " ")
  if kind == "powershell" and words[1]:sub(1, 1) == "'" then
    line = "& " .. line
  end
  return line, nil
end

return M
