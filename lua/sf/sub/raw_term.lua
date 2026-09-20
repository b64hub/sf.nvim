local api = vim.api
local cmd = api.nvim_command
local Layout = require("sf.ui.layout")

local T = {}
local H = {}

function T:new(cfg)
  local config = cfg

  local obj = setmetatable({
    win = nil,
    buf = nil,
    is_running = false,
    config = config,
    last_exit_code = nil,
    label = nil,
    mode = nil,
    job_id = nil,
    progress_handle = nil,
  }, { __index = self })

  obj:init_resize_autocmd()

  return obj
end

-- Reposition the float on `VimResized` so it stays pinned to its corner.
function T:init_resize_autocmd()
  local group = api.nvim_create_augroup("SfTermResize", { clear = true })
  api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      self:reposition()
    end,
  })
end

function T:reposition()
  if not H.is_win_valid(self.win) then
    return
  end

  local geo = H.resolve_geometry(self.config)
  api.nvim_win_set_config(self.win, {
    relative = "editor",
    row = geo.row,
    col = geo.col,
    width = geo.width,
    height = geo.height,
  })
end

function T:setup(cfg)
  if not cfg then
    return vim.notify("SFTerm: setup() is optional. Please remove it!", vim.log.levels.WARN)
  end

  self.config = vim.tbl_deep_extend("force", self.config, cfg)

  return self
end

function T:store(win, buf)
  self.win = win
  self.buf = buf

  return self
end

--- Which display mode a task category should use: "terminal" (visible
--- float, as before) or "progress" (quiet spinner, hidden terminal buffer).
---@param category string|nil
---@return string
function H.resolve_mode(category)
  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  local task_display = ui.task_display or {}
  if category and task_display[category] then
    return task_display[category]
  end
  return task_display.default or "terminal"
end

---@param cmd string
---@param cb function|nil
---@param opts table|nil { label = string|nil, category = string|nil }
function T:run(cmd, cb, opts)
  if self.is_running then
    return vim.notify("Wait the current task to finish.", vim.log.levels.WARN)
  end

  opts = opts or {}
  self.label = opts.label or "terminal"
  self.mode = H.resolve_mode(opts.category)

  local running_buf = api.nvim_create_buf(false, true)
  vim.bo[running_buf].filetype = self.config.ft

  local running_win = nil

  if self.mode == "terminal" then
    if H.is_win_valid(self.win) then
      api.nvim_win_set_buf(self.win, running_buf)
      running_win = self.win
    else
      running_win = self:create_and_open_win(running_buf)
    end
  elseif H.is_win_valid(self.win) then
    -- a float from a previous task is still open; it's now stale (a new
    -- task started), close it rather than leave it orphaned.
    self:close()
  end

  self:store(running_win, running_buf):run_after_setup(cmd, cb, opts)

  return self
end

function T:run_after_setup(cmd, cb, opts)
  local echo_msg = string.gsub(cmd, '"', '\\"')
  local cmd_with_echo = ""

  if H.is_windows_os() then
    local c27 = string.char(27)
    cmd_with_echo = string.format("echo %s && %s", c27 .. "[0;35m" .. echo_msg .. c27 .. "[0m", cmd)
  else
    cmd_with_echo = string.format('echo -e "\\e[0;35m %s \\e[0m";%s', echo_msg, cmd) -- echo Cyan color
  end

  local job_opts = {
    clear_env = self.config.clear_env,
    env = self.config.env,
    on_exit = function(job_id, exit_code, event_name)
      self.last_exit_code = exit_code
      self.is_running = false
      self.job_id = nil

      if self.mode == "progress" then
        self:_finish_progress(exit_code)

        local ui = (vim.g.sf and vim.g.sf.ui) or {}
        local expand_on_error = ui.expand_on_error
        if expand_on_error == nil then
          expand_on_error = true
        end
        if exit_code ~= 0 and expand_on_error then
          self:open()
        end
      else
        self:scroll_to_end_in_win() -- fixed: used to unconditionally self:close():open()
      end

      if cb ~= nil then
        cb(self, cmd, exit_code)
      end
    end,
  }

  if self.mode == "terminal" then
    self:remember_cursor()
    api.nvim_set_current_win(self.win)

    self.job_id = vim.fn.termopen(cmd_with_echo, job_opts)

    self.is_running = true
    vim.bo[self.buf].filetype = self.config.ft -- force filetype
    self:restore_cursor()
  else
    self:_start_progress(opts)

    -- Run the job in the hidden buffer (no window): callbacks that read
    -- `self.buf` (e.g. test coverage parsing) keep working, and "expand"
    -- (toggle_term) can still open this buffer later.
    api.nvim_buf_call(self.buf, function()
      self.job_id = vim.fn.jobstart(cmd_with_echo, vim.tbl_extend("force", { term = true }, job_opts))
    end)

    self.is_running = true
    vim.bo[self.buf].filetype = self.config.ft
  end

  return self
end

function T:toggle()
  if H.is_win_valid(self.win) then
    self:close()
  else
    self:open()
  end

  return self
end

function T:open()
  if H.is_win_valid(self.win) then
    return
  end

  if not H.is_buf_valid(self.buf) then
    return vim.notify_once("Sf: no previous task. Run a terminal command to initiate the term.", vim.log.levels.WARN)
  end

  local win = self:create_and_open_win(self.buf)
  self:remember_cursor()

  api.nvim_set_current_win(win)
  self:scroll_to_end():restore_cursor()

  self:store(win, self.buf)

  return self
end

function T:close()
  if not H.is_win_valid(self.win) then
    return self
  end

  api.nvim_win_close(self.win, false)

  return self
end

function T:cancel()
  if not self.is_running then
    return
  end

  self.is_running = false

  if self.job_id then
    pcall(vim.fn.jobstop, self.job_id)
  end

  if self.progress_handle then
    self.progress_handle:finish(false, (self.label or "task") .. " cancelled")
    self.progress_handle = nil
  end
end

--- Start a quiet progress handle for the current ("progress" mode) task.
function T:_start_progress(opts)
  local Progress = require("sf.ui.progress")
  self.progress_handle = Progress.start({ msg = opts.label or self.label or "sf task" })
end

--- Finish the progress handle for the current task with a short result.
---@param exit_code number
function T:_finish_progress(exit_code)
  if not self.progress_handle then
    return
  end

  local ok = exit_code == 0
  local label = self.label or "Task"
  local msg = ok and (label .. " done") or (label .. " failed – <leader><leader> to view output")

  self.progress_handle:finish(ok, msg)
  self.progress_handle = nil
end

function T:create_and_open_win(buf)
  local cfg = self.config
  local ui = (vim.g.sf and vim.g.sf.ui) or {}

  local geo = H.resolve_geometry(cfg)
  local border = cfg.border or ui.border or "rounded"
  local icon = (ui.icons ~= false) and " " or ""
  local label = self.label or "terminal"

  local win_opts = {
    border = border,
    relative = "editor",
    style = "minimal",
    title = { { string.format(" %ssf · %s ", icon, label), "SfTitle" } },
    title_pos = "left",
    width = geo.width,
    height = geo.height,
    col = geo.col,
    row = geo.row,
  }

  if vim.fn.has("nvim-0.10") == 1 then
    win_opts.footer = { { " <C-c> cancel · q close ", "SfFooter" } }
    win_opts.footer_pos = "left"
  end

  local win = api.nvim_open_win(buf, false, win_opts)

  local winhl = cfg.hl and ("Normal:%s"):format(cfg.hl)
    or "Normal:SfNormal,FloatBorder:SfBorder,FloatTitle:SfTitle,FloatFooter:SfFooter"

  api.nvim_win_set_option(win, "winhl", winhl)
  api.nvim_win_set_option(win, "winblend", cfg.blend)

  return win
end

function T:remember_cursor()
  self.last_win = api.nvim_get_current_win()
  self.prev_win = vim.fn.winnr("#")
  self.last_pos = api.nvim_win_get_cursor(self.last_win)

  return self
end

function T:restore_cursor()
  if self.last_win and self.last_pos ~= nil then
    if self.prev_win > 0 then
      cmd(("silent! %s wincmd w"):format(self.prev_win))
    end

    if H.is_win_valid(self.last_win) then
      api.nvim_set_current_win(self.last_win)
      api.nvim_win_set_cursor(self.last_win, self.last_pos)
    end

    self.last_win = nil
    self.prev_win = nil
    self.last_pos = nil
  end

  return self
end

function T:get_config()
  return self.config
end

function T:get_last_exit_code()
  return self.last_exit_code
end

function T:scroll_to_end()
  cmd("$")
  return self
end

--- Scroll the float to the end without stealing focus or opening a window
--- that wasn't already open (replaces the old `self:close(); self:open()`
--- re-open hack, which popped the float open at the end of every task).
function T:scroll_to_end_in_win()
  if not H.is_win_valid(self.win) then
    return self
  end

  local line_count = api.nvim_buf_line_count(self.buf)
  pcall(api.nvim_win_set_cursor, self.win, { line_count, 0 })

  return self
end

-- helper -------------------

function H.is_win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function H.is_buf_valid(buf)
  return buf and vim.api.nvim_buf_is_loaded(buf)
end

-- Resolve float geometry: the old proportional `x`/`y` positioning if the
-- user set either (back-compat "custom" mode), else the new corner layout.
---@param cfg table term_config
---@return table { row, col, width, height }
function H.resolve_geometry(cfg)
  if cfg.dimensions.x ~= nil or cfg.dimensions.y ~= nil then
    return H.get_dimension(cfg.dimensions)
  end

  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  local term_ui = ui.terminal or {}

  return Layout.float_geometry({
    position = term_ui.position or "bottom_right",
    width = term_ui.width or 0.45,
    height = term_ui.height or 0.35,
    margin = term_ui.margin,
  })
end

function H.get_dimension(opts)
  -- get lines and columns
  local cl = vim.o.columns
  local ln = vim.o.lines

  -- calculate our floating window size
  local width = math.ceil(cl * opts.width)
  local height = math.ceil(ln * opts.height - 4)

  -- and its starting position
  local col = math.ceil((cl - width) * opts.x)
  local row = math.ceil((ln - height) * opts.y - 1)

  return {
    width = width,
    height = height,
    col = col,
    row = row,
  }
end

function H.is_windows_os()
  if vim.fn.has("win32") == 1 then
    return true
  end
  return false
end

return T
