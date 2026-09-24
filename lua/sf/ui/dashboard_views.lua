-- Registry of view descriptors for the org dashboard right pane.
-- Each descriptor defines how to fetch, render, and act on a view.
-- Adding a new view is just adding an entry to this array.

local util = require("sf.util")
local org_view = require("sf.ui.org_view")
local org_status = require("sf.sub.org_status")
local rest_api = require("sf.sub.rest_api")
local Org = require("sf.org")
local Debug = require("sf.debug")

--- Format one log record the same way whether it's being rendered or
--- filtered, so a filter query can never drift from what's actually shown.
---@param log table { user, start_time, size, status }
---@return string
--- Truncate text to a maximum width, appending "..." if truncated.
--- Uses ASCII "..." so byte length stays consistent with render_columns.
---@param text string
---@param max_width number
---@return string truncated text
local function truncate(text, max_width)
  if #text <= max_width then
    return text
  end
  return string.sub(text, 1, max_width - 3) .. "..."
end

local function format_log_line(log)
  -- Truncate operation to 30 chars to keep overall line width reasonable
  local operation = truncate(log.operation or "", 30)
  return string.format(
    "%s | %s | %s | %s | %s",
    log.user,
    string.gsub(log.start_time, "T", " "),
    operation,
    util.format_bytes(log.size),
    log.status
  )
end

--- Filter logs by case-insensitive substring match against any rendered field.
--- Empty or nil query returns all logs unchanged.
---@param logs table[] array of { id, user, start_time, size, status }
---@param query string|nil search query (case-insensitive substring match)
---@return table[] filtered logs
local function filter_logs(logs, query)
  if not query or query == "" then
    return logs
  end

  local query_lower = string.lower(query)
  local filtered = {}

  for _, log in ipairs(logs) do
    if string.find(string.lower(format_log_line(log)), query_lower, 1, true) then
      table.insert(filtered, log)
    end
  end

  return filtered
end

--- Highlight group for a given instance status string.
---@param status string
---@return string
local function status_highlight(status)
  if status == "OK" then
    return "SfSuccess"
  elseif status == "unknown" then
    return "SfWarn"
  end
  return "SfError" -- any incident/maintenance/degraded state
end

--- Parse a Salesforce datetime string (e.g. "2024-01-01T00:00:00.000+0000")
--- into remaining minutes from now, formatted as a string.
--- @param datetime_str string Salesforce ISO datetime string
--- @return string formatted remaining time (e.g. "expires in 47 min", "expires in 2h", "expired")
local function format_trace_flag_expiry(datetime_str)
  if not datetime_str or datetime_str == "" then
    return "no expiry"
  end

  -- Parse Salesforce datetime: "2024-01-01T00:00:00.000+0000"
  local year, month, day, hour, minute, second = datetime_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not year then
    return "invalid date"
  end

  -- Convert parsed UTC fields to Unix timestamp, correcting for local timezone
  local parsed_table = {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(minute),
    sec = tonumber(second),
  }
  local now = os.time()
  local utc_now = os.date("!*t", now)
  local local_now = os.date("*t", now)
  utc_now.isdst = local_now.isdst
  local offset = os.difftime(os.time(local_now), os.time(utc_now))
  local expiry_timestamp = os.time(parsed_table) + offset

  local remaining_secs = expiry_timestamp - now
  if remaining_secs < 0 then
    return "expired"
  end

  local remaining_mins = math.floor(remaining_secs / 60)
  if remaining_mins < 1 then
    return "expires soon"
  elseif remaining_mins < 60 then
    return string.format("expires in %d min", remaining_mins)
  else
    local hours = math.floor(remaining_mins / 60)
    return string.format("expires in %dh", hours)
  end
end

--- Format org limits data into an array of rows for rendering.
--- Computes used count and percentage for each limit, with a guard against
--- division by zero for limits with Max=0.
---@param decoded table API response { limit_name = { Max = number, Remaining = number }, ... }
---@return table[] array of rows, each with { name, remaining, max_val, used_count, used_percent }
---  Rows are sorted with DailyApiRequests, DataStorageMB, FileStorageMB first if present,
---  then remaining entries sorted alphabetically by name.
local function format_limits(decoded)
  local rows = {}

  for name, limit_data in pairs(decoded) do
    if limit_data and type(limit_data) == "table" then
      local max_val = limit_data.Max or 0
      local remaining = limit_data.Remaining or 0
      local used_count = max_val - remaining
      local used_percent = (max_val > 0) and (used_count / max_val * 100) or 0

      table.insert(rows, {
        name = name,
        remaining = remaining,
        max_val = max_val,
        used_count = used_count,
        used_percent = used_percent,
      })
    end
  end

  -- Sort: interesting limits first (DailyApiRequests, DataStorageMB, FileStorageMB), then alphabetically
  local priority_order = {
    DailyApiRequests = 1,
    DataStorageMB = 2,
    FileStorageMB = 3,
  }
  table.sort(rows, function(row_a, row_b)
    local priority_a = priority_order[row_a.name] or 999
    local priority_b = priority_order[row_b.name] or 999

    if priority_a ~= priority_b then
      return priority_a < priority_b
    end
    return row_a.name < row_b.name
  end)

  return rows
end

--- Format an ISO8601 status-API datetime ("2026-10-09T21:30:00.000Z") into
--- a compact "YYYY-MM-DD HH:MM" for display; passes through unparseable or
--- missing input as an empty string rather than erroring.
---@param iso_datetime string|nil
---@return string
local function format_status_date(iso_datetime)
  if not iso_datetime or iso_datetime == "" then
    return ""
  end
  local date_part, time_part = iso_datetime:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
  if date_part then
    return date_part .. " " .. time_part
  end
  return iso_datetime
end

--- Check if an ISO datetime string is in the past.
---@param iso_datetime string|nil ISO 8601 datetime (e.g. "2026-08-23T11:20:00Z")
---@return boolean true if the datetime is before now, false if future/missing
local function is_past(iso_datetime)
  if not iso_datetime or iso_datetime == "" then
    return false
  end
  -- Parse YYYY-MM-DDTHH:MM pattern
  local year, month, day, hour, minute = iso_datetime:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
  if not year then
    return false
  end
  local timestamp = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = tonumber(hour), min = tonumber(minute), sec = 0 })
  return timestamp < os.time()
end

--- Append a titled table section (a header row plus data rows, or a
--- fallback message when there are no rows) to `lines`/`line_hls` in
--- place, followed by a blank separator line. Shared by the
--- Products/Maintenances/Messages sections of render_status_section so the
--- "title + table-or-empty-message" shape isn't repeated three times.
---@param lines string[] appended in place
---@param line_hls table[] appended in place
---@param title string section title, rendered as "Title:"
---@param header_cells string[] column headers
---@param rows table[] each a { cells = {...} } row for org_view.render_columns
---@param empty_message string shown instead of a table when rows is empty
local function append_table_section(lines, line_hls, title, header_cells, rows, empty_message)
  table.insert(lines, title .. ":")
  table.insert(line_hls, {})

  if #rows == 0 then
    table.insert(lines, empty_message)
    table.insert(line_hls, {})
  else
    local col_rows = { { cells = header_cells, highlight = "SfTableHeader" } }
    vim.list_extend(col_rows, rows)
    local table_lines, table_hls = org_view.render_columns(col_rows)
    vim.list_extend(lines, table_lines)
    vim.list_extend(line_hls, table_hls)
  end

  table.insert(lines, "")
  table.insert(line_hls, {})
end

--- Render the org status section for the merged details view: overall
--- status, instance info (location/release/maintenance window), and
--- tabulated Products/Maintenances/Messages/Incidents from the real
--- status.salesforce.com response (see org_status.parse_instance_status).
--- Returns a single error line on error, never an empty section.
---@param status_data table|nil the result of org_status.fetch (or nil on error)
---@param status_err string|nil error message from org_status.fetch
---@return string[] lines, table[] per-line highlight segments
local function render_status_section(status_data, status_err)
  local lines, line_hls = {}, {}

  if status_err then
    local err_line = "Org status unavailable: " .. status_err
    table.insert(lines, err_line)
    table.insert(line_hls, { { group = "SfError", col_start = 0, col_end = #err_line } })
    return lines, line_hls
  end

  if not status_data then
    -- This should not happen if fetch properly guards against it,
    -- but defend gracefully just in case.
    local err_line = "Org status unavailable: no data returned"
    table.insert(lines, err_line)
    table.insert(line_hls, { { group = "SfError", col_start = 0, col_end = #err_line } })
    return lines, line_hls
  end

  local status_line = "Status: " .. status_data.status
  table.insert(lines, status_line)
  table.insert(line_hls, { { group = status_highlight(status_data.status), col_start = 0, col_end = #status_line } })
  table.insert(lines, "")
  table.insert(line_hls, {})

  -- Instance info: only the fields the API actually returned (older
  -- fixtures / a genuinely sparse response just skip this block).
  local info_rows = {}
  local add_info_row = function(label, value)
    if value then
      table.insert(info_rows, { cells = { label, value }, cell_highlights = { [1] = "SfDim" } })
    end
  end
  add_info_row("Instance", status_data.instance_name)
  add_info_row("Location", status_data.location)
  add_info_row("Environment", status_data.environment)
  add_info_row("Release", status_data.release_version)
  add_info_row("Maintenance window", status_data.maintenance_window)
  if #info_rows > 0 then
    local info_lines, info_hls = org_view.render_columns(info_rows)
    vim.list_extend(lines, info_lines)
    vim.list_extend(line_hls, info_hls)
    table.insert(lines, "")
    table.insert(line_hls, {})
  end

  local product_rows = {}
  for _, product in ipairs(status_data.products or {}) do
    local row = {
      cells = { product.name, product.is_active and "Available" or "Unavailable" },
    }
    -- Inactive products get warning highlight; active ones use normal weight
    if not product.is_active then
      row.highlight = "SfWarn"
    else
      row.cell_highlights = { [2] = "SfDim" } -- dim the redundant "Available" label
    end
    table.insert(product_rows, row)
  end
  append_table_section(lines, line_hls, "Products", { "Product", "Status" }, product_rows, "No product data.")

  local maintenance_rows = {}
  for _, maintenance in ipairs(status_data.maintenances or {}) do
    local row = {
      cells = {
        truncate(maintenance.name, 40),
        maintenance.status,
        format_status_date(maintenance.planned_start),
        format_status_date(maintenance.planned_end),
      },
    }
    if is_past(maintenance.planned_end) then
      row.highlight = "SfDim"
    end
    table.insert(maintenance_rows, row)
  end
  append_table_section(
    lines,
    line_hls,
    "Maintenances",
    { "Maintenance", "Status", "Start", "End" },
    maintenance_rows,
    "No scheduled maintenance."
  )

  local message_rows = {}
  for _, general_message in ipairs(status_data.messages or {}) do
    local row = {
      cells = {
        truncate(general_message.subject, 50),
        general_message.status,
        format_status_date(general_message.start_date),
        format_status_date(general_message.end_date),
      },
    }
    if general_message.status == "Resolved" then
      row.highlight = "SfDim"
    end
    table.insert(message_rows, row)
  end
  append_table_section(
    lines,
    line_hls,
    "Messages",
    { "Message", "Status", "Start", "End" },
    message_rows,
    "No general messages."
  )

  local incident_rows = {}
  for _, incident in ipairs(status_data.incidents or {}) do
    local row = {
      cells = {
        truncate(incident.message or incident.type or incident.id or "(no details)", 40),
        incident.status or "unknown",
        incident.type or "",
        incident.severity or "",
        format_status_date(incident.impact_start),
        format_status_date(incident.impact_end),
      },
    }
    if incident.status == "Resolved" then
      row.highlight = "SfDim"
    elseif incident.severity and incident.severity ~= "minor" then
      row.highlight = "SfError"
    else
      row.highlight = "SfWarn"
    end
    table.insert(incident_rows, row)
  end
  append_table_section(
    lines,
    line_hls,
    "Incidents",
    { "Incident", "Status", "Type", "Severity", "Start", "End" },
    incident_rows,
    "No incidents reported."
  )

  return lines, line_hls
end

--- Flatten a raw Tooling API InstalledSubscriberPackage record into a simple table.
--- Handles missing nested fields gracefully, falling back to sensible defaults.
---@param raw_record table raw record from Tooling API with nested SubscriberPackage and SubscriberPackageVersion fields
---@return table { name, namespace, version } a flat record safe to render
--- Type-checked accessor for a Tooling API field: the API decodes a JSON
--- `null` to Neovim's truthy `vim.NIL` userdata sentinel when a caller
--- goes through an unpatched vim.json.decode (rest_api.lua's own decode
--- calls are patched -- see cli_json_call -- but this stays defensive in
--- case some future caller isn't). A plain `field or default` does not
--- catch that, since `vim.NIL` is truthy; this does, by checking `type`.
---@param value any
---@return string|nil
local function as_string_field(value)
  if type(value) == "string" then
    return value
  end
  return nil
end

---@param value any
---@return number|nil
local function as_number_field(value)
  if type(value) == "number" then
    return value
  end
  return nil
end

local function flatten_package_row(raw_record)
  local subscriber_package = raw_record.SubscriberPackage or {}
  local package_version = raw_record.SubscriberPackageVersion or {}

  local name = as_string_field(subscriber_package.Name) or "unknown"
  local namespace = as_string_field(subscriber_package.NamespacePrefix) or "unmanaged"
  local major = as_number_field(package_version.MajorVersion)
  local minor = as_number_field(package_version.MinorVersion)

  local version
  if major ~= nil and minor ~= nil then
    version = string.format("%d.%d", major, minor)
  else
    version = "unknown"
  end

  return {
    name = name,
    namespace = namespace,
    version = version,
  }
end

local views = {
  {
    id = "details",
    key = "d",
    label = "Details",
    fetch = function(record, callback)
      -- Fetch both detail and status in parallel with a pending counter.
      -- Call back exactly once with both halves, always with err = nil
      -- so paint_view doesn't blank the whole pane on partial failure.
      local pending = 2
      local detail_result = { data = nil, err = nil }
      local status_result = { data = nil, err = nil }

      local check_complete = function()
        pending = pending - 1
        if pending == 0 then
          -- Always pass err = nil to avoid blanking the pane on partial failure.
          callback(
            {
              detail = detail_result.data,
              detail_err = detail_result.err,
              status = status_result.data,
              status_err = status_result.err,
            },
            nil
          )
        end
      end

      -- Fetch org details
      org_view.fetch_org_display(record, function(detail_data, detail_err)
        detail_result.data = detail_data
        detail_result.err = detail_err
        check_complete()
      end)

      -- Fetch org status
      rest_api.get_session(record.alias, function(session, session_err)
        if not session then
          status_result.data = nil
          status_result.err = session_err or "could not get session"
          check_complete()
        else
          org_status.fetch(session, function(status_data, status_err)
            status_result.data = status_data
            status_result.err = status_err
            check_complete()
          end)
        end
      end)
    end,
    render = function(record, data)
      local lines, line_hls = {}, {}

      -- Render details section (org_view.render_detail_lines expects non-nil detail_err when detail is nil)
      local detail_lines, detail_hls = org_view.render_detail_lines(record, nil, data.detail, data.detail_err)
      vim.list_extend(lines, detail_lines)
      vim.list_extend(line_hls, detail_hls)

      -- Add separator blank line
      table.insert(lines, "")
      table.insert(line_hls, {})

      -- Render status section
      local status_lines, status_hls = render_status_section(data.status, data.status_err)
      vim.list_extend(lines, status_lines)
      vim.list_extend(line_hls, status_hls)

      return lines, line_hls
    end,
    action = nil,
  },
  {
    id = "set_local_default",
    key = "L",
    label = "Set Local Default",
    -- Org-scoped action: shown in the left (org list) pane's footer.
    pane = "left",
    fetch = nil,
    render = nil,
    action = function(record, dashboard_api)
      Org.set_target_org_to(record.alias, false)
      dashboard_api.repaint_list()
    end,
  },
  {
    id = "set_global_default",
    key = "G",
    label = "Set Global Default",
    -- Org-scoped action: shown in the left (org list) pane's footer.
    pane = "left",
    fetch = nil,
    render = nil,
    action = function(record, dashboard_api)
      Org.set_target_org_to(record.alias, true)
      dashboard_api.repaint_list()
      vim.notify("Global target_org set: " .. record.alias, vim.log.levels.INFO)
    end,
  },
  {
    id = "open_org",
    key = "o",
    label = "Open",
    -- Org-scoped action: shown in the left (org list) pane's footer.
    pane = "left",
    fetch = nil,
    render = nil,
    action = function(record, _)
      Org.open_org(record.alias)
    end,
  },
  {
    id = "trace_flags",
    key = "t",
    label = "Trace Flags",
    fetch = function(record, callback)
      rest_api.get_session(record.alias, function(session, err)
        if not session then
          return callback(nil, err)
        end
        local soql =
          "SELECT Id, DebugLevel.DeveloperName, ExpirationDate, TracedEntity.Name FROM TraceFlag ORDER BY ExpirationDate DESC"
        rest_api.query(session, soql, function(records, query_err)
          if not records then
            return callback(nil, query_err)
          end
          callback(records, nil)
        end)
      end)
    end,
    render = function(_, data)
      local lines, line_hls = {}, {}

      if #data == 0 then
        table.insert(lines, "No active trace flags.")
        table.insert(line_hls, {})
        return lines, line_hls
      end

      local col_rows = {
        { cells = { "Entity", "Debug Level", "Expiry" }, highlight = "SfTableHeader" },
      }

      for _, flag in ipairs(data) do
        local traced_entity = flag.TracedEntity and flag.TracedEntity.Name or "(unknown)"
        local debug_level = flag.DebugLevel and flag.DebugLevel.DeveloperName or "(unknown)"
        local expiry = format_trace_flag_expiry(flag.ExpirationDate)
        table.insert(col_rows, { cells = { traced_entity, debug_level, expiry } })
      end

      return org_view.render_columns(col_rows)
    end,
    action = nil,
  },
  {
    id = "enable_logging",
    key = "e",
    label = "Enable Logging",
    -- View-scoped action (not org-identity related): shown in the right
    -- (detail view) pane's footer alongside refresh/filter/close.
    pane = "right",
    fetch = nil,
    render = nil,
    action = function(record, _)
      Debug.enable_replay_logging({ alias = record.alias })
    end,
  },
  {
    id = "logs",
    key = "l",
    label = "Logs",
    fetch = function(record, callback)
      Org.list_org_logs(record.alias, callback)
    end,
    render = function(_, data)
      local lines, line_hls = {}, {}

      if #data == 0 then
        table.insert(lines, "No logs found.")
        table.insert(line_hls, {})
        return lines, line_hls
      end

      -- Header row: org_dashboard.lua's <CR> handler accounts for this
      -- extra line when mapping the view cursor row back into
      -- session.filtered_logs (row 1 is the header, not the first log).
      local col_rows = {
        { cells = { "User", "Started", "Operation", "Size", "Status" }, highlight = "SfTableHeader" },
      }

      for _, log in ipairs(data) do
        table.insert(col_rows, {
          cells = {
            log.user,
            string.gsub(log.start_time, "T", " "),
            truncate(log.operation or "", 30),
            util.format_bytes(log.size),
            log.status,
          },
          highlight = nil,
        })
      end

      return org_view.render_columns(col_rows)
    end,
    action = nil,
  },
  {
    id = "limits",
    key = "u",
    label = "Limits",
    fetch = function(record, callback)
      rest_api.get_session(record.alias, function(session, err)
        if not session then
          return callback(nil, err)
        end
        rest_api.curl_json({
          "-G",
          string.format("%s/services/data/v%s/limits", session.url, session.api_version),
          "-H",
          "Authorization: Bearer " .. session.token,
        }, function(decoded, err)
          if not decoded then
            return callback(nil, err)
          end
          callback(decoded, nil)
        end)
      end)
    end,
    render = function(_, data)
      local lines, line_hls = {}, {}
      local formatted_rows = format_limits(data)

      if #formatted_rows == 0 then
        table.insert(lines, "No limits data found.")
        table.insert(line_hls, {})
        return lines, line_hls
      end

      -- Build header row
      local col_rows = {}
      table.insert(col_rows, {
        cells = { "Limit", "Used", "Max", "%" },
        highlight = "SfTableHeader",
      })

      -- Build data rows
      for _, row in ipairs(formatted_rows) do
        table.insert(col_rows, {
          cells = {
            row.name,
            tostring(row.used_count),
            tostring(row.max_val),
            string.format("%.0f", row.used_percent),
          },
          highlight = row.used_percent >= 80 and "SfWarn" or nil,
        })
      end

      return org_view.render_columns(col_rows)
    end,
    action = nil,
  },
  {
    id = "packages",
    key = "p",
    label = "Packages",
    fetch = function(record, callback)
      rest_api.get_session(record.alias, function(session, err)
        if not session then
          return callback(nil, err)
        end
        local soql =
          "SELECT SubscriberPackage.Name, SubscriberPackage.NamespacePrefix, SubscriberPackageVersion.MajorVersion, SubscriberPackageVersion.MinorVersion FROM InstalledSubscriberPackage"
        rest_api.query(session, soql, function(records, query_err)
          if not records then
            return callback(nil, query_err)
          end
          callback(records, nil)
        end)
      end)
    end,
    render = function(_, data)
      local lines, line_hls = {}, {}

      if #data == 0 then
        table.insert(lines, "No packages installed.")
        table.insert(line_hls, {})
        return lines, line_hls
      end

      -- Build header row
      local col_rows = {}
      table.insert(col_rows, {
        cells = { "Package", "Namespace", "Version" },
        highlight = "SfTableHeader",
      })

      -- Build data rows
      for _, raw_record in ipairs(data) do
        local flattened = flatten_package_row(raw_record)
        table.insert(col_rows, {
          cells = { flattened.name, flattened.namespace, flattened.version },
          highlight = nil,
        })
      end

      return org_view.render_columns(col_rows)
    end,
    action = nil,
  },
}

--- Return the tab views (entries with a non-nil render function).
--- These are the views shown in the tab strip.
---@return table[] array of view descriptors that have a render function
function views.tab_views()
  local tabs = {}
  for _, view_desc in ipairs(views) do
    if view_desc.render then
      table.insert(tabs, view_desc)
    end
  end
  return tabs
end

--- Return the action-only views (entries with action and no fetch/render).
--- These are shown in the footer only, not in the tab strip.
---@param pane string|nil "left"|"right" to filter by the descriptor's `pane`
---  field (which footer it belongs in); omit for every action view.
---@return table[] array of view descriptors that are action-only
function views.action_views(pane)
  local actions = {}
  for _, view_desc in ipairs(views) do
    if view_desc.action and not view_desc.fetch and not view_desc.render and (not pane or view_desc.pane == pane) then
      table.insert(actions, view_desc)
    end
  end
  return actions
end

--- Render a tab strip from the list of tab views.
--- Render a winbar string for the view pane with clickable tabs.
--- Each tab is a clickable segment built from views.tab_views(). No key
--- prefix or separator glyph: the active/inactive highlight change on each
--- segment's own background is the boundary between tabs (the same
--- pill/segment look powerline-style statuslines get from adjacent
--- highlight groups, no separator character needed) -- this is 'statusline'
--- syntax (see :h statusline), which winbar reuses; %#Group# is its only
--- native coloring primitive and %N@Handler@...%X its only native click
--- primitive. There is no native tab-separator or prev/next-navigation
--- item, so cycling (h/l, arrows) and direct-key jumps stay real Lua
--- keymaps, not winbar features.
---@param active_view_id string the id of the currently active view
---@return string winbar string with clickable regions and highlights
function views.render_winbar(active_view_id)
  local tabs = views.tab_views()
  if #tabs == 0 then
    return ""
  end

  local segments = {}
  for tab_idx, view_desc in ipairs(tabs) do
    local is_active = view_desc.id == active_view_id
    local highlight = is_active and "%#SfTitle#" or "%#SfFooter#"
    local segment = string.format(
      "%%%d@v:lua.require'sf.ui.org_dashboard'.handle_tab_click@%s %s %%X",
      tab_idx,
      highlight,
      view_desc.label
    )
    table.insert(segments, segment)
  end

  -- Plain space between segments (not colored, not a glyph) -- the
  -- highlight change between an SfTitle and SfFooter segment is what
  -- reads as a tab boundary; add a left-anchor truncation marker at the end.
  return table.concat(segments, " ") .. "%<"
end

-- Export filter_logs, format_limits, and flatten_package_row for testing
views._filter_logs = filter_logs
views._format_limits = format_limits
views._flatten_package_row = flatten_package_row

return views
