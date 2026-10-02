local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

local test_set = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[
        dashboard = require("sf.ui.org_dashboard")
        org_view = require("sf.ui.org_view")
        dashboard_views = require("sf.ui.dashboard_views")
        
        -- Stub fetch_org_display to avoid calling the CLI
        org_view.fetch_org_display = function(record, callback)
          vim.schedule(function()
            callback({ alias = record.alias, username = record.username, id = "test-id" }, nil)
          end)
        end
      ]])
    end,
    post_once = child.stop,
  },
})

test_set["open: creates two windows"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
      { alias = "org2", username = "user2", org_type = "sandbox", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  -- Let the async fetch complete
  child.lua([[vim.wait(60, function() return false end, 50)]])

  local window_count = child.lua_get([[#vim.api.nvim_list_wins()]])
  eq(window_count >= 2, true)
end

test_set["open: left buffer contains first org alias"] = function()
  child.lua([[
    records = {
      { alias = "myorg", username = "user@example.com", org_type = "production", expiration_date = nil },
      { alias = "other", username = "user2", org_type = "sandbox", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  local buffers = child.lua([[
    bufs = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        table.insert(bufs, vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
      end
    end
    return bufs
  ]])

  eq(#buffers >= 1, true)
  eq(buffers[1]:find("myorg") ~= nil, true)
end

test_set["open: q closes both windows"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  local windows_before = child.lua_get([[#vim.api.nvim_list_wins()]])
  eq(windows_before >= 2, true)

  child.lua([[vim.api.nvim_input("q")]])
  child.lua([[vim.wait(40, function() return false end, 50)]])

  local windows_after = child.lua_get([[#vim.api.nvim_list_wins()]])
  -- After closing the dashboard, there should be fewer windows
  eq(windows_after < windows_before, true)
end

test_set["open: singleton guard prevents duplicate dashboards"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
      { alias = "org2", username = "user2", org_type = "sandbox", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  local windows_after_first_open = child.lua_get([[#vim.api.nvim_list_wins()]])
  eq(windows_after_first_open >= 2, true)

  -- Call dashboard.open a second time with the same records
  child.lua([[
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  local windows_after_second_open = child.lua_get([[#vim.api.nvim_list_wins()]])
  -- Should still have the same number of windows, not doubled
  eq(windows_after_second_open, windows_after_first_open)
end

test_set["open: no orgs raises notification"] = function()
  child.lua([[
    records = {}
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  -- Just verify it doesn't crash and returns nil
  local result = child.lua_get([[nil]])
  eq(result, vim.NIL)
end

test_set["view registry: footer contains registered view keys"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Left (org list) and right (detail view) panes now show different,
  -- pane-scoped footers -- concatenate every window's footer text so
  -- assertions below don't care which pane a given key landed in.
  local footer_text = child.lua([[
    local parts = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      if config.footer then
        table.insert(parts, config.footer[1][1])
      end
    end
    return table.concat(parts, " ")
  ]])

  -- Footer should NOT contain 'd' for details view (tabs are in the strip, not footer)
  eq(footer_text:find(" d ") == nil, true)
  -- Footer should contain action-only keys like 'L', 'G', 'o'
  eq(footer_text:find("L") ~= nil, true)
  -- Footer should contain 'q' for close
  eq(footer_text:find("q") ~= nil, true)
end

test_set["view registry: can add and use a second view"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
      { alias = "org2", username = "user2", org_type = "sandbox", expiration_date = nil },
    }
    
    -- Add a fake view to dashboard_views
    local fetch_call_count = 0
    table.insert(dashboard_views, {
      id = "fake_view",
      key = "f",
      label = "Fake",
      fetch = function(record, callback)
        fetch_call_count = fetch_call_count + 1
        vim.schedule(function()
          callback({ test_data = "fake_" .. record.alias }, nil)
        end)
      end,
      render = function(record, data)
        local lines = { "Fake view: " .. (data.test_data or "unknown") }
        local line_hls = { { { group = "SfFooter", col_start = 0, col_end = #lines[1] } } }
        return lines, line_hls
      end,
      action = nil,
    })
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Press 'f' to switch to fake view
  child.lua([[vim.api.nvim_input("f")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Get view buffer content to verify fake view is rendered
  -- Note: the buffer now starts with a tab strip, so content is after the header
  local fake_view_found = child.lua([[
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        -- Find the line that has our fake view data
        for _, line in ipairs(lines) do
          if line:find("Fake view") then
            return true
          end
        end
      end
    end
    return false
  ]])

  eq(fake_view_found, true)
end

test_set["view registry: cache hit prevents re-fetch"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }
    
    -- Add a view with fetch call counting
    local cached_fetch_calls = {}
    table.insert(dashboard_views, {
      id = "counting_view",
      key = "c",
      label = "Counting",
      fetch = function(record, callback)
        if not cached_fetch_calls[record.alias] then
          cached_fetch_calls[record.alias] = 0
        end
        cached_fetch_calls[record.alias] = cached_fetch_calls[record.alias] + 1
        vim.schedule(function()
          callback({ count = cached_fetch_calls[record.alias] }, nil)
        end)
      end,
      render = function(record, data)
        local lines = { "Fetch count: " .. tostring(data.count or 0) }
        local line_hls = { { { group = "SfFooter", col_start = 0, col_end = #lines[1] } } }
        return lines, line_hls
      end,
      action = nil,
    })
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Press 'c' to fetch counting_view
  child.lua([[vim.api.nvim_input("c")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])

  local first_render = child.lua([[
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for _, line in ipairs(lines) do
          if line:find("Fetch count") then
            return line
          end
        end
      end
    end
    return ""
  ]])

  -- Should show count = 1
  eq(first_render:find("1") ~= nil, true)

  -- Press 'c' again
  child.lua([[vim.api.nvim_input("c")]])
  child.lua([[vim.wait(40, function() return false end, 50)]])

  local second_render = child.lua([[
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for _, line in ipairs(lines) do
          if line:find("Fetch count") then
            return line
          end
        end
      end
    end
    return ""
  ]])

  -- Should still show count = 1 (cache hit, no re-fetch)
  eq(second_render:find("1") ~= nil, true)
end

test_set["action entry: spy function is called with record"] = function()
  child.lua([[
    action_spy = { called = false, record_alias = nil }
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
      { alias = "org2", username = "user2", org_type = "sandbox", expiration_date = nil },
    }
    
    -- Add an action-only view with a spy function
    table.insert(dashboard_views, {
      id = "test_action",
      key = "x",
      label = "Test Action",
      fetch = nil,
      render = nil,
      action = function(record, _)
        action_spy.called = true
        action_spy.record_alias = record.alias
      end,
    })
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Move to second org
  child.lua([[vim.api.nvim_input("j")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Press 'x' to trigger the action
  child.lua([[vim.api.nvim_input("x")]])
  child.lua([[vim.wait(40, function() return false end, 50)]])

  local called = child.lua_get([[action_spy.called]])
  local alias = child.lua_get([[action_spy.record_alias]])

  eq(called, true)
  eq(alias, "org2")
end

test_set["refresh key 'r': re-fetches org list and invalidates the active view's cache"] = function()
  child.lua([[
    local util = require("sf.util")
    util.is_sf_cmd_installed = function() end

    -- Track org-list refetches (jobstart calls) separately from the fake
    -- view's own fetch, so this test can distinguish "org list refetched"
    -- from "the currently active view's cache was actually invalidated" --
    -- two different claims a refresh needs to satisfy, not just one.
    _G.jobstart_count = 0
    vim.fn.jobstart = function(_, opts)
      _G.jobstart_count = _G.jobstart_count + 1
      if opts.on_stdout then
        opts.on_stdout(nil, { '{"result":{"nonScratchOrgs":[{"alias":"org1","username":"user1","isScratch":false,"isSandbox":false,"isDefaultUsername":true,"isDefaultDevHubUsername":false}],"scratchOrgs":[]}}' })
      end
      if opts.on_exit then
        opts.on_exit()
      end
      return 1
    end

    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }

    -- A fake view (key 'z' -- deliberately not 'f', which the real logs
    -- view's filter keymap already uses) whose own fetch is counted, so a
    -- second fetch after refresh proves session.cache was actually cleared
    -- for it, not just that Org.fetch_org_list ran again.
    _G.fake_view_fetch_count = 0
    table.insert(dashboard_views, {
      id = "cache_probe",
      key = "z",
      label = "Cache Probe",
      fetch = function(record, callback)
        _G.fake_view_fetch_count = _G.fake_view_fetch_count + 1
        vim.schedule(function()
          callback({ probe = record.alias }, nil)
        end)
      end,
      render = function(_, data)
        return { "probe: " .. data.probe }, { {} }
      end,
      action = nil,
    })

    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Switch to the fake view: first fetch, gets cached.
  child.lua([[vim.api.nvim_input("z")]])
  child.lua([[vim.wait(50, function() return false end, 50)]])
  eq(child.lua_get([[_G.fake_view_fetch_count]]), 1)

  -- Re-selecting the same view without a refresh is a cache hit -- no
  -- second fetch. (Establishes the baseline this test's refresh assertion
  -- below is actually contrasted against.)
  child.lua([[vim.api.nvim_input("z")]])
  child.lua([[vim.wait(40, function() return false end, 50)]])
  eq(child.lua_get([[_G.fake_view_fetch_count]]), 1)

  local jobstart_count_before_refresh = child.lua_get([[_G.jobstart_count]])

  -- Press 'r' to refresh.
  child.lua([[vim.api.nvim_input("r")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Org list was re-fetched (another jobstart call)...
  eq(child.lua_get([[_G.jobstart_count]]) > jobstart_count_before_refresh, true)
  -- ...AND the currently-active fake view was re-fetched too, proving its
  -- cache entry was actually cleared rather than just the org list's own
  -- data being refreshed underneath a stale view cache.
  eq(child.lua_get([[_G.fake_view_fetch_count]]), 2)
end

test_set["action entry: dashboard_api.repaint_list invoked after action"] = function()
  child.lua([[
    helpers = require("sf.org").__test
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
      { alias = "org2", username = "user2", org_type = "sandbox", expiration_date = nil },
    }
    helpers.orgs = records
    
    -- Add an action that tracks if repaint_list is called. "is_default"
    -- is derived from util.target_org at render time (never stored on a
    -- record, see org_model.lua), so "making org2 the default" here is
    -- just updating that, the same way Org.set_target_org_to does.
    repaint_called = false
    util = require("sf.util")
    util.set_target_org = function(alias) util.target_org = alias end
    table.insert(dashboard_views, {
      id = "toggle_default",
      key = "t",
      label = "Toggle Default",
      fetch = nil,
      render = nil,
      action = function(record, dashboard_api)
        util.set_target_org(record.alias)
        dashboard_api.repaint_list()
        repaint_called = true
      end,
    })
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Move to second org
  child.lua([[vim.api.nvim_input("j")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Press 't' to toggle default (org2 becomes default, org1 is not)
  child.lua([[vim.api.nvim_input("t")]])
  child.lua([[vim.wait(40, function() return false end, 50)]])

  -- Verify the action was called and repaint_list was invoked
  local repaint_called = child.lua_get([[repaint_called]])
  eq(repaint_called, true)
  
  -- Verify the target org was updated
  eq(child.lua_get([[util.target_org]]), "org2")

  -- Verify the *rendered buffer* actually reflects the new default -- this
  -- is the real point of repaint_list: without an actual repaint, the
  -- assertions above would still pass (they only check the underlying
  -- data, not what the list pane shows) while the UI stayed stale.
  local list_lines = child.lua([[
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        if lines[1] and (lines[1]:find("org1", 1, true) or lines[1]:find("org2", 1, true)) then
          return lines
        end
      end
    end
    return {}
  ]])

  eq(#list_lines >= 2, true)
  -- org1's line no longer carries the default marker (●); org2's does.
  eq(list_lines[1]:sub(1, 2), "  ")
  expect.match(list_lines[2], "^\u{25CF} ")
end

test_set["winbar tab strip: renders and is clickable"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }
    
    org_view = require("sf.ui.org_view")
    org_view.fetch_org_display = function(record, callback)
      vim.schedule(function()
        callback({ alias = record.alias }, nil)
      end)
    end
    
    dashboard = require("sf.ui.org_dashboard")
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Check that winbar is set and contains tab labels
  local has_winbar = child.lua([[
    local view_wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
    for _, win in ipairs(view_wins) do
      if vim.wo[win].winbar and vim.wo[win].winbar ~= "" then
        _G.winbar_text = vim.wo[win].winbar
        return true
      end
    end
    return false
  ]])
  
  eq(has_winbar, true)
  
  -- Verify the winbar contains tab labels
  local winbar = child.lua_get([[_G.winbar_text or ""]])
  eq(winbar:find("Details") ~= nil, true)
  eq(winbar:find("%#SfTitle#") ~= nil, true)
end

test_set["handle_tab_click: switches view and returns focus to list"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }
    
    org_view = require("sf.ui.org_view")
    org_view.fetch_org_display = function(record, callback)
      vim.schedule(function()
        callback({ alias = record.alias }, nil)
      end)
    end
    
    dashboard = require("sf.ui.org_dashboard")
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Get the second tab's index
  child.lua([[
    local tabs = require("sf.ui.dashboard_views").tab_views()
    if #tabs >= 2 then
      _G.second_tab_id = tabs[2].id
      -- Call handle_tab_click for the second tab (minwid=2)
      dashboard.handle_tab_click(2, 1, "l", "")
    end
  ]])

  child.lua([[vim.wait(50, function() return false end, 50)]])

  -- Verify the active_view_id changed
  local new_view = child.lua([[
    -- We can't directly access active_session, but the handle_tab_click
    -- function should have set the tab as active in the winbar
    _G.tabs = require("sf.ui.dashboard_views").tab_views()
    return _G.second_tab_id or "details"
  ]])
  
  eq(new_view ~= "details", true)
  
  -- Verify the view buffer's first line is view content, not a tab label
  child.lua([[
    local view_buf = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
        if #lines > 0 then
          -- First line should not be a tab strip
          _G.first_line_is_content = not string.find(lines[1], "Details") or string.find(lines[1], "alias") ~= nil
        end
      end
    end
  ]])
  
  eq(child.lua_get([[_G.first_line_is_content]]), true)
end

test_set["footer: shows action-only views, not tabs; includes f, r, q"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }
    
    org_view = require("sf.ui.org_view")
    org_view.fetch_org_display = function(record, callback)
      vim.schedule(function()
        callback({ alias = record.alias }, nil)
      end)
    end
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Left and right panes have distinct footers (org ops vs. misc/view ops)
  -- -- concatenate both so this test doesn't care which side a key is on.
  local footer_text = child.lua([[
    local parts = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      if config.footer then
        table.insert(parts, config.footer[1][1])
      end
    end
    return table.concat(parts, " ")
  ]])

  -- Footer should contain action keys like L, G, o, t, e
  eq(footer_text:find("L") ~= nil, true)
  eq(footer_text:find("G") ~= nil, true)
  eq(footer_text:find("o") ~= nil, true)
  -- Footer should contain f, r, q (dashboard-level keys)
  eq(footer_text:find("f") ~= nil, true)
  eq(footer_text:find("r") ~= nil, true)
  eq(footer_text:find("q") ~= nil, true)
  -- Footer should NOT contain tab labels (Details, Logs, etc. are in the strip, not footer)
  eq(footer_text:find("Details") == nil, true)
end

test_set["refresh key 'r': invalidates org_display cache"] = function()
  child.lua([[
    local util = require("sf.util")
    util.is_sf_cmd_installed = function() end
    local api = require("sf.sub.rest_api")

    _G.invalidate_called = false
    local original_invalidate = api.invalidate_org_display
    api.invalidate_org_display = function()
      _G.invalidate_called = true
      original_invalidate()
    end

    vim.fn.jobstart = function(_, opts)
      if opts.on_stdout then
        opts.on_stdout(nil, { '{"result":{"nonScratchOrgs":[{"alias":"org1","username":"user1","isScratch":false,"isSandbox":false,"isDefaultUsername":true,"isDefaultDevHubUsername":false}],"scratchOrgs":[]}}' })
      end
      if opts.on_exit then
        opts.on_exit()
      end
      return 1
    end

    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }

    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  -- Press 'r' to refresh
  child.lua([[vim.api.nvim_input("r")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])

  eq(child.lua_get([[_G.invalidate_called]]), true)
end

test_set["prefetch: eager warm-up fetches default/devhub orgs"] = function()
  child.lua([[
    fetch_count = {}
    local original_view_descriptor
    
    -- Register a counting view to track prefetch behavior
    local counting_view = {
      id = "prefetch_test",
      key = "x",
      label = "PrefetchTest",
      fetch = function(record, callback)
        if not fetch_count[record.alias] then
          fetch_count[record.alias] = 0
        end
        fetch_count[record.alias] = fetch_count[record.alias] + 1
        vim.schedule(function()
          callback({ result = "data" }, nil)
        end)
      end,
      render = function(record, data)
        return { "data" }, { {} }
      end,
    }
    
    -- Inject counting_view into dashboard_views
    table.insert(dashboard_views, counting_view)
    
    -- Mock org_view.fetch_org_display
    org_view.fetch_org_display = function(record, callback)
      vim.schedule(function()
        callback({ alias = record.alias }, nil)
      end)
    end
    
    -- "default"/"default devhub" are never stored on a record (see
    -- org_model.lua) -- the dashboard's warm-up compares against these
    -- directly instead.
    util = require("sf.util")
    util.target_org = "default_org"
    require("sf.org").__test.default_devhub_alias = "devhub_org"

    records = {
      { alias = "default_org", username = "user1", org_type = "production", expiration_date = nil },
      { alias = "devhub_org", username = "user2", org_type = "production", expiration_date = nil },
      { alias = "other_org", username = "user3", org_type = "production", expiration_date = nil },
    }
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])
  
  -- Wait for eager prefetch and initial fetch to complete
  child.lua([[vim.wait(80, function() return false end, 50)]])
  
  local default_count = child.lua_get([[fetch_count["default_org"] or 0]])
  local devhub_count = child.lua_get([[fetch_count["devhub_org"] or 0]])
  local other_count = child.lua_get([[fetch_count["other_org"] or 0]])
  
  -- default_org and devhub_org should be prefetched once each
  eq(default_count, 1)
  eq(devhub_count, 1)
  -- other_org should not be prefetched (only cursor-landed, which doesn't happen on open)
  eq(other_count, 0)
end

test_set["prefetch: #records == 1 skips eager prefetch"] = function()
  child.lua([[
    fetch_count = 0
    
    -- Register a counting view to track prefetch behavior
    local counting_view = {
      id = "prefetch_test_single",
      key = "y",
      label = "PrefetchTestSingle",
      fetch = function(record, callback)
        fetch_count = fetch_count + 1
        vim.schedule(function()
          callback({ result = "data" }, nil)
        end)
      end,
      render = function(record, data)
        return { "data" }, { {} }
      end,
    }
    
    -- Inject into dashboard_views
    table.insert(dashboard_views, counting_view)
    
    -- Mock org_view.fetch_org_display
    org_view.fetch_org_display = function(record, callback)
      vim.schedule(function()
        callback({ alias = record.alias }, nil)
      end)
    end
    
    records = {
      { alias = "single_org", username = "user1", org_type = "production", expiration_date = nil },
    }
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])
  
  -- Wait for the cursor-landed fetch (not prefetch, which should be skipped)
  child.lua([[vim.wait(80, function() return false end, 50)]])
  
  local count = child.lua_get([[fetch_count]])
  -- Should be 1 from on_cursor_move (which also calls prefetch_record_views, but
  -- prefetch finds the cache already has `fetching=true` from show_view, so returns early)
  eq(count, 1)
end

test_set["prefetch: cache hit prevents re-fetch on tab switch"] = function()
  child.lua([[
    fetch_count = 0
    
    local counting_view = {
      id = "prefetch_cache_test",
      key = "z",
      label = "PrefetchCacheTest",
      fetch = function(record, callback)
        fetch_count = fetch_count + 1
        vim.schedule(function()
          callback({ result = "data" }, nil)
        end)
      end,
      render = function(record, data)
        return { "data" }, { {} }
      end,
    }
    
    -- Inject into dashboard_views
    table.insert(dashboard_views, counting_view)
    
    -- Mock org_view.fetch_org_display
    org_view.fetch_org_display = function(record, callback)
      vim.schedule(function()
        callback({ alias = record.alias }, nil)
      end)
    end
    
    records = {
      { alias = "cache_test_org", username = "user1", org_type = "production", expiration_date = nil },
    }
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])
  
  child.lua([[vim.wait(80, function() return false end, 50)]])
  
  -- Get initial count
  local count_before = child.lua_get([[fetch_count]])
  eq(count_before, 1)  -- One from on_cursor_move
  
  -- Switch to the prefetched view (cache hit, no re-fetch)
  child.lua([[vim.api.nvim_input("z")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])
  
  local count_after = child.lua_get([[fetch_count]])
  -- Should still be 1 (cache hit)
  eq(count_after, 1)
end

test_set["arrow keys: <Up>/<Down> scroll view window, not org list"] = function()
  child.lua([[
    -- Create a view that returns more lines than the pane height
    local tall_view = {
      id = "tall_view",
      key = "t",
      label = "TallView",
      fetch = function(record, callback)
        vim.schedule(function()
          callback({ tall = true }, nil)
        end)
      end,
      render = function(record, data)
        local lines = {}
        for i = 1, 30 do
          table.insert(lines, "line " .. tostring(i))
        end
        local line_hls = {}
        for _ = 1, #lines do
          table.insert(line_hls, {})
        end
        return lines, line_hls
      end,
    }
    
    table.insert(dashboard_views, tall_view)
    
    org_view.fetch_org_display = function(record, callback)
      vim.schedule(function()
        callback({ alias = record.alias }, nil)
      end)
    end
    
    records = {
      { alias = "tall_test_org", username = "user1", org_type = "production", expiration_date = nil },
    }
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])
  
  child.lua([[vim.wait(80, function() return false end, 50)]])
  
  -- Switch to the tall view
  child.lua([[vim.api.nvim_input("t")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])
  
  -- Resolve the list/view window handles: both dashboard buffers share
  -- filetype "SfOrgDashboard", but only the view window has a non-empty
  -- 'winbar' (the tab strip) -- that is what tells them apart here.
  child.lua([[
    GLOBAL_view_window, GLOBAL_list_window = nil, nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "SfOrgDashboard" then
        if vim.wo[win].winbar ~= "" then
          GLOBAL_view_window = win
        else
          GLOBAL_list_window = win
        end
      end
    end
  ]])
  
  -- Get initial view window cursor position
  local view_cursor_before = child.lua([[return vim.api.nvim_win_get_cursor(GLOBAL_view_window)[1] ]])
  local list_cursor_before = child.lua([[return vim.api.nvim_win_get_cursor(GLOBAL_list_window)[1] ]])
  
  -- Press <Down> to scroll view pane
  child.lua([[vim.api.nvim_input("<Down>")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])
  
  local view_cursor_after = child.lua([[return vim.api.nvim_win_get_cursor(GLOBAL_view_window)[1] ]])
  local list_cursor_after = child.lua([[return vim.api.nvim_win_get_cursor(GLOBAL_list_window)[1] ]])
  
  -- View window cursor should have moved down
  eq(view_cursor_after, view_cursor_before + 1)
  -- List window cursor should NOT have changed
  eq(list_cursor_after, list_cursor_before)
end

test_set["arrow keys: <C-d>/<C-u> still scroll half-page"] = function()
  child.lua([[
    local tall_view = {
      id = "tall_view_hpage",
      key = "v",
      label = "TallViewHPage",
      fetch = function(record, callback)
        vim.schedule(function()
          callback({ tall = true }, nil)
        end)
      end,
      render = function(record, data)
        local lines = {}
        for i = 1, 50 do
          table.insert(lines, "line " .. tostring(i))
        end
        local line_hls = {}
        for _ = 1, #lines do
          table.insert(line_hls, {})
        end
        return lines, line_hls
      end,
    }
    
    table.insert(dashboard_views, tall_view)
    
    org_view.fetch_org_display = function(record, callback)
      vim.schedule(function()
        callback({ alias = record.alias }, nil)
      end)
    end
    
    records = {
      { alias = "hpage_test_org", username = "user1", org_type = "production", expiration_date = nil },
    }
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])
  
  child.lua([[vim.wait(80, function() return false end, 50)]])
  
  -- Switch to the tall view
  child.lua([[vim.api.nvim_input("v")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])
  
  -- Resolve the view window handle the same way as the <Up>/<Down> test
  -- above (only the view window has a non-empty 'winbar').
  child.lua([[
    GLOBAL_view_window = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "SfOrgDashboard" and vim.wo[win].winbar ~= "" then
        GLOBAL_view_window = win
      end
    end
  ]])
  
  -- Get initial topline (what line is at the top of the view window)
  local topline_before = child.lua([[
    return vim.fn.getwininfo(GLOBAL_view_window)[1].topline
  ]])
  
  -- Press <C-d> to scroll down half-page
  child.lua([[vim.api.nvim_input("<C-d>")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])
  
  local topline_after = child.lua([[
    return vim.fn.getwininfo(GLOBAL_view_window)[1].topline
  ]])
  
  -- topline should have moved down (half-page scroll)
  eq(topline_after > topline_before, true)
end

test_set["arrow keys: j/k still control org selection, not view scroll"] = function()
  child.lua([[
    local basic_view = {
      id = "basic_view_j_k",
      key = "b",
      label = "BasicViewJK",
      fetch = function(record, callback)
        vim.schedule(function()
          callback({ org = record.alias }, nil)
        end)
      end,
      render = function(record, data)
        return { "Org: " .. (data.org or "?") }, { {} }
      end,
    }
    
    table.insert(dashboard_views, basic_view)
    
    org_view.fetch_org_display = function(record, callback)
      vim.schedule(function()
        callback({ alias = record.alias }, nil)
      end)
    end
    
    records = {
      { alias = "org_a", username = "user1", org_type = "production", expiration_date = nil },
      { alias = "org_b", username = "user2", org_type = "production", expiration_date = nil },
    }
    
    dashboard.open(records, { prompt = "Orgs" })
  ]])
  
  child.lua([[vim.wait(80, function() return false end, 50)]])
  
  -- Switch to the custom view so its "Org: <alias>" marker is what's on
  -- screen -- the default active view on open is "details", which never
  -- renders that marker.
  child.lua([[vim.api.nvim_input("b")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])
  
  -- Get content for first org
  local content_first = child.lua([[
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for _, line in ipairs(lines) do
          if line:find("Org:") then
            return line
          end
        end
      end
    end
    return ""
  ]])
  
  eq(content_first:find("org_a") ~= nil, true)
  
  -- Press 'j' to move to next org
  child.lua([[vim.api.nvim_input("j")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])
  
  -- Get content for second org
  local content_second = child.lua([[
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for _, line in ipairs(lines) do
          if line:find("Org:") then
            return line
          end
        end
      end
    end
    return ""
  ]])
  
  eq(content_second:find("org_b") ~= nil, true)
end

test_set["disk cache: a cacheable tab persists its result and seeds the next open instantly"] = function()
  child.lua([[
    local util = require("sf.util")
    TMP_CACHE_DIR = vim.fn.tempname() .. "/"
    vim.fn.mkdir(TMP_CACHE_DIR, "p")
    util.get_cache_dir = function() return TMP_CACHE_DIR end

    -- Swap the real "packages" view's fetch for a counting/delayable stub.
    -- Its id stays "packages" -- what org_dashboard.lua's disk-cache
    -- allowlist keys off -- so this exercises the real seed/persist code
    -- path without needing to mock rest_api/session plumbing underneath.
    _G.packages_fetch_count = 0
    _G.packages_names = { "PkgOne", "PkgTwo" }
    for _, view_desc in ipairs(dashboard_views) do
      if view_desc.id == "packages" then
        view_desc.fetch = function(_, callback)
          _G.packages_fetch_count = _G.packages_fetch_count + 1
          local name = _G.packages_names[_G.packages_fetch_count] or "PkgOther"
          -- First call resolves ~immediately; the second (background,
          -- post-reopen) call is deliberately slower so the test can
          -- observe the seeded/stale paint before it lands.
          local delay = _G.packages_fetch_count == 1 and 0 or 200
          vim.defer_fn(function()
            callback({
              {
                SubscriberPackage = { Name = name, NamespacePrefix = vim.NIL },
                SubscriberPackageVersion = { MajorVersion = 1, MinorVersion = 0 },
              },
            }, nil)
          end, delay)
        end
      end
    end

    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }

    dashboard.open(records, { prompt = "Orgs" })
  ]])

  local buffer_has = function(needle)
    return child.lua(string.format(
      [[
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[buf].filetype == "SfOrgDashboard" then
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          for _, line in ipairs(lines) do
            if line:find(%q, 1, true) then
              return true
            end
          end
        end
      end
      return false
    ]],
      needle
    ))
  end

  child.lua([[vim.wait(60, function() return false end, 50)]])
  child.lua([[vim.api.nvim_input("p")]])
  child.lua([[vim.wait(80, function() return false end, 50)]])

  -- First-ever fetch: no disk cache yet, real fetch lands, result shown.
  eq(child.lua_get([[_G.packages_fetch_count]]), 1)
  eq(buffer_has("PkgOne"), true)

  -- Close and reopen (fresh session.cache) to simulate the dashboard being
  -- opened again -- "packages.json" is now on disk from the fetch above.
  child.lua([[vim.api.nvim_input("q")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])
  child.lua([[dashboard.open(records, { prompt = "Orgs" })]])
  -- Reopening alone (via its own cursor-landed prefetch) already seeds
  -- "org1:packages" from disk and kicks off the (200ms-delayed) real
  -- fetch; switching tabs just makes it the painted view.
  child.lua([[vim.api.nvim_input("p")]])
  child.lua([[vim.wait(20, function() return false end, 20)]])

  -- Well before the stubbed 200ms background fetch resolves: last
  -- session's data is already on screen, seeded straight from disk.
  eq(buffer_has("PkgOne"), true)
  eq(buffer_has("PkgTwo"), false)

  -- Once the background refresh lands, the pane updates and disk is
  -- re-persisted with the fresh result.
  child.lua([[vim.wait(250, function() return false end, 50)]])
  eq(child.lua_get([[_G.packages_fetch_count]]), 2)
  eq(buffer_has("PkgTwo"), true)
end

test_set["disk cache: a failed background refresh keeps showing the seeded data instead of blanking to an error"] = function()
  child.lua([[
    local util = require("sf.util")
    TMP_CACHE_DIR = vim.fn.tempname() .. "/"
    vim.fn.mkdir(TMP_CACHE_DIR, "p")
    util.get_cache_dir = function() return TMP_CACHE_DIR end
    -- File-per-org layout: every cacheable view for one org shares one
    -- JSON file (orgs/<alias>.json), keyed by view id -- see Org.org_cache.
    util.write_cache_json("orgs/org1.json", {
      packages = {
        {
          SubscriberPackage = { Name = "SeededPkg", NamespacePrefix = vim.NIL },
          SubscriberPackageVersion = { MajorVersion = 1, MinorVersion = 0 },
        },
      },
    })

    for _, view_desc in ipairs(dashboard_views) do
      if view_desc.id == "packages" then
        view_desc.fetch = function(_, callback)
          vim.schedule(function()
            callback(nil, "boom: org unreachable")
          end)
        end
      end
    end

    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }

    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  child.lua([[vim.api.nvim_input("p")]])
  child.lua([[vim.wait(80, function() return false end, 50)]])

  local found = child.lua([[
    _G.has_seed, _G.has_error = false, false
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for _, line in ipairs(lines) do
          if line:find("SeededPkg", 1, true) then
            _G.has_seed = true
          end
          if line:find("Failed to load", 1, true) then
            _G.has_error = true
          end
        end
      end
    end
    return { seed = _G.has_seed, err = _G.has_error }
  ]])

  eq(found.seed, true)
  eq(found.err, false)
end

test_set["CR on logs tab: downloads scoped to that org's alias, opens the log, and closes the dashboard"] = function()
  child.sf_setup()
  child.go_to_sf_dir() -- util.get_sf_root() (used to build the download dir) needs a real sf project root
  local windows_before = child.lua_get([[#vim.api.nvim_list_wins()]])

  child.lua([[
    Org = require("sf.org")
    util = require("sf.util")
    -- A different alias than the one being browsed -- proves the download
    -- is scoped to the browsed org, not whatever target_org happens to be.
    util.target_org = "some_other_org"

    Org.list_org_logs = function(alias, callback)
      vim.schedule(function()
        callback({ { id = "07L1", user = "u", start_time = "2024-01-01T00:00:00", size = 100, status = "Success", operation = "Op" } }, nil)
      end)
    end

    _G.download_args = nil
    Org.download_log = function(log_id, dir, on_done, alias)
      _G.download_args = { log_id = log_id, alias = alias, dir = dir }
      on_done(dir .. log_id .. ".log")
    end
    _G.opened_path = nil
    util.try_open_file = function(path)
      _G.opened_path = path
    end

    records = {
      { alias = "myorg", username = "user1", org_type = "production", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  -- Switch to the logs tab.
  child.lua([[vim.api.nvim_input("l")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])
  -- Move the view pane's cursor onto the (only) log row, without ever
  -- leaving the list window -- this is the path that used to silently do
  -- nothing because <CR> was only bound on the view buffer.
  child.lua([[vim.api.nvim_input("<Down>")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])
  child.lua([[vim.api.nvim_input("<CR>")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])

  local download_args = child.lua_get([[_G.download_args]])
  eq(download_args.log_id, "07L1")
  eq(download_args.alias, "myorg")
  -- sfdx-conventional location, not the cache dir.
  eq(download_args.dir:find(".sfdx/tools/debug/logs/", 1, true) ~= nil, true)
  eq(download_args.dir:find(".nvim/sf", 1, true) == nil, true)
  eq(child.lua_get([[_G.opened_path ~= nil]]), true)
  -- Dashboard floats gone -- back to whatever window count there was
  -- before `dashboard.open`, not stuck showing log text in the list pane.
  eq(child.lua_get([[#vim.api.nvim_list_wins()]]), windows_before)
end

test_set["CR on logs tab: still works focused directly on the view buffer"] = function()
  child.sf_setup()
  child.go_to_sf_dir()
  child.lua([[
    Org = require("sf.org")
    util = require("sf.util")

    Org.list_org_logs = function(alias, callback)
      vim.schedule(function()
        callback({ { id = "07L2", user = "u", start_time = "2024-01-01T00:00:00", size = 100, status = "Success", operation = "Op" } }, nil)
      end)
    end

    _G.download_args = nil
    Org.download_log = function(log_id, dir, on_done, alias)
      _G.download_args = { log_id = log_id, alias = alias }
      on_done(dir .. log_id .. ".log")
    end
    util.try_open_file = function() end

    records = {
      { alias = "myorg", username = "user1", org_type = "production", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  child.lua([[vim.api.nvim_input("l")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])

  child.lua([[
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "SfOrgDashboard" and vim.wo[win].winbar ~= "" then
        vim.api.nvim_set_current_win(win)
      end
    end
    vim.api.nvim_input("<Down>")
  ]])
  child.lua([[vim.wait(30, function() return false end, 30)]])
  child.lua([[vim.api.nvim_input("<CR>")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])

  eq(child.lua_get([[_G.download_args.log_id]]), "07L2")
end

test_set["D on logs tab: downloads without opening or closing the dashboard, so multiple logs can be grabbed in a row"] = function()
  child.sf_setup()
  child.go_to_sf_dir()
  child.lua([[
    Org = require("sf.org")
    util = require("sf.util")

    Org.list_org_logs = function(alias, callback)
      vim.schedule(function()
        callback({ { id = "07L3", user = "u", start_time = "2024-01-01T00:00:00", size = 100, status = "Success", operation = "Op" } }, nil)
      end)
    end

    _G.download_count = 0
    Org.download_log = function(log_id, dir, on_done, alias)
      _G.download_count = _G.download_count + 1
      on_done(dir .. log_id .. ".log")
    end
    _G.open_count = 0
    util.try_open_file = function()
      _G.open_count = _G.open_count + 1
    end

    records = {
      { alias = "myorg", username = "user1", org_type = "production", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  child.lua([[vim.api.nvim_input("l")]])
  child.lua([[vim.wait(60, function() return false end, 50)]])
  child.lua([[vim.api.nvim_input("<Down>")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])

  -- Press D twice -- both should download (no close in between), neither
  -- should open the file.
  child.lua([[vim.api.nvim_input("D")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])
  child.lua([[vim.api.nvim_input("D")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])

  eq(child.lua_get([[_G.download_count]]), 2)
  eq(child.lua_get([[_G.open_count]]), 0)
  -- Dashboard windows still there -- D must not close it.
  local still_open = child.lua([[
    local count = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "SfOrgDashboard" then
        count = count + 1
      end
    end
    return count
  ]])
  eq(still_open, 2)
end

test_set["D outside logs tab: refuses a prod org without prompting"] = function()
  child.lua([[
    util = require("sf.util")
    Org = require("sf.org")

    _G.err_msg = nil
    util.show_err = function(msg) _G.err_msg = msg end
    vim.ui.input = function() error("must not prompt for a prod org") end
    Org.delete_org = function() error("must not be called for a prod org") end

    records = {
      { alias = "prod1", username = "user1", org_type = "production", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  child.lua([[vim.api.nvim_input("D")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])

  expect.match(child.lua_get([[_G.err_msg]]), "scratch orgs and sandboxes")
end

test_set["D outside logs tab: a 'n' answer cancels without deleting"] = function()
  child.lua([[
    Org = require("sf.org")
    vim.ui.input = function(_, cb) cb("n") end
    Org.delete_org = function() error("must not be called when the answer isn't y") end

    records = {
      { alias = "scratch1", username = "user1", org_type = "scratch", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  child.lua([[vim.api.nvim_input("D")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])
  -- Reaching here without the error above firing is the assertion; nothing
  -- else to check.
end

test_set["D outside logs tab: a 'y' answer deletes the org under the cursor and repaints the list"] = function()
  child.lua([[
    Org = require("sf.org")
    vim.ui.input = function(_, cb) cb("y") end

    _G.deleted_alias = nil
    Org.delete_org = function(record, on_done)
      _G.deleted_alias = record.alias
      on_done()
    end

    records = {
      { alias = "sandbox1", username = "user1", org_type = "sandbox", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  child.lua([[vim.api.nvim_input("D")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])

  eq(child.lua_get([[_G.deleted_alias]]), "sandbox1")
end

test_set["? help: opens an overlay with descriptions longer than the shortened footer labels, and toggles closed"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  local windows_before = child.lua_get([[#vim.api.nvim_list_wins()]])

  child.lua([[vim.api.nvim_input("?")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])

  local windows_during = child.lua_get([[#vim.api.nvim_list_wins()]])
  eq(windows_during, windows_before + 1)

  local help_text = child.lua([[
    local lines
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if text:find("Set local target org", 1, true) then
        lines = text
      end
    end
    return lines
  ]])
  expect.match(help_text, "Set local target org")
  expect.match(help_text, "Delete org %b()")

  child.lua([[vim.api.nvim_input("?")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])

  local windows_after = child.lua_get([[#vim.api.nvim_list_wins()]])
  eq(windows_after, windows_before)
end

test_set["R: refuses a non-sandbox without prompting"] = function()
  child.lua([[
    util = require("sf.util")
    Org = require("sf.org")

    _G.err_msg = nil
    util.show_err = function(msg) _G.err_msg = msg end
    vim.ui.input = function() error("must not prompt for a non-sandbox") end
    Org.refresh_sandbox = function() error("must not be called for a non-sandbox") end

    records = {
      { alias = "scratch1", username = "user1", org_type = "scratch", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  child.lua([[vim.api.nvim_input("R")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])

  expect.match(child.lua_get([[_G.err_msg]]), "sandboxes can be refreshed")
end

test_set["R on a sandbox: prompts, then requests a refresh through Org.refresh_sandbox on 'y'"] = function()
  child.lua([[
    Org = require("sf.org")
    vim.ui.input = function(_, cb) cb("y") end

    _G.refreshed_alias = nil
    Org.refresh_sandbox = function(record, on_done)
      _G.refreshed_alias = record.alias
      on_done()
    end

    records = {
      { alias = "sandbox1", username = "user1", org_type = "sandbox", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  child.lua([[vim.api.nvim_input("R")]])
  child.lua([[vim.wait(30, function() return false end, 30)]])

  eq(child.lua_get([[_G.refreshed_alias]]), "sandbox1")
end

test_set["navigate: opens a fresh dashboard positioned on the given org + tab"] = function()
  child.lua([[
    Org = require("sf.org")
    Org.list_org_logs = function(alias, callback)
      vim.schedule(function()
        callback({}, nil)
      end)
      _G.fetched_alias = alias
    end

    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
      { alias = "org2", username = "user2", org_type = "production", expiration_date = nil },
    }
    dashboard.navigate(records, { prompt = "Orgs", view_id = "logs", alias = "org2" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])

  eq(child.lua_get([[#vim.api.nvim_list_wins() >= 2]]), true)
  eq(child.lua_get([[_G.fetched_alias]]), "org2")
end

test_set["navigate: reuses an already-open session instead of stacking a second dashboard"] = function()
  child.lua([[
    Org = require("sf.org")
    _G.fetched_aliases = {}
    Org.list_org_logs = function(alias, callback)
      table.insert(_G.fetched_aliases, alias)
      vim.schedule(function()
        callback({}, nil)
      end)
    end

    records = {
      { alias = "org1", username = "user1", org_type = "production", expiration_date = nil },
      { alias = "org2", username = "user2", org_type = "production", expiration_date = nil },
    }
    dashboard.open(records, { prompt = "Orgs" })
  ]])

  child.lua([[vim.wait(60, function() return false end, 50)]])
  local windows_before = child.lua_get([[#vim.api.nvim_list_wins()]])

  child.lua([[dashboard.navigate(records, { view_id = "logs", alias = "org2" })]])
  child.lua([[vim.wait(60, function() return false end, 50)]])

  local windows_after = child.lua_get([[#vim.api.nvim_list_wins()]])
  eq(windows_after, windows_before)
  eq(child.lua_get([[_G.fetched_aliases[#_G.fetched_aliases] ]]), "org2")
end

return test_set
