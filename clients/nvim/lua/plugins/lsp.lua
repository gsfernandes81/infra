-- Language servers come from the system package manager, never from Mason.
--
-- Mason downloads release binaries built for glibc Linux. On Termux those cannot run
-- (Android's libc is bionic), and every server needed here is a Termux and an Arch
-- package. With Mason off there is one way a server arrives on both clients, and the
-- client play installs it.
return {
  { "mason-org/mason.nvim", enabled = false },
  { "mason-org/mason-lspconfig.nvim", enabled = false },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ty = { mason = false },
        ruff = { mason = false },
        -- LazyVim enables lua_ls for editing this config. It is optional here, so a
        -- client without the package skips it instead of failing to start it on every Lua
        -- file.
        lua_ls = { mason = false, enabled = vim.fn.executable("lua-language-server") == 1 },
      },
    },
  },
}
