-- Loaded by LazyVim before its plugins. Its defaults are in
-- lazyvim/config/options.lua; only the differences live here.

-- Python: ty for types, definitions and references, ruff for lint and formatting. The
-- python extra enables exactly these two servers and disables pyright.
vim.g.lazyvim_python_lsp = "ty"
vim.g.lazyvim_python_ruff = "ruff"

-- Helix's soft wrap: a long line wraps at a word boundary, its continuation keeps the
-- line's indent, and starts with ↪. LazyVim leaves wrap off.
vim.opt.wrap = true
vim.opt.linebreak = true
vim.opt.breakindent = true
vim.opt.showbreak = "↪ "

-- No keys echoed in the statusline as they are typed (LazyVim shows Vim's showcmd
-- there). Every scroll key flashed in and out, shifting the statusline: on the phone
-- that read as flicker. Space sequences still get the which-key menu.
vim.opt.showcmd = false
