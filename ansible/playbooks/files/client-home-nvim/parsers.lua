-- Run by client-home-nvim.yml as `nvim --headless --cmd "luafile <this>"`. Compiles every
-- treesitter parser LazyVim's config asks for that is missing, then rebuilds any whose
-- pinned revision moved with nvim-treesitter. Needs the tree-sitter CLI and a C compiler;
-- clients/nvim/lua/plugins/treesitter.lua limits the compile to four at a time.
--
-- Prints `changed` or `unchanged`, judged by the parser files themselves, and exits
-- non-zero naming any wanted parser that is still missing.

-- Read by clients/nvim/lua/plugins/treesitter.lua, which then hands LazyVim's parser list
-- to this script instead of compiling it as the plugin loads. Set from --cmd, before the
-- config runs.
vim.g.infra_step = "parsers"

local dir = vim.fn.stdpath("data") .. "/site/parser"

local function stamp()
  local out = {}
  for _, f in ipairs(vim.fn.glob(dir .. "/*.so", false, true)) do
    out[#out + 1] = f .. "=" .. vim.fn.getftime(f) .. ":" .. vim.fn.getfsize(f)
  end
  table.sort(out)
  return table.concat(out, "\n")
end

local function run()
  local ts = require("nvim-treesitter")
  local wanted = vim.g.infra_wanted_parsers
  if type(wanted) ~= "table" or #wanted == 0 then
    io.stdout:write("NO LIST: clients/nvim/lua/plugins/treesitter.lua did not hand one over\n")
    vim.cmd("cquit 1")
  end

  local before = stamp()
  -- Thirty minutes each is the ceiling for a slow phone.
  ts.install(wanted, { summary = false }):wait(30 * 60 * 1000)
  ts.update(wanted, { summary = false }):wait(30 * 60 * 1000)

  local have = {}
  for _, lang in ipairs(ts.get_installed("parsers")) do
    have[lang] = true
  end
  local missing = vim.tbl_filter(function(lang)
    return not have[lang]
  end, wanted)

  if #missing > 0 then
    io.stdout:write("MISSING " .. table.concat(missing, " ") .. "\n")
    vim.cmd("cquit 1")
  end
  io.stdout:write((stamp() == before and "unchanged" or "changed") .. "\n")
  vim.cmd("qall!")
end

-- An error in a VimEnter callback is reported and Neovim carries on, which headless means
-- waiting forever with the play holding on it. So any error exits.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local ok, err = pcall(run)
    if not ok then
      io.stdout:write("FAILED: " .. tostring(err) .. "\n")
      vim.cmd("cquit 1")
    end
  end,
})
