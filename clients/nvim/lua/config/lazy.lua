-- The plugin manager and the plugin list.
--
-- lazy-lock.json beside init.lua pins every plugin to a commit. `:Lazy restore` installs
-- exactly those commits; `:Lazy update` moves them, and the changed lock file is then a
-- change to commit, so the phone and the laptop run the same plugins.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  local repo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", repo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    -- Headless (the client play) has nobody to press a key, and would wait forever.
    if not vim.tbl_contains(vim.v.argv, "--headless") then
      vim.fn.getchar()
    end
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    { import = "lazyvim.plugins.extras.lang.python" },
    { import = "plugins" },
  },
  defaults = {
    lazy = false,
    -- Latest commit rather than latest tag: the lock file is what pins.
    version = false,
  },
  install = { colorscheme = { "tokyonight", "habamax" } },
  -- No background update checks. The phone is on a metered connection, and an update is
  -- a deliberate `:Lazy update` followed by a commit of the lock file.
  checker = { enabled = false },
  change_detection = { notify = false },
  -- No plugin here needs luarocks, and building it on Termux is slow.
  rocks = { enabled = false },
  performance = {
    rtp = {
      -- The LazyVim starter also disables "tutor". It stays on here: `:Tutor` is how
      -- the motions are learned.
      disabled_plugins = { "gzip", "tarPlugin", "tohtml", "zipPlugin" },
    },
  },
})
