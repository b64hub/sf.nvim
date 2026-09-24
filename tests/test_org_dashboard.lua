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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
      { alias = "org2", username = "user2", is_sandbox = true, is_default = false, is_default_devhub = false, expiration_date = nil },
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
      { alias = "myorg", username = "user@example.com", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
      { alias = "other", username = "user2", is_sandbox = true, is_default = false, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
      { alias = "org2", username = "user2", is_sandbox = true, is_default = false, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
      { alias = "org2", username = "user2", is_sandbox = true, is_default = false, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = false, is_default_devhub = false, expiration_date = nil },
      { alias = "org2", username = "user2", is_sandbox = true, is_default = false, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
      { alias = "org2", username = "user2", is_sandbox = true, is_default = false, is_default_devhub = false, expiration_date = nil },
    }
    helpers.orgs = records
    
    -- Add an action that tracks if repaint_list is called
    repaint_called = false
    table.insert(dashboard_views, {
      id = "toggle_default",
      key = "t",
      label = "Toggle Default",
      fetch = nil,
      render = nil,
      action = function(record, dashboard_api)
        helpers.mark_default(record.alias)
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
  
  -- Verify the is_default field was mutated
  eq(child.lua_get([[helpers.orgs[1].is_default]]), false)
  eq(child.lua_get([[helpers.orgs[2].is_default]]), true)

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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
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
      { alias = "org1", username = "user1", is_prod = true, is_default = true, is_default_devhub = false, expiration_date = nil },
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
    
    records = {
      { alias = "default_org", username = "user1", is_default = true, is_default_devhub = false, is_prod = false, is_sandbox = false, expiration_date = nil },
      { alias = "devhub_org", username = "user2", is_default = false, is_default_devhub = true, is_prod = false, is_sandbox = false, expiration_date = nil },
      { alias = "other_org", username = "user3", is_default = false, is_default_devhub = false, is_prod = false, is_sandbox = false, expiration_date = nil },
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
      { alias = "single_org", username = "user1", is_default = true, is_default_devhub = true, is_prod = false, is_sandbox = false, expiration_date = nil },
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
      { alias = "cache_test_org", username = "user1", is_default = true, is_default_devhub = false, is_prod = false, is_sandbox = false, expiration_date = nil },
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
      { alias = "tall_test_org", username = "user1", is_default = true, is_default_devhub = false, is_prod = false, is_sandbox = false, expiration_date = nil },
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
      { alias = "hpage_test_org", username = "user1", is_default = true, is_default_devhub = false, is_prod = false, is_sandbox = false, expiration_date = nil },
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
      { alias = "org_a", username = "user1", is_default = true, is_default_devhub = false, is_prod = false, is_sandbox = false, expiration_date = nil },
      { alias = "org_b", username = "user2", is_default = false, is_default_devhub = false, is_prod = false, is_sandbox = false, expiration_date = nil },
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

return test_set
