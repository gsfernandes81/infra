-- Run by client-home-nvim.yml as `nvim --headless --cmd "luafile <this>"`. Puts every
-- plugin at the commit clients/nvim/lazy-lock.json pins, installing any that are missing,
-- and prints one word for the play: `changed` or `unchanged`.
--
-- --cmd, not +: it runs before init.lua, which installs missing plugins on its own as it
-- starts. Snapshotting after that would report a first install as `unchanged`.
--
-- The proof is each plugin's checked-out commit against the lock file, not lazy.nvim's own
-- report. Tried 2026-11-01 with a commit that does not exist: git said `fatal`, every
-- lazy.nvim task said no error, and lazy.nvim then rewrote lazy-lock.json to the commits
-- it was left on. So this reads the lock before lazy.nvim starts, checks against that, and
-- puts the file's bytes back: the lock is the repo's, and a restore never edits it.

-- Read by clients/nvim/lua/plugins/treesitter.lua: nvim-treesitter is installed and
-- checked out here but not loaded, so no parser compile starts in a process that quits.
vim.g.infra_step = "restore"

local lock_path = vim.fn.stdpath("config") .. "/lazy-lock.json"
local lock_bytes = table.concat(vim.fn.readfile(lock_path, "b"), "\n")
local lock = vim.json.decode(lock_bytes)

-- The commit, resolved: .git/HEAD alone reads `ref: refs/heads/main` when lazy.nvim left
-- a plugin on its branch because the branch tip was already the locked commit.
local function head(dir)
  local out = vim.fn.system({ "git", "-C", dir, "rev-parse", "HEAD" })
  return vim.v.shell_error == 0 and vim.trim(out) or nil
end

local function heads()
  local out = {}
  for _, dir in ipairs(vim.fn.glob(vim.fn.stdpath("data") .. "/lazy/*", false, true)) do
    out[#out + 1] = dir .. "=" .. (head(dir) or "")
  end
  table.sort(out)
  return table.concat(out, "\n")
end

local before = heads()

local function finish(code, line)
  if table.concat(vim.fn.readfile(lock_path, "b"), "\n") ~= lock_bytes then
    vim.fn.writefile(vim.split(lock_bytes, "\n", { plain = true }), lock_path, "b")
  end
  io.stdout:write(line .. "\n")
  vim.cmd(code == 0 and "qall!" or "cquit " .. code)
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local ok, err = pcall(function()
      require("lazy").restore({ wait = true, show = false })
      local wrong = {}
      for _, plugin in ipairs(require("lazy").plugins()) do
        local want = lock[plugin.name] and lock[plugin.name].commit
        if want and head(plugin.dir) ~= want then
          wrong[#wrong + 1] = plugin.name
        end
      end
      if #wrong > 0 then
        return finish(1, "FAILED, not at the locked commit: " .. table.concat(wrong, " "))
      end
      finish(0, heads() == before and "unchanged" or "changed")
    end)
    if not ok then
      finish(1, "FAILED: " .. tostring(err))
    end
  end,
})
