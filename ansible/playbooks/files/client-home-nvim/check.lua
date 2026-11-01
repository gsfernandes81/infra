-- Run by client-home-nvim.yml as `nvim --headless +"luafile <this>"`, with
-- NVIM_CHECK_FILE naming a scratch Python file. Proves the parts that only fail at
-- runtime: that ty and ruff start and attach, and that blink.cmp's matcher for this
-- platform downloads and loads. Prints one JSON object; exits non-zero if anything is
-- missing.
local result = { lsp = {}, fuzzy = "not loaded" }

-- blink.cmp fetches a prebuilt matcher for this platform on first use (Termux gets the
-- Android build). Fetched here, so the first edit does not wait on it and a wrong build
-- fails now, not as a slow fallback nobody notices. Loading the plugin runs its setup,
-- which does the fetch and then switches the matcher from the Lua fallback to the native
-- one; waiting on that switch, rather than starting a second fetch, keeps one download in
-- flight.
require("lazy").load({ plugins = { "blink.cmp" } })
local fuzzy = require("blink.cmp.fuzzy")
vim.wait(120000, function()
  return fuzzy.implementation_type == "rust"
end, 200)
result.fuzzy = fuzzy.implementation_type == "rust" and "rust" or "lua fallback (see :messages)"

vim.cmd.edit(vim.env.NVIM_CHECK_FILE)
vim.wait(30000, function()
  local names = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
    names[c.name] = true
  end
  return names.ty and names.ruff
end, 200)
for _, c in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
  result.lsp[#result.lsp + 1] = c.name
end
table.sort(result.lsp)

io.stdout:write(vim.json.encode(result) .. "\n")
local attached = {}
for _, name in ipairs(result.lsp) do
  attached[name] = true
end
if result.fuzzy ~= "rust" or not attached.ty or not attached.ruff then
  vim.cmd("cquit 1")
end
vim.cmd("qall!")
