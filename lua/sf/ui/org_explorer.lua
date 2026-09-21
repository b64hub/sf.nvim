-- Modal org explorer: a plain table (icon, alias, username, expiry for
-- scratch orgs), with `<Tab>` to drill into full `sf org display` detail
-- for the org under the cursor. Not a general-purpose picker -- specific
-- to org records, mirroring `sf org list` for the summary and
-- `sf org display` for detail.
--
-- Performance: `sf org display` is genuinely slow in practice (observed
-- 10-60+ seconds on a real machine, likely CLI update/network checks) and
-- would be wasteful -- possibly minutes -- to prefetch for every org up
-- front. So we never prefetch: detail is fetched lazily, only for the org
-- you expand, run async (never blocks the UI), shown with a spinner while
-- in flight, and cached per-alias for the lifetime of one explorer session
-- so re-expanding the same org is instant.
local Layout = require("sf.ui.layout")
local Icons = require("sf.ui.icons")
local B = require("sf.sub.cmd_builder")

local M = {}
local H = {}

H.SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Never render these, even though `sf org display --json` includes them.
H.REDACT_KEYS = {
  accessToken = true,
  refreshToken = true,
  clientSecret = true,
  sfdxAuthUrl = true,
  privateKey = true,
}

-- Preferred field order for the detail view; anything else returned by the
-- CLI (except redacted keys) is appended after, alphabetically.
H.DETAIL_KEY_ORDER = {
  "alias",
  "username",
  "id",
  "instanceUrl",
  "orgName",
  "edition",
  "apiVersion",
  "connectedStatus",
  "status",
  "isDefaultUsername",
  "isDefaultDevHubUsername",
  "expirationDate",
  "createdDate",
  "devHubId",
}

---@param record table { is_prod, is_sandbox, is_scratch }
---@return string highlight group
H.hl_for = function(record)
  if record.is_prod then
    return "SfStatusProd"
  end
  if record.is_sandbox then
    return "SfStatusSandbox"
  end
  if record.is_scratch then
    return "SfStatusScratch"
  end
  return "SfStatusOrg"
end

---@param s string|nil
---@param width number
---@return string
H.pad = function(s, width)
  s = s or ""
  return s .. string.rep(" ", math.max(width - #s, 0))
end

---@param records table[]
---@return string[] lines, table[] per-line highlight segments
H.render_list_lines = function(records)
  local alias_w, user_w = 0, 0
  for _, r in ipairs(records) do
    alias_w = math.max(alias_w, #(r.alias or ""))
    user_w = math.max(user_w, #(r.username or ""))
  end

  local lines, line_hls = {}, {}

  for i, r in ipairs(records) do
    local marker = r.is_default and "● " or "  "
    local org_part = marker .. Icons.CLOUD .. " " .. H.pad(r.alias, alias_w)
    local user_part = "  " .. H.pad(r.username, user_w)
    local expiry_part = (r.is_scratch and r.expiration_date) and ("  expires " .. r.expiration_date) or ""

    lines[i] = org_part .. user_part .. expiry_part
    line_hls[i] = {
      { group = H.hl_for(r), col_start = 0, col_end = #org_part },
      { group = "SfFooter", col_start = #org_part, col_end = #org_part + #user_part },
    }
  end

  return lines, line_hls
end

---@param record table
---@param frame number|nil spinner frame index while loading (nil once settled)
---@param detail table|nil parsed `sf org display` result, or nil while loading/on error
---@param err string|nil
---@return string[] lines, table[] per-line highlight segments
H.render_detail_lines = function(record, frame, detail, err)
  local lines, line_hls = {}, {}
  local org_part = Icons.CLOUD .. " " .. (record.alias or "")
  lines[1] = org_part
  line_hls[1] = { { group = H.hl_for(record), col_start = 0, col_end = #org_part } }
  lines[2] = ""
  line_hls[2] = {}

  if err then
    lines[3] = "Failed to load: " .. err
    line_hls[3] = { { group = "SfError", col_start = 0, col_end = #lines[3] } }
    return lines, line_hls
  end

  if not detail then
    local spinner = H.SPINNER[(frame % #H.SPINNER) + 1]
    lines[3] = spinner .. " Loading `sf org display`..."
    line_hls[3] = { { group = "SfSpinner", col_start = 0, col_end = #lines[3] } }
    return lines, line_hls
  end

  local seen = {}
  local key_w = 0
  for _, k in ipairs(H.DETAIL_KEY_ORDER) do
    if detail[k] ~= nil then
      key_w = math.max(key_w, #k)
    end
  end
  for k in pairs(detail) do
    if not H.REDACT_KEYS[k] and not vim.tbl_contains(H.DETAIL_KEY_ORDER, k) then
      key_w = math.max(key_w, #k)
    end
  end

  local add_row = function(k, v)
    table.insert(lines, H.pad(k, key_w) .. "  " .. tostring(v))
    table.insert(line_hls, { { group = "SfStatusOrg", col_start = 0, col_end = key_w } })
  end

  for _, k in ipairs(H.DETAIL_KEY_ORDER) do
    if detail[k] ~= nil and not seen[k] then
      add_row(k, detail[k])
      seen[k] = true
    end
  end

  local rest = {}
  for k, v in pairs(detail) do
    if not seen[k] and not H.REDACT_KEYS[k] then
      table.insert(rest, k)
    end
  end
  table.sort(rest)
  for _, k in ipairs(rest) do
    add_row(k, detail[k])
  end

  return lines, line_hls
end

---@param buf integer
---@param lines string[]
---@param line_hls table[]
H.paint = function(buf, lines, line_hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  for lnum, segments in ipairs(line_hls) do
    for _, seg in ipairs(segments) do
      vim.api.nvim_buf_add_highlight(buf, -1, seg.group, lnum - 1, seg.col_start, seg.col_end)
    end
  end
end

---@param record table
---@param on_result fun(detail: table|nil, err: string|nil)
H.fetch_org_display = function(record, on_result)
  local cmd = B:new():cmd("org"):act("display"):addParams("--json"):set_org(record.alias):buildAsTable()

  vim.system(cmd, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        return on_result(nil, "exit code " .. obj.code)
      end
      local ok, parsed = pcall(vim.json.decode, obj.stdout or "")
      if not ok or not parsed or not parsed.result then
        return on_result(nil, "could not parse `sf org display` output")
      end
      on_result(parsed.result, nil)
    end)
  end)
end

--- Show the explorer. `<CR>` calls `opts.on_choice(record)` for the org
--- under the cursor (list view) or currently expanded (detail view).
--- `<Tab>` toggles list/detail. `o` calls `opts.on_open(record)` (e.g. `sf
--- org open`) without closing. `q`/`<Esc>`/`<BS>` go back to the list from
--- detail, or close entirely from the list.
---@param records table[] { alias, username, is_scratch, is_sandbox, is_prod, is_default, expiration_date }
---@param opts table { prompt = string, on_choice = fun(record: table), on_open = fun(record: table)|nil }
function M.pick(records, opts)
  if #records == 0 then
    return vim.notify("Sf: no orgs available. Run :SF org list first.", vim.log.levels.WARN)
  end

  local list_lines, list_hls = H.render_list_lines(records)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "SfOrgExplorer"
  H.paint(buf, list_lines, list_hls)

  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  local has_footer = vim.fn.has("nvim-0.10") == 1

  --- Session state for this one explorer invocation.
  local S = {
    view = "list", -- "list" | "detail"
    detail_alias = nil,
    cache = {}, -- alias -> parsed `sf org display` result
    gen = 0, -- bumped on every view/alias change; guards stale async results
    win = nil,
    spinner_timer = nil,
  }

  local footer_for = function()
    if S.view == "detail" then
      return " <CR> select · o open · <Tab>/q/<BS> back "
    end
    local open_hint = opts.on_open and "o open · " or ""
    return " <CR> select · <Tab> details · " .. open_hint .. "q close "
  end

  local geometry_for = function(lines)
    local content_width = 0
    for _, l in ipairs(lines) do
      content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
    end
    content_width = math.min(content_width, vim.o.columns - 6)
    local content_height = math.min(#lines, vim.o.lines - 8)
    return Layout.float_geometry({
      position = "center",
      width = content_width + 2, -- float_geometry subtracts border cells back off
      height = content_height + 2,
    })
  end

  local geo = geometry_for(list_lines)

  local win_opts = {
    relative = "editor",
    row = geo.row,
    col = geo.col,
    width = geo.width,
    height = geo.height,
    style = "minimal",
    border = ui.border or "rounded",
    title = { { " " .. (opts.prompt or "Select org") .. " ", "SfTitle" } },
    title_pos = "left",
  }
  if has_footer then
    win_opts.footer = { { footer_for(), "SfFooter" } }
    win_opts.footer_pos = "left"
  end

  local win = vim.api.nvim_open_win(buf, true, win_opts)
  S.win = win

  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_option(
    win,
    "winhl",
    "Normal:SfNormal,FloatBorder:SfBorder,FloatTitle:SfTitle,FloatFooter:SfFooter,CursorLine:Visual"
  )

  local stop_spinner = function()
    if S.spinner_timer then
      S.spinner_timer:stop()
      S.spinner_timer:close()
      S.spinner_timer = nil
    end
  end

  local resize = function(lines)
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local g = geometry_for(lines)
    local cfg = { relative = "editor", row = g.row, col = g.col, width = g.width, height = g.height }
    if has_footer then
      cfg.footer = { { footer_for(), "SfFooter" } }
      cfg.footer_pos = "left"
    end
    vim.api.nvim_win_set_config(win, cfg)
  end

  local render_detail = function(record)
    local frame = 0
    local detail = S.cache[record.alias]
    local dlines, dhls = H.render_detail_lines(record, frame, detail, nil)
    resize(dlines)
    H.paint(buf, dlines, dhls)

    if detail then
      return -- cached; nothing to fetch
    end

    local gen = S.gen
    stop_spinner()
    S.spinner_timer = vim.uv.new_timer()
    S.spinner_timer:start(
      0,
      100,
      vim.schedule_wrap(function()
        if gen ~= S.gen or not vim.api.nvim_win_is_valid(win) then
          return
        end
        frame = frame + 1
        local lines2, hls2 = H.render_detail_lines(record, frame, S.cache[record.alias], nil)
        H.paint(buf, lines2, hls2)
      end)
    )

    H.fetch_org_display(record, function(result, err)
      if gen ~= S.gen then
        return -- user moved on (closed, went back, expanded a different org)
      end
      stop_spinner()
      if result then
        S.cache[record.alias] = result
      end
      if vim.api.nvim_win_is_valid(win) then
        local lines3, hls3 = H.render_detail_lines(record, 0, result, err)
        resize(lines3)
        H.paint(buf, lines3, hls3)
      end
    end)
  end

  local render_list = function()
    resize(list_lines)
    H.paint(buf, list_lines, list_hls)
  end

  local current_record = function()
    if S.view == "detail" then
      for _, r in ipairs(records) do
        if r.alias == S.detail_alias then
          return r
        end
      end
      return nil
    end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    return records[row]
  end

  local close = function()
    S.gen = S.gen + 1
    stop_spinner()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local toggle_detail = function()
    S.gen = S.gen + 1
    stop_spinner()
    if S.view == "list" then
      local record = current_record()
      if not record then
        return
      end
      S.view = "detail"
      S.detail_alias = record.alias
      render_detail(record)
    else
      S.view = "list"
      S.detail_alias = nil
      render_list()
    end
  end

  -- q / <Esc> / <BS>: go back to the list from detail, close from the list.
  local back_or_close = function()
    if S.view == "detail" then
      toggle_detail()
    else
      close()
    end
  end

  local select_current = function()
    local record = current_record()
    close()
    if record then
      opts.on_choice(record)
    end
  end

  local open_current = function()
    if not opts.on_open then
      return
    end
    local record = current_record()
    if record then
      opts.on_open(record)
    end
  end

  vim.keymap.set("n", "<CR>", select_current, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Tab>", toggle_detail, { buffer = buf, nowait = true })
  vim.keymap.set("n", "o", open_current, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", back_or_close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", back_or_close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<BS>", back_or_close, { buffer = buf, nowait = true })

  -- `nvim_open_win(..., enter=true, ...)` above already focuses it; this is
  -- belt-and-suspenders for callers that trigger the picker from unusual
  -- contexts (e.g. a lualine mouse click), where focus previously leaked to
  -- whatever buffer was underneath.
  vim.api.nvim_set_current_win(win)
end

return M
