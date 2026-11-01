-- Syntax parsers compile four at a time, wherever the compile starts.
--
-- nvim-treesitter runs up to a hundred compilers at once by default. On a phone, that
-- many clang processes is how Android's low-memory killer ends Termux mid-build. LazyVim
-- starts a compile on its own when a wanted parser is missing, as do :TSInstall,
-- :TSUpdate and the plugin's build step after `:Lazy update`, and none of them passes a
-- limit. So the limit goes on nvim-treesitter's two entry points, which all of them call.
--
-- client-home-nvim.yml runs Neovim headless in two steps and names the step in
-- vim.g.infra_step; in an editing session it is unset and none of that applies.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    -- The restore step installs plugins and quits, so a compile LazyVim started there
    -- would be killed half done. Not loaded, the plugin is still installed at its
    -- pinned commit.
    cond = vim.g.infra_step ~= "restore",
    opts = function(_, opts)
      -- The parsers step compiles LazyVim's list itself. LazyVim compiling the same list
      -- as the plugin loads would build each parser twice at once, racing on its files.
      if vim.g.infra_step == "parsers" then
        vim.g.infra_wanted_parsers = opts.ensure_installed
        opts.ensure_installed = {}
      end

      local install = require("nvim-treesitter.install")
      if install.infra_max_jobs then
        return
      end
      install.infra_max_jobs = 4
      for _, name in ipairs({ "install", "update" }) do
        local fn = install[name]
        install[name] = function(languages, options)
          return fn(languages, vim.tbl_extend("keep", options or {}, { max_jobs = install.infra_max_jobs }))
        end
      end
    end,
  },
}
