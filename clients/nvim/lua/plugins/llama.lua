-- Fill-in-the-middle completion from a llama-server, shown as grey text after the cursor.
--
-- The server is not on the client. With nothing set, this talks to 127.0.0.1:8080,
-- llama-server's own default port, where an ssh forward or `tailscale serve` to the
-- machine running it puts it. The settings, all optional and none tracked:
--
--   LLAMA_BASE_URL       the server's address, `http://host:port`, with or without /v1;
--                        the owner's WSL shell sets it to the Windows host's NAT address
--   LLAMA_FIM_ENDPOINT   the full /infill URL, which wins over LLAMA_BASE_URL
--   LLAMA_FIM_MODEL      the completion model's name; required with llama-server's
--                        router, which refuses a request without one, and llama.vim
--                        drops the refusal silently (:LlamaStatus shows it)
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

-- When the server is away, suggestions turn off quietly and come back when it answers.
--
-- A check of the server's /health, which needs no key and which the router answers too,
-- runs as the plugin loads and then at most every 20 seconds while you type. Each change
-- is one notice. Only llama.vim's automatic suggestions are switched, the way its own
-- :LlamaToggleAutoFim does: llama#enable starts a timer that never stops, so cycling the
-- whole plugin on every outage would pile them up. vim.g.llama_server_up holds the
-- latest answer.
local health = { url = endpoint_fim:gsub("/infill$", "") .. "/health", last = 0, running = false }

local function set_auto_fim(on)
  vim.cmd("let g:llama_config.auto_fim = " .. (on and "v:true" or "v:false"))
  vim.fn["llama#setup_autocmds"]()
end

-- A line in the bottom right corner, not a notification popup: the noice route below
-- sends it there. "Not reachable" shows on every start without the tunnel, and a popup
-- would cover half a phone's width each time.
local function say(msg)
  vim.api.nvim_echo({ { msg } }, false, {})
end

local function on_health(up)
  local was = vim.g.llama_server_up
  vim.g.llama_server_up = up
  if up == was then
    return
  end
  set_auto_fim(up)
  if up and was ~= nil then
    say("llama on: the server answered")
  elseif not up then
    -- Short enough for a phone held upright: the address without scheme or path.
    say(("llama off: no server at %s"):format(endpoint_fim:gsub("^%a+://", ""):gsub("/infill$", "")))
  end
end

local function check_health(force)
  local now = vim.uv.now()
  if health.running or (not force and now - health.last < 20000) then
    return
  end
  health.running, health.last = true, now
  vim.system(
    { "curl", "--silent", "--output", "/dev/null", "--connect-timeout", "2", "--max-time", "4", health.url },
    {},
    function(out)
      vim.schedule(function()
        health.running = false
        on_health(out.code == 0)
      end)
    end
  )
end

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
        -- Off until the health check above hears the server.
        auto_fim = false,
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
      -- Tab falls through to whatever held this hook before, such as a LazyVim AI extra
      -- (Copilot), when no llama suggestion is showing; replacing it outright left Tab
      -- unable to accept the other's suggestions.
      local before = LazyVim.cmp.actions.ai_accept
      LazyVim.cmp.actions.ai_accept = function()
        return accept("full") or (before ~= nil and before())
      end
      -- Its own group: llama#disable clears the `llama` group wholesale.
      vim.api.nvim_create_autocmd({ "InsertEnter", "TextChangedI" }, {
        group = vim.api.nvim_create_augroup("infra_llama_health", { clear = true }),
        callback = function()
          check_health(false)
        end,
      })
      check_health(true)
    end,
  },
  -- A server that goes away between two health checks fails the requests in between, and
  -- llama.vim reports each one ("FIM job failed with exit code: 7"), which LazyVim would
  -- show as a popup over the code. Sent to the corner instead, until the next check
  -- turns suggestions off.
  {
    "folke/noice.nvim",
    opts = function(_, opts)
      opts.routes = opts.routes or {}
      table.insert(opts.routes, {
        filter = { event = "msg_show", find = "job failed with exit code" },
        view = "mini",
      })
      table.insert(opts.routes, {
        filter = { event = "msg_show", find = "^llama o[nf]+:" },
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
