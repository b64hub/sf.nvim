-- Small progress/spinner widget for quiet background tasks (deploy,
-- retrieve, etc), so they don't need to pop open a terminal float.
-- Two backends:
--  - "float": a small non-focusable bottom-right window (stacks with others)
--  - "notify": vim.notify, updated in place via a stable `id`
local Layout = require("sf.ui.layout")

local progress = {}
local registry = { handles = {}, timer = nil, next_id = 1 }

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

--- Highlight the trailing "→ alias" / "← alias" segment of a progress
--- message (if present) with `SfWarn` (a subtle, contrasting yellow by
--- default) so the target org alias stands out from "Deploy foo.cls done".
---@param buf number
---@param ns number
---@param line string
---@param lnum number 0-indexed line number
local function highlight_alias(buf, ns, line, lnum)
  for _, arrow in ipairs({ "→ ", "← " }) do
    local _, arrow_end = line:find(arrow, 1, true)
    if arrow_end then
      vim.api.nvim_buf_add_highlight(buf, ns, "SfWarn", lnum, arrow_end, -1)
      return
    end
  end
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
  for _, entry in ipairs(registry.handles) do
    if entry.backend == "float" and entry.win and vim.api.nvim_win_is_valid(entry.win) then
      local geo = entry:_float_geometry(idx)
      vim.api.nvim_win_set_config(entry.win, {
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
  for _, entry in ipairs(registry.handles) do
    if entry == self then
      break
    end
    if entry.backend == "float" and entry.win then
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

  local text = self:_text()
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { text })
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, -1, 0, -1)
  vim.api.nvim_buf_add_highlight(self.buf, -1, self:_hl(), 0, 0, -1)
  highlight_alias(self.buf, -1, text, 0)
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

--- Snacks notifier custom render: identical to the built-in "compact"
--- style (title in the border, message as buffer lines), plus
--- `highlight_alias` on the message body -- Snacks has no per-substring
--- highlight hook otherwise, so the default style can't do this alone.
---@param buf number
---@param notif table
---@param ctx table
local function snacks_alias_style(buf, notif, ctx)
  local title = vim.trim((notif.icon or "") .. " " .. (notif.title or ""))
  if title ~= "" then
    ctx.opts.title = { { " " .. title .. " ", ctx.hl.title } }
    ctx.opts.title_pos = "center"
  end

  local lines = vim.split(notif.msg, "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i, line in ipairs(lines) do
    highlight_alias(buf, ctx.ns, line, i - 1)
  end
end

function Handle:_notify_render()
  local level = (not self.done or self.ok) and vim.log.levels.INFO or vim.log.levels.ERROR

  local ok_snacks, Snacks = pcall(require, "snacks")
  if ok_snacks and Snacks.notify then
    Snacks.notify(self:_text_plain(), {
      id = self.notify_id,
      title = "sf",
      level = self.done and (self.ok and "info" or "error") or "info",
      icon = self:_icon(),
      style = snacks_alias_style,
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
  for i, entry in ipairs(registry.handles) do
    if entry == handle then
      table.remove(registry.handles, i)
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
  for _, entry in ipairs(registry.handles) do
    if not entry.done then
      return
    end
  end
  if registry.timer then
    registry.timer:stop()
    registry.timer:close()
    registry.timer = nil
  end
end

local function ensure_timer()
  if registry.timer then
    return
  end

  local interval = cfg().interval_ms or 80
  registry.timer = vim.uv.new_timer()
  registry.timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      for _, entry in ipairs(registry.handles) do
        if not entry.done then
          entry.frame = entry.frame + 1
          entry:_render()
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
function progress.start(opts)
  local handle = setmetatable({
    msg = opts.msg or "",
    started = vim.uv.now(),
    frame = 0,
    done = false,
    ok = nil,
    backend = resolve_backend(),
    notify_id = registry.next_id,
  }, Handle)
  registry.next_id = registry.next_id + 1

  table.insert(registry.handles, handle)

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
    if registry.timer then
      registry.timer:stop()
      registry.timer:close()
      registry.timer = nil
    end
  end,
})

return progress
