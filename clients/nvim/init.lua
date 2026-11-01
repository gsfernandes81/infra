-- Neovim on the clients: Termux on the phone, and Arch in WSL on the laptop.
--
-- LazyVim, with ty and ruff for Python and llama.vim for fill-in-the-middle completion
-- from a llama-server. Installed by ansible/playbooks/client-home-nvim.yml, which links
-- ~/.config/nvim to this directory, so an edit here is live on the next start. What
-- each file does and how to update the plugin pins is README.md beside this file.

-- LazyVim keeps which news it has shown, and any extras picked in :LazyExtras, in this
-- file. By default it is beside init.lua, which is the repo. That state is per client, so
-- it lives with the client's other state; the extras every client gets are in
-- lua/config/lazy.lua.
vim.g.lazyvim_json = vim.fn.stdpath("state") .. "/lazyvim.json"

require("config.lazy")
