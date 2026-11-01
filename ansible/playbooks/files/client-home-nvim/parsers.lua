-- Run by client-home-nvim.yml as `nvim --headless +"luafile <this>"`. Compiles every
-- treesitter parser LazyVim's config asks for that is not there yet, which needs the
-- tree-sitter CLI and a C compiler. Prints `<installed before> <installed after>
-- <wanted>`, and exits non-zero if any wanted parser is still missing.
local ts = require("nvim-treesitter")
local wanted = LazyVim.opts("nvim-treesitter").ensure_installed or {}

local function count()
  local have = {}
  for _, lang in ipairs(ts.get_installed("parsers")) do
    have[lang] = true
  end
  local n, missing = 0, {}
  for _, lang in ipairs(wanted) do
    if have[lang] then
      n = n + 1
    else
      missing[#missing + 1] = lang
    end
  end
  return n, missing
end

local before = count()
-- Four compilers at once, not nvim-treesitter's default of up to a hundred: on a phone,
-- that many clang processes is how Android's low-memory killer ends Termux mid-build.
-- Thirty minutes is the ceiling for a slow phone.
ts.install(wanted, { summary = false, max_jobs = 4 }):wait(30 * 60 * 1000)
local after, missing = count()

io.stdout:write(("%d %d %d\n"):format(before, after, #wanted))
if #missing > 0 then
  io.stdout:write("MISSING " .. table.concat(missing, " ") .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qall!")
