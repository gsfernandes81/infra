-- LazyVim's look, changed only where it got in the way on a phone held upright. Each
-- change is one of LazyVim's own settings, so there is no styling here to maintain.
--
--   command line   on the bottom line, as in Helix and Vim, not a box mid-screen
--   inlay hints    off; in portrait they push most lines past the edge. Space u h
--                  turns them on
--   diagnostics    inline text on the cursor's line only; every line's would fall off
--                  a narrow screen. The signs in the gutter stay for every line
--   file tree      closes when it opens a file, instead of keeping 40 columns of a
--                  46-column screen
--   start screen   40 columns wide, and its logo only on a screen wide enough for it;
--                  at its default 60, a phone cut off both the logo and the menu's keys
--   statusline     no git branch or clock below 80 columns, which left no room for the
--                  file's name
--   scrolling      not animated. Ctrl-d stepped through six positions on its way, and
--                  the statusline redrew at each; on the phone it flickered
--   hover (K)      drawn by Neovim, not noice. noice sized the popup for unwrapped text,
--                  so on a narrow screen its last lines were cut off; Neovim wraps to the
--                  window each time. To scroll a long one, K again to enter it, then q
--
-- Soft wrap, as in Helix, is in lua/config/options.lua.
return {
  {
    "folke/noice.nvim",
    opts = {
      cmdline = { view = "cmdline" },
      presets = { command_palette = false, bottom_search = true },
      lsp = { hover = { enabled = false } },
    },
  },
  {
    "folke/snacks.nvim",
    opts = {
      picker = { sources = { explorer = { auto_close = true } } },
      scroll = { enabled = false },
      dashboard = {
        width = 40,
        sections = {
          {
            section = "header",
            enabled = function()
              return vim.o.columns >= 70
            end,
          },
          { section = "keys", gap = 1, padding = 1 },
          { section = "startup" },
        },
      },
    },
  },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      local function wide()
        return vim.o.columns >= 80
      end
      for _, name in ipairs({ "lualine_b", "lualine_z" }) do
        for i, component in ipairs(opts.sections[name] or {}) do
          component = type(component) == "table" and component or { component }
          local cond = component.cond
          component.cond = function()
            return wide() and (cond == nil or cond())
          end
          opts.sections[name][i] = component
        end
      end
    end,
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      inlay_hints = { enabled = false },
      diagnostics = { virtual_text = { current_line = true } },
    },
  },
}
