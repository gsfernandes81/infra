-- Loaded by LazyVim after its own keymaps (lazyvim/config/keymaps.lua).

-- Redo on U, as in Helix, so undo and redo need no Ctrl. Vim's own U (undo every change
-- on the last edited line) is rarely wanted and is given up for it.
vim.keymap.set("n", "U", "<C-r>", { desc = "Redo" })
