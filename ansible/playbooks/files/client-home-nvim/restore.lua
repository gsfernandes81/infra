-- Run by client-home-nvim.yml as `nvim --headless --cmd "luafile <this>"`. Puts every
-- plugin at the commit clients/nvim/lazy-lock.json pins, installing any that are missing,
-- and prints one word for the play: `changed` or `unchanged`.
--
-- --cmd, not +: it runs before init.lua, which installs missing plugins on its own as it
-- starts. Snapshotting after that would report a first install as `unchanged`.
local function heads()
  local out = {}
  for _, head in ipairs(vim.fn.glob(vim.fn.stdpath("data") .. "/lazy/*/.git/HEAD", false, true)) do
    out[#out + 1] = head .. "=" .. (vim.fn.readfile(head)[1] or "")
  end
  table.sort(out)
  return table.concat(out, "\n")
end

local before = heads()

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    require("lazy").restore({ wait = true, show = false })

    local failed = {}
    for _, plugin in ipairs(require("lazy").plugins()) do
      if plugin._.has_errors or not plugin._.installed then
        failed[#failed + 1] = plugin.name
      end
    end
    if #failed > 0 then
      io.stdout:write("FAILED " .. table.concat(failed, " ") .. "\n")
      vim.cmd("cquit 1")
    end
    io.stdout:write((heads() == before and "unchanged" or "changed") .. "\n")
    vim.cmd("qall!")
  end,
})
