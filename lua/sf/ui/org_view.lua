-- Shared org-record rendering and fetching for the org dashboard. Handles
-- list view (org summary table), detail view (expanded org via `sf org
-- display`), and colour-coding by org type (prod/sandbox/scratch).
--
-- Performance note: `sf org display` is genuinely slow (10-60+ seconds
-- in practice), so it's fetched lazily: only for the org you expand, run
-- async, shown with a spinner while in flight, and cached for re-renders in a
-- single session.

local cmd_builder = require("sf.sub.cmd_builder")
local rest_api = require("sf.sub.rest_api")
local Icons = require("sf.ui.icons")

local org_view = {}

-- Animation frames for the loading spinner, shown while `sf org display`
-- is in flight.
org_view.SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Never render these keys from `sf org display --json`, even though they're
-- in the output. Secrets that should stay in the org's auth context only.
org_view.REDACT_KEYS = {
  accessToken = true,
  refreshToken = true,
  clientSecret = true,
  sfdxAuthUrl = true,
  privateKey = true,
}

-- Preferred field order for the detail view; any remaining keys returned by
-- the CLI (except redacted ones) are appended alphabetically after this list.
org_view.DETAIL_KEY_ORDER = {
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
---@return string highlight group name
function org_view.highlight_for(record)
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

---@param str string|nil
---@param width number
---@return string padded string
function org_view.pad(str, width)
  str = str or ""
  return str .. string.rep(" ", math.max(width - #str, 0))
end

--- Calculate days remaining until a date. Used for scratch-org expiry display.
--- @param date_string string|nil ISO8601 date string (e.g. "2025-01-15T00:00:00.000Z")
--- @param now_timestamp integer|nil Unix timestamp for testing; defaults to os.time()
--- @return string|nil "14d", "6d", "today", "expired", or nil if unparseable
function org_view.days_until(date_string, now_timestamp)
  if not date_string or date_string == "" then
    return nil
  end

  -- Parse ISO8601 format. Expect YYYY-MM-DD at start, possibly followed by
  -- T and time. The date part is all we need for expiry calculations.
  local year, month, day = date_string:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if not year then
    return nil
  end

  -- ponytail: `os.time(table)` interprets the parsed date at local-midnight,
  -- not UTC-midnight (unlike debug.lua's parse_sf_datetime, which corrects
  -- for that). At day granularity the bucket only shifts if the local
  -- timezone offset pushes the instant across a day boundary; fine for a
  -- "~14d/6d" display. Upgrade path: mirror debug.lua's UTC correction if
  -- this ever needs to be exact.
  local now = now_timestamp or os.time()
  local target_time = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 0, min = 0, sec = 0 })
  local seconds_until = target_time - now
  local days_until = math.ceil(seconds_until / 86400)

  if days_until < 0 then
    return "expired"
  elseif days_until == 0 then
    return "today"
  elseif days_until <= 7 then
    return days_until .. "d"
  else
    -- Only show in short form up to a week out; beyond that, expiry
    -- isn't the urgent detail (you can see the full date in details view).
    return nil
  end
end

---@param records table[]
---@return string[] lines, table[] per-line highlight segments
function org_view.render_list_lines(records)
  local alias_w, user_w = 0, 0
  for _, record in ipairs(records) do
    alias_w = math.max(alias_w, #(record.alias or ""))
    user_w = math.max(user_w, #(record.username or ""))
  end

  local lines, line_hls = {}, {}

  for i, record in ipairs(records) do
    -- Marker: ● = default target org, ◆ = default devhub, ◈ = both
    local marker
    if record.is_default and record.is_default_devhub then
      marker = "◈ "
    elseif record.is_default then
      marker = "● "
    elseif record.is_default_devhub then
      marker = "◆ "
    else
      marker = "  "
    end

    local org_part = marker .. Icons.CLOUD .. " " .. org_view.pad(record.alias, alias_w)
    local user_part = "  " .. org_view.pad(record.username, user_w)

    -- Relative expiry for scratch orgs only; use days_until for short-form display
    local expiry_part = ""
    if record.is_scratch and record.expiration_date then
      local relative = org_view.days_until(record.expiration_date)
      if relative then
        expiry_part = "  expires " .. relative
      end
    end

    lines[i] = org_part .. user_part .. expiry_part
    line_hls[i] = {
      { group = org_view.highlight_for(record), col_start = 0, col_end = #org_part },
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
function org_view.render_detail_lines(record, frame, detail, err)
  local lines, line_hls = {}, {}
  local org_part = Icons.CLOUD .. " " .. (record.alias or "")
  lines[1] = org_part
  line_hls[1] = { { group = org_view.highlight_for(record), col_start = 0, col_end = #org_part } }
  lines[2] = ""
  line_hls[2] = {}

  if err then
    lines[3] = "Failed to load: " .. err
    line_hls[3] = { { group = "SfError", col_start = 0, col_end = #lines[3] } }
    return lines, line_hls
  end

  if not detail then
    local spinner = org_view.SPINNER_FRAMES[(frame % #org_view.SPINNER_FRAMES) + 1]
    lines[3] = spinner .. " Loading `sf org display`..."
    line_hls[3] = { { group = "SfSpinner", col_start = 0, col_end = #lines[3] } }
    return lines, line_hls
  end

  local seen = {}
  local key_w = 0
  for _, key in ipairs(org_view.DETAIL_KEY_ORDER) do
    if detail[key] ~= nil then
      key_w = math.max(key_w, #key)
    end
  end
  for key in pairs(detail) do
    if not org_view.REDACT_KEYS[key] and not vim.tbl_contains(org_view.DETAIL_KEY_ORDER, key) then
      key_w = math.max(key_w, #key)
    end
  end

  local add_row = function(key, value)
    table.insert(lines, org_view.pad(key, key_w) .. "  " .. tostring(value))
    table.insert(line_hls, { { group = "SfStatusOrg", col_start = 0, col_end = key_w } })
  end

  for _, key in ipairs(org_view.DETAIL_KEY_ORDER) do
    if detail[key] ~= nil and not seen[key] then
      add_row(key, detail[key])
      seen[key] = true
    end
  end

  local rest = {}
  for key in pairs(detail) do
    if not seen[key] and not org_view.REDACT_KEYS[key] then
      table.insert(rest, key)
    end
  end
  table.sort(rest)
  for _, key in ipairs(rest) do
    add_row(key, detail[key])
  end

  return lines, line_hls
end

---@param buf integer
---@param lines string[]
---@param line_hls table[]
function org_view.paint(buf, lines, line_hls)
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

--- Render tabular data with aligned columns.
--- Coerce a cell to a safe string for width/length math. Defensive against
--- `vim.NIL` (Neovim's truthy userdata sentinel for a decoded JSON `null`,
--- which crashed `#cell` here on an unmanaged package's null
--- `NamespacePrefix` -- see rest_api.lua's cli_json_call for the fuller
--- story) and any other non-string a caller passes through, e.g. a number.
---@param cell any
---@return string
local function safe_cell_text(cell)
  if type(cell) == "string" then
    return cell
  elseif cell == nil or cell == vim.NIL then
    return ""
  end
  return tostring(cell)
end

--- Computes column widths as the maximum cell width in each column,
--- joins cells with a two-space gap, and applies whole-line highlights.
---@param rows table[] array of { cells = {"text", ...}, highlight = "SfWarn"|nil }
---@return string[] lines, table[] per-line highlight segments
function org_view.render_columns(rows)
  if #rows == 0 then
    return {}, {}
  end

  -- Compute column widths
  local col_widths = {}
  for _, row in ipairs(rows) do
    if row.cells then
      for col_idx, cell in ipairs(row.cells) do
        col_widths[col_idx] = math.max(col_widths[col_idx] or 0, #safe_cell_text(cell))
      end
    end
  end

  -- ponytail: width is byte length (#cell), same ASCII assumption as org_view.pad;
  -- upgrade path is vim.fn.strdisplaywidth if non-ASCII aliases ever misalign.
  local lines = {}
  local line_hls = {}
  local gap = "  "

  for _, row in ipairs(rows) do
    if row.cells then
      local padded_cells = {}
      local last_col_idx = #row.cells
      local col_byte_ranges = {} -- track [col_idx] = { byte_start, byte_end }
      local byte_offset = 0

      for col_idx, cell in ipairs(row.cells) do
        -- Don't pad the last column -- matches render_list_lines'
        -- convention (its trailing expiry_part is never padded) and
        -- avoids meaningless trailing whitespace on every row.
        local cell_text = safe_cell_text(cell)
        local cell_byte_len = #cell_text
        col_byte_ranges[col_idx] = { byte_offset, byte_offset + cell_byte_len }

        if col_idx == last_col_idx then
          table.insert(padded_cells, cell_text)
          byte_offset = byte_offset + cell_byte_len
        else
          local width = col_widths[col_idx] or 0
          local padded = org_view.pad(cell_text, width)
          table.insert(padded_cells, padded)
          byte_offset = byte_offset + #padded
        end

        -- Add gap between columns (except after the last one)
        if col_idx < last_col_idx then
          byte_offset = byte_offset + #gap
        end
      end

      local line = table.concat(padded_cells, gap)
      table.insert(lines, line)

      -- Apply whole-line highlight if specified, and per-cell highlights
      local hls = {}
      if row.highlight then
        table.insert(hls, { group = row.highlight, col_start = 0, col_end = #line })
      end
      if row.cell_highlights then
        for col_idx, highlight_group in pairs(row.cell_highlights) do
          local range = col_byte_ranges[col_idx]
          if range then
            table.insert(hls, { group = highlight_group, col_start = range[1], col_end = range[2] })
          end
        end
      end
      table.insert(line_hls, hls)
    end
  end

  return lines, line_hls
end

---@param record table
---@param on_result fun(detail: table|nil, err: string|nil)
function org_view.fetch_org_display(record, on_result)
  -- Fetch via shared, cached, coalesced rest_api.get_org_display:
  -- deduplicates identical spawns across all dashboard views
  rest_api.get_org_display(record.alias, function(result, err)
    if err then
      return on_result(nil, "could not parse `sf org display` output")
    end
    on_result(result, nil)
  end)
end

return org_view
