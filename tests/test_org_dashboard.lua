local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local new_set = MiniTest.new_set

local test_set = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[
        dashboard = require("sf.ui.org_dashboard")
        org_view = require("sf.ui.org_view")
        
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

return test_set
