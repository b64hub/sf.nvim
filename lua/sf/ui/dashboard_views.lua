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
local function format_log_line(log)
  return string.format(
    "%s | %s | %s | %s",
    log.user,
    string.gsub(log.start_time, "T", " "),
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

--- Flatten a raw Tooling API InstalledSubscriberPackage record into a simple table.
--- Handles missing nested fields gracefully, falling back to sensible defaults.
---@param raw_record table raw record from Tooling API with nested SubscriberPackage and SubscriberPackageVersion fields
---@return table { name, namespace, version } a flat record safe to render
local function flatten_package_row(raw_record)
  local subscriber_package = raw_record.SubscriberPackage or {}
  local package_version = raw_record.SubscriberPackageVersion or {}

  local name = subscriber_package.Name or "unknown"
  local namespace = subscriber_package.NamespacePrefix or "unmanaged"
  local major = package_version.MajorVersion
  local minor = package_version.MinorVersion

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
      org_view.fetch_org_display(record, callback)
    end,
    render = function(record, data)
      return org_view.render_detail_lines(record, nil, data, nil)
    end,
    action = nil, -- details view is fetch+render only
  },
  {
    id = "status",
    key = "s",
    label = "Org Status",
    fetch = function(record, callback)
      rest_api.get_session(record.alias, function(session, err)
        if not session then
          return callback(nil, err)
        end
        org_status.fetch(session, callback)
      end)
    end,
    render = function(_, data)
      local lines, line_hls = {}, {}

      local status_line = "Status: " .. data.status
      table.insert(lines, status_line)
      table.insert(line_hls, { { group = status_highlight(data.status), col_start = 0, col_end = #status_line } })

      if data.message then
        table.insert(lines, data.message)
        table.insert(line_hls, {})
      end

      table.insert(lines, "")
      table.insert(line_hls, {})

      if #data.incidents == 0 then
        table.insert(lines, "No incidents reported.")
        table.insert(line_hls, {})
      else
        table.insert(lines, "Incidents:")
        table.insert(line_hls, {})
        for _, incident in ipairs(data.incidents) do
          local incident_line = "  - " .. (incident.message or incident.id or "(no details)")
          table.insert(lines, incident_line)
          table.insert(line_hls, { { group = "SfWarn", col_start = 0, col_end = #incident_line } })
        end
      end

      return lines, line_hls
    end,
    action = nil,
  },
  {
    id = "set_local_default",
    key = "L",
    label = "Set Local Default",
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
        local soql = "SELECT Id, DebugLevel.DeveloperName, ExpirationDate, TracedEntity.Name FROM TraceFlag ORDER BY ExpirationDate DESC"
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

      for _, flag in ipairs(data) do
        local traced_entity = flag.TracedEntity and flag.TracedEntity.Name or "(unknown)"
        local debug_level = flag.DebugLevel and flag.DebugLevel.DeveloperName or "(unknown)"
        local expiry = format_trace_flag_expiry(flag.ExpirationDate)
        local line = string.format("%s | %s | %s", traced_entity, debug_level, expiry)
        table.insert(lines, line)
        table.insert(line_hls, {})
      end

      return lines, line_hls
    end,
    action = nil,
  },
  {
    id = "enable_logging",
    key = "e",
    label = "Enable Logging",
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

      for _, log in ipairs(data) do
        table.insert(lines, format_log_line(log))
        table.insert(line_hls, {})
      end

      return lines, line_hls
    end,
    action = nil,
  },
  {
    id = "limits",
    key = "u",
    label = "Org Limits",
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
      local rows = format_limits(data)

      if #rows == 0 then
        table.insert(lines, "No limits data found.")
        table.insert(line_hls, {})
        return lines, line_hls
      end

      for _, row in ipairs(rows) do
        local line = string.format("%s: %d/%d (%.0f%%)", row.name, row.remaining, row.max_val, row.used_percent)
        table.insert(lines, line)
        local hls = {}
        if row.used_percent >= 80 then
          table.insert(hls, { group = "SfWarn", col_start = 0, col_end = #line })
        end
        table.insert(line_hls, hls)
      end

      return lines, line_hls
    end,
    action = nil,
  },
  {
    id = "packages",
    key = "p",
    label = "Installed Packages",
    fetch = function(record, callback)
      rest_api.get_session(record.alias, function(session, err)
        if not session then
          return callback(nil, err)
        end
        local soql = "SELECT SubscriberPackage.Name, SubscriberPackage.NamespacePrefix, SubscriberPackageVersion.MajorVersion, SubscriberPackageVersion.MinorVersion FROM InstalledSubscriberPackage"
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

      for _, raw_record in ipairs(data) do
        local flattened = flatten_package_row(raw_record)
        local line = string.format("%s (%s) v%s", flattened.name, flattened.namespace, flattened.version)
        table.insert(lines, line)
        table.insert(line_hls, {})
      end

      return lines, line_hls
    end,
    action = nil,
  },
}

-- Export filter_logs, format_limits, and flatten_package_row for testing
views._filter_logs = filter_logs
views._format_limits = format_limits
views._flatten_package_row = flatten_package_row

return views
