-- agent.lua — persistent AI-agent side panel for Neovim (0.11+)
--
-- A VS Code-style panel: a terminal split on the right running your coding
-- agent (opencode / codex / claude) while the main window stays on code.
--
--   * One session per (agent, project). Switching agents or projects never
--     kills the others; they keep running hidden.
--   * Edits made by the agent show up in your buffers within ~1s, even while
--     you are typing in the panel (terminal output does not fire the usual
--     focus events, so a light timer runs checktime while an agent is alive).
--   * Send the current file (@path) or a visual selection (with path:lines)
--     straight into the agent prompt.
--
-- Default keymaps (prefix = <leader>a):
--   <leader>aa  toggle panel          <leader>ao  open / focus panel
--   <leader>an  new (restart) session <leader>as  switch agent
--   <leader>ak  kill session          <leader>af  send current file as @path
--   <leader>av  (visual) send selection
--
-- Commands: :AgentToggle :AgentOpen :AgentFocus :AgentNew [agent]
--           :AgentSwitch [agent] :AgentKill :AgentSendFile :'<,'>AgentSendSelection
--
-- Optional setup (everything has a default; this file also self-initialises):
--   require("agent").setup({
--     default = "claude",
--     width = 0.45,
--     agents = { opencode = { cmd = { "opencode", "--no-attach" } } },
--   })
--
-- Env override for the starting agent: $NVIM_AGENT_CMD=codex nvim

local M = {}

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------

local defaults = {
  -- argv lists (no shell quoting needed). A plain string is split on spaces.
  agents = {
    opencode = { cmd = { "opencode" } },
    codex = { cmd = { "codex" } },
    claude = { cmd = { "claude" } },
  },
  default = "opencode",
  width = 0.40, -- fraction of the editor width
  min_width = 40, -- columns
  root_markers = { ".git" }, -- project root detection (falls back to file dir)
  reload_interval = 1000, -- ms between checktime polls while an agent runs; 0 = off
  notify_reload = true, -- "reloaded foo.lua" when an agent edit lands
  kill_on_quit = true, -- stop agents on :qa so Neovim can exit without E948
  keymaps = true,
  prefix = "<leader>a",
  -- <C-h/j/k/l> from inside the terminal. Off by default: agent TUIs use
  -- Ctrl-J (newline), Ctrl-K, Ctrl-L themselves. Use <C-\><C-n> then <C-w>h.
  term_nav = false,
}

M.config = vim.deepcopy(defaults)

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local state = {
  agent = nil, -- currently selected agent name
  win = nil, -- panel window id
  sessions = {}, -- "agent@cwd" -> { agent, cwd, key, buf, job, started, id }
  timer = nil, -- uv timer for checktime polling
  last_key = nil, -- last session shown (to avoid notify spam)
  seq = 0,
}
M.state = state

local mapped = {} -- keymaps we created, so setup() can replace them

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function notify(msg, level)
  vim.notify("[agent] " .. msg, level or vim.log.levels.INFO)
end

local function win_valid()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function buf_valid(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

-- jobwait() always returns a list; first element is -1 while running.
local function alive(s)
  return s ~= nil and s.job ~= nil and vim.fn.jobwait({ s.job }, 0)[1] == -1
end

local function session_key(agent, cwd)
  return agent .. "@" .. cwd
end

local function any_alive()
  for _, s in pairs(state.sessions) do
    if s.job then
      return true
    end
  end
  return false
end

local function sorted_agents()
  local names = vim.tbl_keys(M.config.agents)
  table.sort(names)
  return names
end

local function pretty(path)
  return vim.fn.fnamemodify(path, ":~")
end

-- path relative to base when inside it (what agents expect for @mentions)
local function relpath(path, base)
  base = (base:gsub("/+$", ""))
  if path:sub(1, #base + 1) == base .. "/" then
    return path:sub(#base + 2)
  end
  return path
end

-- The project the user is working in. If we are inside an agent buffer, use
-- that session's directory; otherwise the git root (or file dir) of the
-- current file, falling back to Neovim's cwd for fileless buffers.
local function project_dir()
  local cur = vim.api.nvim_get_current_buf()
  local key = vim.b[cur].agent_key
  if key and state.sessions[key] then
    return state.sessions[key].cwd
  end
  local name = vim.api.nvim_buf_get_name(cur)
  if name ~= "" and vim.bo[cur].buftype == "" then
    local dir = vim.fs.dirname(name)
    if dir and vim.fn.isdirectory(dir) == 1 then
      return vim.fs.root(dir, M.config.root_markers) or dir
    end
  end
  return vim.uv.cwd()
end

-- startinsert no-ops until the window switch is committed, so schedule it.
local function enter_insert()
  vim.schedule(function()
    if win_valid() then
      vim.api.nvim_set_current_win(state.win)
      vim.cmd("startinsert")
    end
  end)
end

---------------------------------------------------------------------------
-- Auto-reload of files the agent edits
---------------------------------------------------------------------------

local function checktime()
  if vim.fn.mode() == "c" or vim.fn.getcmdwintype() ~= "" then
    return
  end
  vim.cmd("silent! checktime")
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function start_timer()
  local interval = M.config.reload_interval
  if state.timer or not interval or interval <= 0 then
    return
  end
  state.timer = vim.uv.new_timer()
  state.timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if any_alive() then
        checktime()
      else
        stop_timer()
      end
    end)
  )
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------

local function discard(s)
  s.stopping = true
  if s.job then
    pcall(vim.fn.jobstop, s.job)
  end
  if buf_valid(s.buf) then
    pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
  end
  if state.sessions[s.key] == s then
    state.sessions[s.key] = nil
  end
end

-- Exit codes that mean "the user quit the agent" rather than "it crashed".
local CLEAN_EXIT = { [0] = true, [129] = true, [130] = true, [143] = true }

local function on_exit(s, code)
  vim.schedule(function()
    s.job = nil
    if s.stopping then
      return
    end
    if CLEAN_EXIT[code] then
      -- Agent was quit on purpose: tidy up the panel and the buffer.
      if win_valid() and vim.api.nvim_win_get_buf(state.win) == s.buf then
        vim.cmd("stopinsert")
        M.close()
      end
      if buf_valid(s.buf) then
        pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
      end
      if state.sessions[s.key] == s then
        state.sessions[s.key] = nil
      end
    else
      -- Keep the buffer so the error output stays readable.
      local fast = (vim.uv.now() - s.started) < 5000
      notify(
        ("%s exited with code %d%s — <leader>an to retry"):format(
          s.agent,
          code,
          fast and " right after starting (check the command/flags)" or ""
        ),
        vim.log.levels.ERROR
      )
    end
  end)
end

-- Start an agent in the panel window. Requires a valid state.win.
local function spawn(agent, cwd)
  local spec = M.config.agents[agent]
  local argv = spec.cmd
  if type(argv) == "string" then
    argv = vim.split(argv, "%s+", { trimempty = true })
  else
    argv = vim.deepcopy(argv)
  end
  if vim.fn.executable(argv[1]) ~= 1 then
    notify(("'%s' is not executable / not in $PATH"):format(argv[1]), vim.log.levels.ERROR)
    return nil
  end

  state.seq = state.seq + 1
  local buf = vim.api.nvim_create_buf(false, true)
  local s = {
    agent = agent,
    cwd = cwd,
    key = session_key(agent, cwd),
    buf = buf,
    started = vim.uv.now(),
    id = state.seq,
  }

  vim.api.nvim_win_set_buf(state.win, buf)
  vim.api.nvim_win_call(state.win, function()
    s.job = vim.fn.jobstart(argv, {
      term = true,
      cwd = cwd,
      on_exit = function(_, code)
        on_exit(s, code)
      end,
    })
  end)

  if not s.job or s.job <= 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    notify("failed to start: " .. table.concat(argv, " "), vim.log.levels.ERROR)
    return nil
  end

  vim.b[buf].agent_key = s.key
  vim.bo[buf].buflisted = false -- invisible to :bnext and tabline plugins
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "agent"
  pcall(vim.api.nvim_buf_set_name, buf, ("agent://%s/%s#%d"):format(agent, vim.fs.basename(cwd), s.id))

  if M.config.term_nav then
    for _, k in ipairs({ "h", "j", "k", "l" }) do
      vim.keymap.set("t", "<C-" .. k .. ">", "<C-\\><C-n><C-w>" .. k, {
        buffer = buf,
        desc = "agent: move to window " .. k,
      })
    end
  end
  return s
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local WIN_OPTS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  cursorline = false,
  cursorcolumn = false,
  spell = false,
  list = false,
  winfixwidth = true,
}

local function panel_width()
  return math.max(M.config.min_width, math.floor(vim.o.columns * M.config.width))
end

-- `botright vsplit` always lands on the far right and focuses the new
-- window, regardless of 'splitright'.
local function open_win()
  vim.cmd("botright vsplit")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(state.win, panel_width())
  for k, v in pairs(WIN_OPTS) do
    vim.wo[state.win][k] = v
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function M.is_open()
  return win_valid()
end

-- For statuslines: require("agent").status()
function M.status()
  if not state.agent then
    return ""
  end
  if win_valid() then
    return "agent:" .. state.agent
  end
  return any_alive() and ("agent:" .. state.agent .. " (bg)") or ""
end

--- Show the panel for the current project + agent, starting it if needed.
--- Returns the session and whether it was freshly spawned.
--- opts: { agent = name, fresh = bool }
function M.open(opts)
  opts = type(opts) == "table" and opts or {}
  local agent = opts.agent or state.agent
  local cwd = project_dir() -- before any window changes
  local key = session_key(agent, cwd)

  local s = state.sessions[key]
  local old
  if s and (opts.fresh or not (buf_valid(s.buf) and alive(s))) then
    old, s = s, nil
  end

  local opened_now = false
  if not win_valid() then
    open_win()
    opened_now = true
  end

  local spawned = false
  if s then
    if vim.api.nvim_win_get_buf(state.win) ~= s.buf then
      vim.api.nvim_win_set_buf(state.win, s.buf)
    end
  else
    s = spawn(agent, cwd)
    if not s then
      if opened_now then
        M.close()
      end
      return nil
    end
    spawned = true
    state.sessions[key] = s
  end

  if old then
    discard(old) -- after the swap, so the window survives
  end

  state.agent = agent
  if spawned or state.last_key ~= key then
    notify(("%s @ %s"):format(agent, pretty(cwd)))
  end
  state.last_key = key

  start_timer()
  enter_insert()
  return s, spawned
end

--- Hide the panel (sessions keep running).
function M.close()
  if win_valid() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
end

function M.toggle()
  if win_valid() then
    M.close()
  else
    M.open()
  end
end

function M.focus()
  M.open()
end

local function valid_agent(name)
  if M.config.agents[name] then
    return true
  end
  notify(("unknown agent '%s' (have: %s)"):format(name, table.concat(sorted_agents(), ", ")), vim.log.levels.ERROR)
  return false
end

--- Restart the session for this project (optionally as a different agent).
function M.new(agent)
  if agent and not valid_agent(agent) then
    return
  end
  if M.open({ agent = agent, fresh = true }) then
    notify("restarted " .. state.agent)
  end
end

--- Switch agent without killing the other agents' sessions.
function M.switch(agent)
  if agent then
    if valid_agent(agent) then
      M.open({ agent = agent })
    end
    return
  end
  local cwd = project_dir()
  vim.ui.select(sorted_agents(), {
    prompt = "Switch agent:",
    format_item = function(name)
      local running = alive(state.sessions[session_key(name, cwd)]) and " ●" or ""
      local current = name == state.agent and "* " or "  "
      return current .. name .. running
    end,
  }, function(choice)
    if choice then
      M.open({ agent = choice })
    end
  end)
end

--- Stop and forget the session for this project + current agent.
function M.kill()
  local s = state.sessions[session_key(state.agent, project_dir())]
  if not s then
    notify("no session for this project")
    return
  end
  discard(s)
  notify("stopped " .. s.agent)
end

local function deliver(text, bracketed)
  local s, spawned = M.open()
  if not s then
    return
  end
  local function go()
    if s.job then
      vim.api.nvim_chan_send(s.job, bracketed and ("\27[200~" .. text .. "\27[201~") or text)
    end
  end
  -- A freshly started TUI needs a moment before it reads input.
  if spawned then
    vim.defer_fn(go, 1500)
  else
    go()
  end
end

--- Type `@path/to/file ` into the agent prompt.
function M.send_file()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    notify("current buffer has no file", vim.log.levels.WARN)
    return
  end
  deliver("@" .. relpath(name, project_dir()) .. " ", false)
end

--- Paste lines l1..l2 of the current buffer (with path:lines header).
function M.send_selection(l1, l2)
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    notify("current buffer has no file", vim.log.levels.WARN)
    return
  end
  if l1 > l2 then
    l1, l2 = l2, l1
  end
  local lines = vim.api.nvim_buf_get_lines(0, l1 - 1, l2, false)
  local text = ("%s:%d-%d\n```%s\n%s\n```\n"):format(
    relpath(name, project_dir()),
    l1,
    l2,
    vim.bo.filetype,
    table.concat(lines, "\n")
  )
  deliver(text, true) -- bracketed paste: newlines must not submit the prompt
end

---------------------------------------------------------------------------
-- Setup: options, autocmds, commands, keymaps (idempotent)
---------------------------------------------------------------------------

local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { desc = "agent: " .. desc })
  table.insert(mapped, { mode, lhs })
end

local function setup_keymaps()
  for _, m in ipairs(mapped) do
    pcall(vim.keymap.del, m[1], m[2])
  end
  mapped = {}
  if not M.config.keymaps then
    return
  end
  local p = M.config.prefix
  map("n", p .. "a", M.toggle, "toggle panel")
  map("n", p .. "o", M.focus, "open / focus panel")
  map("n", p .. "n", function()
    M.new()
  end, "new session")
  map("n", p .. "s", function()
    M.switch()
  end, "switch agent")
  map("n", p .. "k", M.kill, "kill session")
  map("n", p .. "f", M.send_file, "send file as @path")
  map("x", p .. "v", function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd("normal! \27") -- leave visual mode before switching windows
    M.send_selection(a, b)
  end, "send selection")
end

local function setup_commands()
  local complete = function()
    return sorted_agents()
  end
  local cmd = vim.api.nvim_create_user_command
  cmd("AgentToggle", function()
    M.toggle()
  end, {})
  cmd("AgentOpen", function()
    M.open()
  end, {})
  cmd("AgentFocus", function()
    M.focus()
  end, {})
  cmd("AgentKill", function()
    M.kill()
  end, {})
  cmd("AgentSendFile", function()
    M.send_file()
  end, {})
  cmd("AgentSendSelection", function(o)
    M.send_selection(o.line1, o.line2)
  end, { range = true })
  cmd("AgentNew", function(o)
    M.new(o.args ~= "" and o.args or nil)
  end, { nargs = "?", complete = complete })
  cmd("AgentSwitch", function(o)
    M.switch(o.args ~= "" and o.args or nil)
  end, { nargs = "?", complete = complete })
end

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("AgentPanel", { clear = true })
  local au = vim.api.nvim_create_autocmd

  -- Reload buffers the agent changed on disk.
  vim.o.autoread = true
  au({ "FocusGained", "BufEnter", "WinEnter", "TermLeave", "CursorHold" }, {
    group = group,
    callback = checktime,
  })
  au("FileChangedShellPost", {
    group = group,
    callback = function(args)
      if M.config.notify_reload and any_alive() then
        notify("reloaded " .. vim.fn.fnamemodify(args.file, ":t"))
      end
    end,
  })

  -- Forget the window when closed by any means (:q, <C-w>c, ...).
  au("WinClosed", {
    group = group,
    callback = function(args)
      if state.win and tonumber(args.match) == state.win then
        state.win = nil
      end
    end,
  })

  -- Keep the panel width proportional when the terminal is resized.
  au("VimResized", {
    group = group,
    callback = function()
      if win_valid() then
        vim.api.nvim_win_set_width(state.win, panel_width())
      end
    end,
  })

  -- The agent buffer belongs to the panel. If it ends up in any other window
  -- (:buffer, a jumplist entry, a picker, ...), put that window back.
  au("BufWinEnter", {
    group = group,
    callback = function(args)
      if not vim.b[args.buf].agent_key then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(args.buf) then
          return
        end
        for _, w in ipairs(vim.fn.win_findbuf(args.buf)) do
          if w ~= state.win then
            local alt = vim.api.nvim_win_call(w, function()
              return vim.fn.bufnr("#")
            end)
            if alt > 0 and alt ~= args.buf and vim.api.nvim_buf_is_valid(alt) and not vim.b[alt].agent_key then
              vim.api.nvim_win_set_buf(w, alt)
            else
              vim.api.nvim_win_set_buf(w, vim.api.nvim_create_buf(true, false))
            end
            notify("the agent lives in the side panel — <leader>ao to focus it")
          end
        end
      end)
    end,
  })

  -- Let :qa work: running terminal jobs otherwise block exit (E948). Skipped
  -- when real buffers are modified, so a failed quit doesn't kill your agents.
  au("ExitPre", {
    group = group,
    callback = function()
      if not M.config.kill_on_quit then
        return
      end
      for _, b in ipairs(vim.fn.getbufinfo({ bufmodified = 1 })) do
        if not vim.b[b.bufnr].agent_key then
          return
        end
      end
      local jobs = {}
      for _, s in pairs(state.sessions) do
        s.stopping = true
        if s.job then
          table.insert(jobs, s.job)
          pcall(vim.fn.jobstop, s.job)
        end
      end
      if #jobs > 0 then
        pcall(vim.fn.jobwait, jobs, 1000)
      end
    end,
  })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  -- Re-running setup() re-picks the starting agent, unless one is running.
  if not any_alive() or not M.config.agents[state.agent or ""] then
    local env = vim.env.NVIM_AGENT_CMD
    state.agent = (env and M.config.agents[env]) and env or M.config.default
  end
  setup_autocmds()
  setup_commands()
  setup_keymaps()
end

if not vim.g.agent_panel_no_autosetup then
  M.setup()
end

return M
