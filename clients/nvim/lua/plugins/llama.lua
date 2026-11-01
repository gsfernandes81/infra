-- Fill-in-the-middle completion from a llama-server, shown as grey text after the cursor.
--
-- The server is not on the client. With nothing set, this talks to 127.0.0.1:8080,
-- llama-server's own default port, where an ssh forward or `tailscale serve` to the
-- machine running it puts it. The settings, all optional and none tracked:
--
--   LLAMA_BASE_URL       the server's address, `http://host:port`, with or without /v1;
--                        the owner's WSL shell sets it to the Windows host's NAT address
--   LLAMA_FIM_ENDPOINT   the full /infill URL, which wins over LLAMA_BASE_URL
--   LLAMA_FIM_MODEL      the completion model's name, for llama-server's router mode
--   LLAMA_INST_MODEL     the model for instructions (Space a i on a selection); defaults
--                        to the completion model
--   LLAMA_API_KEY        the key, when llama-server runs with --api-key
--   ~/.config/llama/api-key   the key from a file instead, one line, mode 600
--
-- Keys, in insert mode while a suggestion shows:
--   Tab         accept all of it
--   Shift-Tab   accept its first line
--   Ctrl-L / Ctrl-H   next / previous suggestion
--
-- Keys for instructions, under LazyVim's Space a (AI) group:
--   Space a i   on a selection: send an instruction about it
--   Space a a / Space a x   accept / cancel the result
--   Space a r / Space a c   rerun / continue it
--   Space a d   the debug pane
--
-- Tab and Shift-Tab are routed through blink.cmp instead of being llama.vim's own. Both
-- plugins map those keys per buffer, and llama.vim removes its mapping when the
-- suggestion goes away, which would take blink's snippet and completion Tab with it.
-- llama.vim hands the key to curl on its command line, so while a request runs any local
-- user can read it from the process list. The file at least should not add a second way.
local function api_key()
  if (vim.env.LLAMA_API_KEY or "") ~= "" then
    return vim.env.LLAMA_API_KEY
  end
  local path = (vim.env.XDG_CONFIG_HOME or vim.fn.expand("~/.config")) .. "/llama/api-key"
  local f = io.open(path, "r")
  if not f then
    return ""
  end
  local key = vim.trim(f:read("*a") or "")
  f:close()
  local stat = vim.uv.fs_stat(path)
  if stat and bit.band(stat.mode, tonumber("077", 8)) ~= 0 then
    vim.schedule(function()
      vim.notify(path .. " is readable by others; chmod 600 it", vim.log.levels.WARN)
    end)
  end
  return key
end

local base = (vim.env.LLAMA_BASE_URL or "http://127.0.0.1:8080"):gsub("/+$", ""):gsub("/v1$", "")
local endpoint_fim = vim.env.LLAMA_FIM_ENDPOINT or (base .. "/infill")
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
        -- Moved under LazyVim's <leader>a (AI) group, away from <leader>l, which is
        -- LazyVim's plugin manager. Accept and cancel default to <Tab> and <Esc>, which
        -- llama.vim maps in normal mode for good, taking Esc's clearing of search
        -- highlights and Tab's jump forward (Ctrl-I) from every buffer.
        keymap_inst_trigger = "<leader>ai",
        keymap_inst_accept = "<leader>aa",
        keymap_inst_cancel = "<leader>ax",
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
  -- llama.vim's mappings carry no descriptions, so the Space menu would list them blank.
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>a", group = "ai (llama)", mode = { "n", "x" } },
        { "<leader>ai", desc = "Instruction on selection", mode = "x" },
        { "<leader>aa", desc = "Accept instruction result" },
        { "<leader>ax", desc = "Cancel instruction" },
        { "<leader>ar", desc = "Rerun instruction" },
        { "<leader>ac", desc = "Continue instruction" },
        { "<leader>ad", desc = "llama.vim debug pane" },
      },
    },
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
