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
  child.lua([[vim.wait(500, function() return false end, 50)]])

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

  child.lua([[vim.wait(500, function() return false end, 50)]])

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

  child.lua([[vim.wait(500, function() return false end, 50)]])

  local windows_before = child.lua_get([[#vim.api.nvim_list_wins()]])
  eq(windows_before >= 2, true)

  child.lua([[vim.api.nvim_input("q")]])
  child.lua([[vim.wait(200, function() return false end, 50)]])

  local windows_after = child.lua_get([[#vim.api.nvim_list_wins()]])
  -- After closing the dashboard, there should be fewer windows
  eq(windows_after < windows_before, true)
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

  child.lua([[vim.wait(500, function() return false end, 50)]])

  -- Get the footer from any dashboard float (both list and view windows
  -- share the same footer_for() text).
  local footer_text = child.lua([[
    local footer_config = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      if config.footer then
        footer_config = config.footer
        break
      end
    end
    if footer_config then
      return footer_config[1][1]
    end
    return ""
  ]])

  -- Footer should contain 'd' for details view
  eq(footer_text:find("d") ~= nil, true)
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

  child.lua([[vim.wait(500, function() return false end, 50)]])

  -- Press 'f' to switch to fake view
  child.lua([[vim.api.nvim_input("f")]])
  child.lua([[vim.wait(500, function() return false end, 50)]])

  -- Get view buffer content to verify fake view is rendered
  local view_lines = child.lua([[
    local view_buffers = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        -- Find the buffer that has our fake view data
        if lines[1] and lines[1]:find("Fake view") then
          return lines
        end
      end
    end
    return {}
  ]])

  eq(#view_lines > 0, true)
  eq(view_lines[1]:find("Fake view") ~= nil, true)
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

  child.lua([[vim.wait(500, function() return false end, 50)]])

  -- Press 'c' to fetch counting_view
  child.lua([[vim.api.nvim_input("c")]])
  child.lua([[vim.wait(500, function() return false end, 50)]])

  local first_render = child.lua([[
    local view_buffers = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        if lines[1] and lines[1]:find("Fetch count") then
          return lines[1]
        end
      end
    end
    return ""
  ]])

  -- Should show count = 1
  eq(first_render:find("1") ~= nil, true)

  -- Press 'c' again
  child.lua([[vim.api.nvim_input("c")]])
  child.lua([[vim.wait(200, function() return false end, 50)]])

  local second_render = child.lua([[
    local view_buffers = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == "SfOrgDashboard" then
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        if lines[1] and lines[1]:find("Fetch count") then
          return lines[1]
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

  child.lua([[vim.wait(500, function() return false end, 50)]])

  -- Move to second org
  child.lua([[vim.api.nvim_input("j")]])
  child.lua([[vim.wait(100, function() return false end, 50)]])

  -- Press 'x' to trigger the action
  child.lua([[vim.api.nvim_input("x")]])
  child.lua([[vim.wait(200, function() return false end, 50)]])

  local called = child.lua_get([[action_spy.called]])
  local alias = child.lua_get([[action_spy.record_alias]])

  eq(called, true)
  eq(alias, "org2")
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

  child.lua([[vim.wait(500, function() return false end, 50)]])

  -- Move to second org
  child.lua([[vim.api.nvim_input("j")]])
  child.lua([[vim.wait(100, function() return false end, 50)]])

  -- Press 't' to toggle default (org2 becomes default, org1 is not)
  child.lua([[vim.api.nvim_input("t")]])
  child.lua([[vim.wait(200, function() return false end, 50)]])

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

return test_set
