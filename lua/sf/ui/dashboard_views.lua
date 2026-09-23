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
}

-- Export filter_logs for testing
views._filter_logs = filter_logs

return views
