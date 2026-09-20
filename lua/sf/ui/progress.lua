-- Small progress/spinner widget for quiet background tasks (deploy,
-- retrieve, etc), so they don't need to pop open a terminal float.
-- Two backends:
--  - "float": a small non-focusable bottom-right window (stacks with others)
--  - "notify": vim.notify, updated in place via a stable `id`
local Layout = require("sf.ui.layout")

local M = {}
local H = { handles = {}, timer = nil, next_id = 1 }

local DEFAULT_SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@return table
local function cfg()
  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  return ui.progress or {}
end

---@return boolean
local function has_snacks_notifier()
  local ok, snacks = pcall(require, "snacks")
  return ok and snacks.notifier ~= nil
end

---@return string "float"|"notify"
local function resolve_backend()
  local backend = cfg().backend or "float"
  if backend ~= "auto" then
    return backend
  end
  if has_snacks_notifier() or pcall(require, "notify") then
    return "notify"
  end
  return "float"
end

-- Handle -----------------------------------------------------------------

local Handle = {}
Handle.__index = Handle

function Handle:_elapsed_str()
  local secs = math.floor((vim.uv.now() - self.started) / 1000)
  return secs .. "s"
end

function Handle:_icon()
  if self.done then
    return self.ok and "✓" or "✗"
  end
  local spinner = cfg().spinner or DEFAULT_SPINNER
  return spinner[(self.frame % #spinner) + 1]
end

--- Single-line text, icon inline (used by the float backend).
function Handle:_text()
  return string.format("%s %s (%s)", self:_icon(), self.msg, self:_elapsed_str())
end

--- Text without an inline icon (notify backends render their own icon).
function Handle:_text_plain()
  return string.format("%s (%s)", self.msg, self:_elapsed_str())
end

function Handle:_hl()
  if not self.done then
    return "SfSpinner"
  end
  return self.ok and "SfSuccess" or "SfError"
end

-- float backend

function Handle:_float_geometry(stack_index)
  local width = math.min(44, vim.o.columns - 4)
  local geo = Layout.float_geometry({
    position = "bottom_right",
    width = width,
    height = 1,
    margin = { row = 1, col = 2 },
  })
  geo.row = geo.row - Layout.stack_offset(stack_index)
  return geo
end

local function float_reflow()
  local idx = 0
  for _, h in ipairs(H.handles) do
    if h.backend == "float" and h.win and vim.api.nvim_win_is_valid(h.win) then
      local geo = h:_float_geometry(idx)
      vim.api.nvim_win_set_config(h.win, {
        relative = "editor",
        row = geo.row,
        col = geo.col,
        width = geo.width,
        height = geo.height,
      })
      idx = idx + 1
    end
  end
end

--- Number of float handles already open, excluding `self`.
function Handle:_float_stack_index()
  local idx = 0
  for _, h in ipairs(H.handles) do
    if h == self then
      break
    end
    if h.backend == "float" and h.win then
      idx = idx + 1
    end
  end
  return idx
end

function Handle:_float_open()
  self.buf = vim.api.nvim_create_buf(false, true)
  local geo = self:_float_geometry(self:_float_stack_index())
  local ui = (vim.g.sf and vim.g.sf.ui) or {}

  self.win = vim.api.nvim_open_win(self.buf, false, {
    relative = "editor",
    row = geo.row,
    col = geo.col,
    width = geo.width,
    height = geo.height,
    style = "minimal",
    border = ui.border or "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 60,
  })

  vim.api.nvim_win_set_option(self.win, "winhl", "Normal:SfNormal,FloatBorder:SfBorder")
  self:_float_render()
end

function Handle:_float_render()
  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
    return
  end

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { self:_text() })
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)
  vim.api.nvim_buf_add_highlight(self.buf, -1, self:_hl(), 0, 0, -1)
end

function Handle:_float_close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
  self.win, self.buf = nil, nil
  float_reflow()
end

-- notify backend

function Handle:_notify_render()
  local level = (not self.done or self.ok) and vim.log.levels.INFO or vim.log.levels.ERROR

  local ok_snacks, Snacks = pcall(require, "snacks")
  if ok_snacks and Snacks.notify then
    Snacks.notify(self:_text_plain(), {
      id = self.notify_id,
      title = "sf",
      level = self.done and (self.ok and "info" or "error") or "info",
      icon = self:_icon(),
    })
    return
  end

  -- Generic fallback (noice.nvim routes/styles this fine; nvim-notify at
  -- least shows a fresh notification per update since it has no
  -- id-based replace API used here).
  vim.notify(self:_text(), level, { id = self.notify_id, title = "sf" })
end

-- ticking ------------------------------------------------------------------

function Handle:_render()
  if self.backend == "notify" then
    self:_notify_render()
  else
    self:_float_render()
  end
end

local function remove_handle(handle)
  for i, h in ipairs(H.handles) do
    if h == handle then
      table.remove(H.handles, i)
      break
    end
  end
end

function Handle:_close()
  if self.backend == "float" then
    self:_float_close()
  end
  remove_handle(self)
end

local function stop_timer_if_idle()
  for _, h in ipairs(H.handles) do
    if not h.done then
      return
    end
  end
  if H.timer then
    H.timer:stop()
    H.timer:close()
    H.timer = nil
  end
end

local function ensure_timer()
  if H.timer then
    return
  end

  local interval = cfg().interval_ms or 80
  H.timer = vim.uv.new_timer()
  H.timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      for _, h in ipairs(H.handles) do
        if not h.done then
          h.frame = h.frame + 1
          h:_render()
        end
      end
      stop_timer_if_idle()
    end)
  )
end

--- Update the message shown while the task is still running.
---@param msg string
function Handle:update(msg)
  self.msg = msg
  vim.schedule(function()
    self:_render()
  end)
end

--- Mark the task finished: shows a ✓/✗ result, then auto-closes after
--- `success_timeout_ms`/`error_timeout_ms`.
---@param ok boolean
---@param msg string|nil
function Handle:finish(ok, msg)
  if self.done then
    return
  end

  self.done = true
  self.ok = ok
  if msg then
    self.msg = msg
  end

  vim.schedule(function()
    self:_render()

    local timeout = ok and (cfg().success_timeout_ms or 3000) or (cfg().error_timeout_ms or 10000)
    vim.defer_fn(function()
      self:_close()
    end, timeout)
  end)
end

-- Module -------------------------------------------------------------------

--- Start a progress handle for a background task.
---@param opts table { msg = string }
---@return table handle with :update(msg) and :finish(ok, msg)
function M.start(opts)
  local handle = setmetatable({
    msg = opts.msg or "",
    started = vim.uv.now(),
    frame = 0,
    done = false,
    ok = nil,
    backend = resolve_backend(),
    notify_id = H.next_id,
  }, Handle)
  H.next_id = H.next_id + 1

  table.insert(H.handles, handle)

  if handle.backend == "float" then
    handle:_float_open()
  else
    handle:_render()
  end

  ensure_timer()

  return handle
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    if H.timer then
      H.timer:stop()
      H.timer:close()
      H.timer = nil
    end
  end,
})

return M
