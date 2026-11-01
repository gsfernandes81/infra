-- Fill-in-the-middle completion from a llama-server, shown as grey text after the cursor.
--
-- The server is not on the client. By default llama.vim talks to 127.0.0.1:8012, which is
-- where an ssh forward or `tailscale serve` to the machine running llama-server puts it.
-- The overrides, all optional and none tracked:
--
--   LLAMA_FIM_ENDPOINT   the full /infill URL, when the server is somewhere else
--   LLAMA_FIM_MODEL      the completion model's name, for llama-server's router mode
--   LLAMA_INST_MODEL     the model for instructions (Space a i on a selection); defaults
--                        to the completion model
--   ~/.config/llama/api-key   one line, when llama-server was started with --api-key
--
-- Keys, in insert mode while a suggestion shows:
--   Tab         accept all of it
--   Shift-Tab   accept its first line
--   Ctrl-L / Ctrl-H   next / previous suggestion
--
-- Tab and Shift-Tab are routed through blink.cmp instead of being llama.vim's own. Both
-- plugins map those keys per buffer, and llama.vim removes its mapping when the
-- suggestion goes away, which would take blink's snippet and completion Tab with it.
local function api_key()
  local f = io.open(vim.fn.expand("~/.config/llama/api-key"), "r")
  if not f then
    return ""
  end
  local key = vim.trim(f:read("*a") or "")
  f:close()
  return key
end

local endpoint_fim = vim.env.LLAMA_FIM_ENDPOINT or "http://127.0.0.1:8012/infill"
local model_fim = vim.env.LLAMA_FIM_MODEL or ""

local function hint_shown()
  if vim.fn.exists("*llama#is_fim_hint_shown") == 0 then
    return false
  end
  -- A Vim boolean, which arrives in Lua as true; older versions returned 1.
  local shown = vim.fn["llama#is_fim_hint_shown"]()
  return shown == true or shown == 1
end

-- Returns true when there was a suggestion to accept, so blink stops there; false lets
-- the key fall through to the next action, and finally to a plain Tab.
local function accept(kind)
  if not hint_shown() then
    return false
  end
  LazyVim.create_undo()
  -- Scheduled: blink runs key actions where the buffer may not be changed.
  vim.schedule(function()
    vim.fn["llama#fim_accept"](kind)
  end)
  return true
end

return {
  {
    "ggml-org/llama.vim",
    event = "VeryLazy",
    init = function()
      vim.g.llama_config = {
        endpoint_fim = endpoint_fim,
        -- The same server for instructions, which llama.vim then treats as a router.
        endpoint_inst = endpoint_fim:gsub("/infill$", "/v1/chat/completions"),
        model_fim = model_fim,
        model_inst = vim.env.LLAMA_INST_MODEL or model_fim,
        api_key = api_key(),
        -- Timings in the status line, not inline: inline text crowds a phone-width line.
        show_info = 1,
        keymap_fim_accept_full = "",
        keymap_fim_accept_line = "",
        -- The defaults for these begin with <leader>, which is Space. In insert mode that
        -- makes every typed space wait to see whether a mapping follows.
        keymap_fim_trigger = "",
        keymap_fim_accept_word = "",
        -- Moved under LazyVim's <leader>a (AI) group, away from <leader>l,
        -- which is LazyVim's plugin manager.
        keymap_inst_trigger = "<leader>ai",
        keymap_inst_rerun = "<leader>ar",
        keymap_inst_continue = "<leader>ac",
        keymap_debug_toggle = "<leader>ad",
      }
    end,
    config = function()
      LazyVim.cmp.actions.ai_accept = function()
        return accept("full")
      end
    end,
  },
  -- With no server reachable, llama.vim reports every failed request ("FIM job failed
  -- with exit code: 7", curl's "could not connect"), and LazyVim shows each one as a
  -- popup over the code. Sent to the corner instead, where it still says why nothing
  -- completes.
  {
    "folke/noice.nvim",
    opts = function(_, opts)
      opts.routes = opts.routes or {}
      table.insert(opts.routes, {
        filter = { event = "msg_show", find = "job failed with exit code" },
        view = "mini",
      })
    end,
  },
  {
    "saghen/blink.cmp",
    opts = {
      keymap = {
        ["<S-Tab>"] = {
          "snippet_backward",
          function()
            return accept("line")
          end,
          "fallback",
        },
      },
    },
  },
}
