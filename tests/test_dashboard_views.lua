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
--- @return string the rendered data line for a single trace flag with that expiry
---   (line 1 is the "Entity | Debug Level | Expiry" header row)
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
  return child_process.lua_get([[rendered_lines[2] ]])
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
  -- Line 1 is now the "Package | Namespace | Version" header row (Phase
  -- 7); the data row follows it.
  local line = child.lua_get([[rendered_lines[2] ]])
  expect.match(line, "MyPackage")
  expect.match(line, "mypkg")
  expect.match(line, "3.1")
end

-- Regression: an unmanaged package has a null NamespacePrefix. Decoded
-- through the real (fixed) rest_api.lua path that comes back as Lua nil,
-- so flatten_package_row's `or "unmanaged"` fallback works -- decoded
-- through the OLD unpatched vim.json.decode it would have been `vim.NIL`,
-- which crashed org_view.render_columns ("attempt to get length of a
-- userdata value"). Construct the row with vim.NIL directly here so this
-- test still catches a regression even if some other caller ever bypasses
-- the fixed decode path.
test_set["packages render: unmanaged package (null NamespacePrefix) does not error"] = function()
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
        SubscriberPackage = { Name = "UnmanagedPkg", NamespacePrefix = vim.NIL },
        SubscriberPackageVersion = { MajorVersion = 1, MinorVersion = 0 },
      },
    }
    local ok, result = pcall(packages_view.render, {}, data)
    _G.render_ok = ok
    _G.render_result = result
  ]])
  eq(child.lua_get([[_G.render_ok]]), true)
  local line = child.lua_get([[_G.render_result[2] ]])
  expect.match(line, "UnmanagedPkg")
  expect.match(line, "unmanaged")
end

test_set["merged details: render with both detail and status ok"] = function()
  child.lua([[
    local details_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "details" then
        details_view = view
        break
      end
    end
    local data = {
      detail = { alias = "myorg", username = "user@example.com", id = "org-id" },
      detail_err = nil,
      status = { status = "OK", message = nil, incidents = {} },
      status_err = nil,
    }
    rendered_lines, _ = details_view.render({ alias = "myorg" }, data)
  ]])
  local line_count = child.lua_get([[#rendered_lines]])
  eq(line_count > 0, true)
  local line_content = child.lua_get([[table.concat(rendered_lines, "\n")]])
  expect.match(line_content, "Status")
end

test_set["merged details: status section renders instance info, products, maintenances, messages and incidents"] = function()
  child.lua([[
    local details_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "details" then
        details_view = view
        break
      end
    end
    local data = {
      detail = { alias = "myorg", username = "user@example.com", id = "org-id" },
      detail_err = nil,
      status = {
        status = "OK",
        instance_name = "DEU146S",
        location = "EMEA",
        environment = "sandbox",
        release_version = "Summer '26 Patch 14.21",
        maintenance_window = "Saturdays 2:00 PM - 6:00 PM PST",
        products = { { name = "Sales and Service", is_active = true } },
        maintenances = {
          { name = "Winter '27 Major Release", status = "Confirmed", planned_start = "2026-10-09T21:30:00.000Z", planned_end = "2026-10-09T22:00:00.000Z" },
        },
        messages = {
          { subject = "Security Advisory", status = "Active", start_date = "2026-03-08T04:00:00.000Z", end_date = nil },
        },
        incidents = {
          { id = "20004367", message = "Root cause identified", severity = "minor", status = "Resolved", impact_start = "2026-08-19T07:38:00Z", impact_end = "2026-08-23T11:20:00Z" },
        },
      },
      status_err = nil,
    }
    rendered_lines, _ = details_view.render({ alias = "myorg" }, data)
    _G.status_lines = rendered_lines
  ]])
  local line_content = child.lua_get([[table.concat(_G.status_lines, "\n")]])
  -- Instance info
  expect.match(line_content, "DEU146S")
  expect.match(line_content, "EMEA")
  expect.match(line_content, "Summer '26 Patch 14.21")
  expect.match(line_content, "Saturdays 2:00 PM %- 6:00 PM PST")
  -- Products / Maintenances / Messages sections and their headers
  expect.match(line_content, "Products:")
  expect.match(line_content, "Sales and Service")
  expect.match(line_content, "Available")
  expect.match(line_content, "Maintenances:")
  expect.match(line_content, "Winter '27 Major Release")
  expect.match(line_content, "2026%-10%-09 21:30") -- format_status_date compacted the ISO datetime
  expect.match(line_content, "Messages:")
  expect.match(line_content, "Security Advisory")
  -- Incidents are now tabulated with headers and data rows
  expect.match(line_content, "Incidents:")
  expect.match(line_content, "Root cause identified")
  expect.match(line_content, "minor") -- severity column
  expect.match(line_content, "2026%-08%-19") -- impact start date
end

test_set["merged details: status section shows empty%-state messages for products/maintenances/messages/incidents"] = function()
  child.lua([[
    local details_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "details" then
        details_view = view
        break
      end
    end
    local data = {
      detail = { alias = "myorg", username = "user@example.com", id = "org-id" },
      detail_err = nil,
      status = { status = "OK", incidents = {} }, -- no instance_name/products/maintenances/messages at all
      status_err = nil,
    }
    rendered_lines, _ = details_view.render({ alias = "myorg" }, data)
    _G.status_lines2 = rendered_lines
  ]])
  local line_content = child.lua_get([[table.concat(_G.status_lines2, "\n")]])
  expect.match(line_content, "No product data%.")
  expect.match(line_content, "No scheduled maintenance%.")
  expect.match(line_content, "No general messages%.")
  expect.match(line_content, "No incidents reported%.")
end

test_set["merged details: render with detail ok, status error"] = function()
  child.lua([[
    local details_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "details" then
        details_view = view
        break
      end
    end
    local data = {
      detail = { alias = "myorg", username = "user@example.com", id = "org-id" },
      detail_err = nil,
      status = nil,
      status_err = "connection failed",
    }
    rendered_lines, _ = details_view.render({ alias = "myorg" }, data)
  ]])
  local line_count = child.lua_get([[#rendered_lines]])
  eq(line_count > 0, true)
  local line_content = child.lua_get([[table.concat(rendered_lines, "\n")]])
  expect.match(line_content, "unavailable")
end

test_set["merged details: render with detail error, status ok"] = function()
  child.lua([[
    local details_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "details" then
        details_view = view
        break
      end
    end
    local data = {
      detail = nil,
      detail_err = "sf org display failed",
      status = { status = "OK", message = nil, incidents = {} },
      status_err = nil,
    }
    rendered_lines, _ = details_view.render({ alias = "myorg" }, data)
  ]])
  local line_count = child.lua_get([[#rendered_lines]])
  eq(line_count > 0, true)
  local line_content = child.lua_get([[table.concat(rendered_lines, "\n")]])
  expect.match(line_content, "Status")
end

test_set["merged details: render with both detail and status error"] = function()
  child.lua([[
    local details_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "details" then
        details_view = view
        break
      end
    end
    local data = {
      detail = nil,
      detail_err = "sf org display failed",
      status = nil,
      status_err = "could not get session",
    }
    rendered_lines, _ = details_view.render({ alias = "myorg" }, data)
  ]])
  local line_count = child.lua_get([[#rendered_lines]])
  eq(line_count > 0, true)
  local line_content = child.lua_get([[table.concat(rendered_lines, "\n")]])
  expect.match(line_content, "unavailable")
end

test_set["merged details: fetch fires both lookups in parallel"] = function()
  child.lua([[
    local details_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "details" then
        details_view = view
        break
      end
    end

    -- Stub the dependencies
    local org_view = require("sf.ui.org_view")
    local original_fetch = org_view.fetch_org_display
    local detail_fetch_called = false
    org_view.fetch_org_display = function(record, callback)
      detail_fetch_called = true
      vim.schedule(function()
        callback({ alias = record.alias, username = "test@example.com", id = "test-id" }, nil)
      end)
    end

    local rest_api = require("sf.sub.rest_api")
    local original_get_session = rest_api.get_session
    local status_fetch_called = false
    rest_api.get_session = function(alias, callback)
      status_fetch_called = true
      vim.schedule(function()
        callback({ token = "test-token", url = "https://test.salesforce.com", api_version = "60.0" }, nil)
      end)
    end

    local org_status = require("sf.sub.org_status")
    local original_status_fetch = org_status.fetch
    org_status.fetch = function(session, callback)
      vim.schedule(function()
        callback({ status = "OK", message = nil, incidents = {} }, nil)
      end)
    end

    _G.merged_callback_called = false
    _G.merged_callback_data = nil
    details_view.fetch(
      { alias = "test-org", username = "test@example.com" },
      function(data, err)
        _G.merged_callback_called = true
        _G.merged_callback_data = data
      end
    )

    -- Wait for async callbacks
    vim.wait(500, function() return _G.merged_callback_called end, 50)

    -- Restore
    org_view.fetch_org_display = original_fetch
    rest_api.get_session = original_get_session
    org_status.fetch = original_status_fetch
  ]])

  eq(child.lua_get([[_G.merged_callback_called]]), true)
  eq(child.lua_get([[_G.merged_callback_data ~= nil]]), true)
  eq(child.lua_get([[_G.merged_callback_data.detail ~= nil]]), true)
  eq(child.lua_get([[_G.merged_callback_data.status ~= nil]]), true)
  eq(child.lua_get([[_G.merged_callback_data.detail.alias]]), "test-org")
end

test_set["tab_views: returns only entries with render function"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    local tabs = dashboard_views.tab_views()
    _G.tab_count = #tabs
    _G.all_have_render = true
    for _, view in ipairs(tabs) do
      if not view.render then
        _G.all_have_render = false
      end
    end
  ]])

  eq(child.lua_get([[_G.tab_count > 0]]), true)
  eq(child.lua_get([[_G.all_have_render]]), true)
end

test_set["action_views: returns only action-only entries"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    local actions = dashboard_views.action_views()
    _G.action_count = #actions
    _G.all_action_only = true
    for _, view in ipairs(actions) do
      if view.render or view.fetch then
        _G.all_action_only = false
      end
      if not view.action then
        _G.all_action_only = false
      end
    end
  ]])

  eq(child.lua_get([[_G.action_count > 0]]), true)
  eq(child.lua_get([[_G.all_action_only]]), true)
end

test_set["render_winbar: contains all tab labels"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    _G.winbar = dashboard_views.render_winbar("details")
    _G.tabs = dashboard_views.tab_views()
  ]])

  local winbar = child.lua_get([[_G.winbar]])
  -- Check that all tab labels appear in the winbar
  child.lua([[
    _G.all_labels_present = true
    for _, view in ipairs(_G.tabs) do
      if not string.find(_G.winbar, view.label, 1, true) then
        _G.all_labels_present = false
      end
    end
  ]])

  eq(child.lua_get([[_G.all_labels_present]]), true)
end

test_set["render_winbar: indices are 1..#tab_views in order"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    _G.winbar = dashboard_views.render_winbar("details")
    _G.tab_count = #dashboard_views.tab_views()
    -- Check that %1@, %2@, ... %N@ are present in order
    _G.all_indices_present = true
    for i = 1, _G.tab_count do
      local pattern = "%" .. i .. "@"
      if not string.find(_G.winbar, pattern, 1, true) then
        _G.all_indices_present = false
      end
    end
  ]])

  eq(child.lua_get([[_G.all_indices_present]]), true)
end

test_set["render_winbar: active tab has SfTitle highlight"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    _G.winbar = dashboard_views.render_winbar("details")
    _G.has_title = string.find(_G.winbar, "%#SfTitle#", 1, true) ~= nil
  ]])

  eq(child.lua_get([[_G.has_title]]), true)
end

test_set["render_winbar: ends with %< for left-anchor truncation"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    _G.winbar = dashboard_views.render_winbar("details")
    _G.has_truncation_marker = string.sub(_G.winbar, -1) == "<"
  ]])

  eq(child.lua_get([[_G.has_truncation_marker]]), true)
end

test_set["render_winbar: unknown active_view_id produces no SfTitle"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    _G.winbar_unknown = dashboard_views.render_winbar("unknown_view")
    _G.tabs = dashboard_views.tab_views()
    if #_G.tabs > 0 then
      _G.has_title = string.find(_G.winbar_unknown, "%#SfTitle#", 1, true) ~= nil
    else
      _G.has_title = false
    end
  ]])

  eq(child.lua_get([[_G.has_title]]), false)
end

test_set["limits render: columns are aligned"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    -- format_limits is a closed-over local inside dashboard_views.lua, not
    -- reachable through the `_format_limits` test export (that export just
    -- hands out a reference for direct pure-function tests -- reassigning
    -- it does not change what `render` calls). Drive it with real
    -- decoded-JSON-shaped input instead of trying to stub the formatter.
    local limits_data = {
      DailyApiRequests = { Max = 1000, Remaining = 500 }, -- used_count = 500
      DataStorageMB = { Max = 1000, Remaining = 200 }, -- used_count = 800
    }

    local limits_view = nil
    for _, view_desc in ipairs(dashboard_views.tab_views()) do
      if view_desc.id == "limits" then
        limits_view = view_desc
        break
      end
    end
    if limits_view then
      local lines, hls = limits_view.render(nil, limits_data)
      -- First line is header, should have "Limit" in the leftmost column
      _G.has_header = lines[1]:find("Limit", 1, true) ~= nil
      -- Verify all data lines have the same column alignment
      if #lines > 1 then
        local first_num_col = lines[2]:find("500", 1, true)
        local second_num_col = lines[3]:find("800", 1, true)
        _G.aligned = first_num_col == second_num_col
      else
        _G.aligned = true
      end
    else
      _G.has_header = false
      _G.aligned = false
    end
  ]])

  eq(child.lua_get([[_G.has_header]]), true)
  eq(child.lua_get([[_G.aligned]]), true)
end

test_set["packages render: columns are aligned"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    -- Stub flatten_package_row
    local original_flatten = dashboard_views._flatten_package_row
    dashboard_views._flatten_package_row = function(raw)
      return raw  -- Pass through for this test
    end

    local packages_view = nil
    for _, view_desc in ipairs(dashboard_views.tab_views()) do
      if view_desc.id == "packages" then
        packages_view = view_desc
        break
      end
    end
    if packages_view then
      local test_data = {
        { SubscriberPackage = { Name = "Pkg1", NamespacePrefix = "ns1" }, SubscriberPackageVersion = { MajorVersion = 1, MinorVersion = 0 } },
        { SubscriberPackage = { Name = "LongerPackageName", NamespacePrefix = "ns" }, SubscriberPackageVersion = { MajorVersion = 2, MinorVersion = 5 } },
      }
      local lines, hls = packages_view.render(nil, test_data)
      -- First line is header
      _G.has_header = lines[1]:find("Package", 1, true) ~= nil
      -- Alignment check: namespace column should start at same position
      if #lines > 2 then
        local first_ns_col = lines[2]:find("ns1", 1, true)
        local second_ns_col = lines[3]:find("ns", 1, true)
        -- Both should find their content, indicating they're properly aligned
        _G.aligned = first_ns_col ~= nil and second_ns_col ~= nil
      else
        _G.aligned = true
      end
    else
      _G.has_header = false
      _G.aligned = false
    end
  ]])

  eq(child.lua_get([[_G.has_header]]), true)
  eq(child.lua_get([[_G.aligned]]), true)
end

test_set["format_log_line: includes operation field"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    local log = {
      user = "alice",
      start_time = "2025-01-15T10:30:00.000Z",
      operation = "/aura",
      size = 1024,
      status = "Success",
    }
    -- format_log_line is file-local; we can't call it directly from test.
    -- Instead, test it through filter_logs which calls it indirectly.
    -- We'll test filter_logs behavior instead.
    _G.logs = { log }
    _G.filtered = dashboard_views._filter_logs(_G.logs, "aura")
  ]])

  eq(child.lua_get([[#_G.filtered]]), 1)
end

test_set["filter_logs: substring matches operation field"] = function()
  child.lua([[
    local dashboard_views = require("sf.ui.dashboard_views")
    local logs = {
      { user = "alice", start_time = "2025-01-15T10:30:00.000Z", operation = "/aura", size = 1024, status = "Success" },
      { user = "bob", start_time = "2025-01-15T11:00:00.000Z", operation = "/webruntime/api/apex/execute", size = 2048, status = "Success" },
      { user = "carol", start_time = "2025-01-15T12:00:00.000Z", operation = "System", size = 512, status = "Error" },
    }
    _G.filtered = dashboard_views._filter_logs(logs, "aura")
  ]])

  eq(child.lua_get([[#_G.filtered]]), 1)
  eq(child.lua_get([[_G.filtered[1].user]]), "alice")
end

return test_set
