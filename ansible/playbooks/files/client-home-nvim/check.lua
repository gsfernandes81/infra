-- Run by client-home-nvim.yml as `nvim --headless +"luafile <this>"`, with
-- NVIM_CHECK_FILE naming a scratch Python file. Proves the parts that only fail at
-- runtime: that ty and ruff start and attach, and that blink.cmp's matcher for this
-- platform downloads and loads. Prints one JSON object; exits non-zero if anything is
-- missing, or on any error, since headless Neovim would otherwise sit open after one.
local result = { lsp = {}, fuzzy = "not loaded" }

local function run()
  -- blink.cmp fetches a prebuilt matcher for this platform on first use (Termux gets the
  -- Android build). Fetched here, so the first edit does not wait on it and a wrong build
  -- fails now, not as a slow fallback nobody notices. Loading the plugin runs its setup,
  -- which does the fetch and then switches the matcher from the Lua fallback to the
  -- native one; waiting on that switch, rather than starting a second fetch, keeps one
  -- download in flight.
  require("lazy").load({ plugins = { "blink.cmp" } })
  local fuzzy = require("blink.cmp.fuzzy")
  vim.wait(120000, function()
    return fuzzy.implementation_type == "rust"
  end, 200)
  result.fuzzy = fuzzy.implementation_type == "rust" and "rust" or "lua fallback (see :messages)"

  vim.cmd.edit(vim.env.NVIM_CHECK_FILE)
  local attached = {}
  vim.wait(30000, function()
    attached = {}
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
      attached[c.name] = true
    end
    return attached.ty and attached.ruff
  end, 200)
  result.lsp = vim.tbl_keys(attached)
  table.sort(result.lsp)
  return result.fuzzy == "rust" and attached.ty and attached.ruff
end

local ok, passed = pcall(run)
if not ok then
  result.error = tostring(passed)
end
io.stdout:write(vim.json.encode(result) .. "\n")
vim.cmd(ok and passed and "qall!" or "cquit 1")
