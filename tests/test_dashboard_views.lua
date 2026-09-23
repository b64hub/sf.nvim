local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Exercises the trace-flags view's private `format_trace_flag_expiry`
-- formatter indirectly through its public `render(record, data)` function
-- (the formatter itself is a local, not exported) -- these tests fix the
-- expiration timestamp relative to the real clock at run time, so no
-- injectable "now" is needed the way org_view.days_until has one.
local test_set = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[dashboard_views = require("sf.ui.dashboard_views")]])
    end,
    post_once = child.stop,
  },
})

--- @param child_process table the mini.test child process handle
--- @param expiration_date string ISO8601 UTC datetime
--- @return string the first rendered line for a single trace flag with that expiry
local function render_first_line(child_process, expiration_date)
  child_process.lua(
    string.format(
      [[
        local trace_flags_view
        for _, view in ipairs(dashboard_views) do
          if view.id == "trace_flags" then
            trace_flags_view = view
            break
          end
        end
        local data = {
          {
            Id = "test-id",
            DebugLevel = { DeveloperName = "SFNVIM_REPLAY" },
            ExpirationDate = %q,
            TracedEntity = { Name = "testuser@example.com" },
          },
        }
        rendered_lines = trace_flags_view.render({}, data)
      ]],
      expiration_date
    )
  )
  return child_process.lua_get([[rendered_lines[1] ]])
end

test_set["trace_flags render: far in the future shows hours remaining"] = function()
  local expiration_date = os.date("!%Y-%m-%dT%H:%M:%S.000Z", os.time() + 24 * 60 * 60)
  local line = render_first_line(child, expiration_date)
  expect.match(line, "expires in")
  expect.match(line, "h")
end

test_set["trace_flags render: about to expire shows minutes remaining"] = function()
  local expiration_date = os.date("!%Y-%m-%dT%H:%M:%S.000Z", os.time() + 5 * 60)
  local line = render_first_line(child, expiration_date)
  expect.match(line, "expires in")
  expect.match(line, "min")
end

test_set["trace_flags render: already expired"] = function()
  local expiration_date = os.date("!%Y-%m-%dT%H:%M:%S.000Z", os.time() - 60)
  local line = render_first_line(child, expiration_date)
  expect.match(line, "expired")
end

test_set["trace_flags render: no trace flags"] = function()
  child.lua([[
    local trace_flags_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "trace_flags" then
        trace_flags_view = view
        break
      end
    end
    rendered_lines = trace_flags_view.render({}, {})
  ]])
  local line = child.lua_get([[rendered_lines[1] ]])
  expect.match(line, "No active")
end

test_set["filter_logs: empty query returns all logs"] = function()
  child.lua([[
    local logs = {
      { id = "1", user = "alice", start_time = "2024-01-01T10:00:00.000+0000", size = 1024, status = "Success" },
      { id = "2", user = "bob", start_time = "2024-01-02T11:00:00.000+0000", size = 2048, status = "Success" },
    }
    filtered = dashboard_views._filter_logs(logs, nil)
  ]])
  eq(child.lua_get([[#filtered]]), 2)
end

test_set["filter_logs: case-insensitive substring match on user"] = function()
  child.lua([[
    local logs = {
      { id = "1", user = "Alice", start_time = "2024-01-01T10:00:00.000+0000", size = 1024, status = "Success" },
      { id = "2", user = "Bob", start_time = "2024-01-02T11:00:00.000+0000", size = 2048, status = "Success" },
    }
    filtered = dashboard_views._filter_logs(logs, "alice")
  ]])
  eq(child.lua_get([[#filtered]]), 1)
  eq(child.lua_get([[filtered[1].id]]), "1")
end

test_set["filter_logs: substring match on status"] = function()
  child.lua([[
    local logs = {
      { id = "1", user = "Alice", start_time = "2024-01-01T10:00:00.000+0000", size = 1024, status = "Success" },
      { id = "2", user = "Bob", start_time = "2024-01-02T11:00:00.000+0000", size = 2048, status = "Error" },
      { id = "3", user = "Charlie", start_time = "2024-01-03T12:00:00.000+0000", size = 512, status = "Success" },
    }
    filtered = dashboard_views._filter_logs(logs, "Success")
  ]])
  eq(child.lua_get([[#filtered]]), 2)
end

test_set["filter_logs: no matches returns empty array"] = function()
  child.lua([[
    local logs = {
      { id = "1", user = "Alice", start_time = "2024-01-01T10:00:00.000+0000", size = 1024, status = "Success" },
      { id = "2", user = "Bob", start_time = "2024-01-02T11:00:00.000+0000", size = 2048, status = "Success" },
    }
    filtered = dashboard_views._filter_logs(logs, "xyz")
  ]])
  eq(child.lua_get([[#filtered]]), 0)
end

test_set["format_limits: computes used percentage correctly"] = function()
  child.lua([[
    local limits_data = {
      DailyApiRequests = { Max = 15000, Remaining = 14000 },
    }
    rows = dashboard_views._format_limits(limits_data)
  ]])
  eq(child.lua_get([[#rows]]), 1)
  eq(child.lua_get([[rows[1].name]]), "DailyApiRequests")
  eq(child.lua_get([[rows[1].max_val]]), 15000)
  eq(child.lua_get([[rows[1].remaining]]), 14000)
  eq(child.lua_get([[rows[1].used_count]]), 1000)
  eq(child.lua_get([[math.floor(rows[1].used_percent)]]), 6) -- (1000 / 15000 * 100) ≈ 6.67 -> 6
end

test_set["format_limits: guards against division by zero for Max=0"] = function()
  child.lua([[
    local limits_data = {
      SomeLimit = { Max = 0, Remaining = 0 },
    }
    rows = dashboard_views._format_limits(limits_data)
  ]])
  eq(child.lua_get([[#rows]]), 1)
  eq(child.lua_get([[rows[1].used_percent]]), 0) -- Should be 0, not NaN or error
end

test_set["format_limits: prioritizes interesting limits first"] = function()
  child.lua([[
    local limits_data = {
      ZebraLimit = { Max = 100, Remaining = 50 },
      DailyApiRequests = { Max = 15000, Remaining = 14000 },
      FileStorageMB = { Max = 1000, Remaining = 800 },
      AppleLimit = { Max = 200, Remaining = 100 },
      DataStorageMB = { Max = 5000, Remaining = 4000 },
    }
    rows = dashboard_views._format_limits(limits_data)
  ]])
  eq(child.lua_get([[#rows]]), 5)
  eq(child.lua_get([[rows[1].name]]), "DailyApiRequests")
  eq(child.lua_get([[rows[2].name]]), "DataStorageMB")
  eq(child.lua_get([[rows[3].name]]), "FileStorageMB")
  eq(child.lua_get([[rows[4].name]]), "AppleLimit")
  eq(child.lua_get([[rows[5].name]]), "ZebraLimit")
end

test_set["format_limits: ignores non-table values"] = function()
  child.lua([[
    local limits_data = {
      DailyApiRequests = { Max = 15000, Remaining = 14000 },
      InvalidEntry = "not a table",
      AnotherLimit = { Max = 500, Remaining = 250 },
    }
    rows = dashboard_views._format_limits(limits_data)
  ]])
  eq(child.lua_get([[#rows]]), 2)
  eq(child.lua_get([[rows[1].name]]), "DailyApiRequests")
  eq(child.lua_get([[rows[2].name]]), "AnotherLimit")
end

test_set["flatten_package_row: fully populated record"] = function()
  child.lua([[
    local record = {
      SubscriberPackage = { Name = "TestPackage", NamespacePrefix = "testns" },
      SubscriberPackageVersion = { MajorVersion = 2, MinorVersion = 5 },
    }
    flattened = dashboard_views._flatten_package_row(record)
  ]])
  eq(child.lua_get([[flattened.name]]), "TestPackage")
  eq(child.lua_get([[flattened.namespace]]), "testns")
  eq(child.lua_get([[flattened.version]]), "2.5")
end

test_set["flatten_package_row: nil namespace prefix falls back to unmanaged"] = function()
  child.lua([[
    local record = {
      SubscriberPackage = { Name = "TestPackage", NamespacePrefix = nil },
      SubscriberPackageVersion = { MajorVersion = 1, MinorVersion = 0 },
    }
    flattened = dashboard_views._flatten_package_row(record)
  ]])
  eq(child.lua_get([[flattened.namespace]]), "unmanaged")
end

test_set["flatten_package_row: missing version fields falls back to unknown"] = function()
  child.lua([[
    local record = {
      SubscriberPackage = { Name = "TestPackage", NamespacePrefix = "testns" },
      SubscriberPackageVersion = { MajorVersion = nil, MinorVersion = nil },
    }
    flattened = dashboard_views._flatten_package_row(record)
  ]])
  eq(child.lua_get([[flattened.version]]), "unknown")
end

test_set["flatten_package_row: missing SubscriberPackage falls back gracefully"] = function()
  child.lua([[
    local record = {
      SubscriberPackage = nil,
      SubscriberPackageVersion = { MajorVersion = 1, MinorVersion = 2 },
    }
    flattened = dashboard_views._flatten_package_row(record)
  ]])
  eq(child.lua_get([[flattened.name]]), "unknown")
  eq(child.lua_get([[flattened.namespace]]), "unmanaged")
  eq(child.lua_get([[flattened.version]]), "1.2")
end

test_set["packages render: no packages installed"] = function()
  child.lua([[
    local packages_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "packages" then
        packages_view = view
        break
      end
    end
    rendered_lines = packages_view.render({}, {})
  ]])
  local line = child.lua_get([[rendered_lines[1] ]])
  expect.match(line, "No packages installed")
end

test_set["packages render: formats package with namespace and version"] = function()
  child.lua([[
    local packages_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "packages" then
        packages_view = view
        break
      end
    end
    local data = {
      {
        SubscriberPackage = { Name = "MyPackage", NamespacePrefix = "mypkg" },
        SubscriberPackageVersion = { MajorVersion = 3, MinorVersion = 1 },
      },
    }
    rendered_lines = packages_view.render({}, data)
  ]])
  local line = child.lua_get([[rendered_lines[1] ]])
  expect.match(line, "MyPackage")
  expect.match(line, "mypkg")
  expect.match(line, "3.1")
end

return test_set
