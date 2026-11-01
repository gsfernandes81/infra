-- LazyVim's look, changed only where it got in the way on a phone held upright. Each
-- change is one of LazyVim's own settings, so there is no styling here to maintain.
--
--   command line   on the bottom line, as in Helix and Vim, not a box mid-screen
--   inlay hints    off; in portrait they push most lines past the edge. Space u h
--                  turns them on
--   diagnostics    inline text on the cursor's line only; every line's would fall off
--                  a narrow screen. The signs in the gutter stay for every line
--
-- Soft wrap, as in Helix, is in lua/config/options.lua.
return {
  {
    "folke/noice.nvim",
    opts = {
      cmdline = { view = "cmdline" },
      presets = { command_palette = false, bottom_search = true },
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      inlay_hints = { enabled = false },
      diagnostics = { virtual_text = { current_line = true } },
    },
  },
}
