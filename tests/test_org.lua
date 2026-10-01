local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- helper

local mock_test = function()
  child.cmd("luafile tests/mock/mock.lua")
end

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[M = require('sf.org')]])
      child.lua([[S = require('sf')]])
    end,
    post_once = child.stop,
  },
})

T["fetch_org_list"] = new_set({ hooks = { pre_case = mock_test } })

T["fetch_org_list"]["test1"] = function()
  eq(child.lua_get([[vim.lsp.buf_get_clients()]]), { "mock client" })
end

T["fetch_org_list"]["on_done callback is invoked after fetch completes"] = function()
  child.lua([[
    local util = require("sf.util")
    util.is_sf_cmd_installed = function() end
    
    -- Track callback invocation globally
    _G.callback_called = false
    
    -- Mock vim.fn.jobstart to immediately fire the on_exit callback
    vim.fn.jobstart = function(cmd, opts)
      -- Simulate buffered stdout with mock org data
      if opts.on_stdout then
        opts.on_stdout(nil, { '{"result":{"nonScratchOrgs":[],"scratchOrgs":[]}}' })
      end
      -- Fire on_exit callback immediately
      if opts.on_exit then
        opts.on_exit()
      end
      return 1  -- return a mock job ID
    end
    
    -- Call fetch_org_list with callback
    M.fetch_org_list(function()
      _G.callback_called = true
    end)
  ]])
  
  eq(child.lua_get([[_G.callback_called]]), true)
end

T["fetch_org_list"]["overlapping calls coalesce onto one job and every waiter still fires"] = function()
  child.lua([[
    local util = require("sf.util")
    util.is_sf_cmd_installed = function() end

    -- Mock jobstart to defer completion instead of firing inline, so the
    -- two fetch_org_list calls below can genuinely overlap in flight.
    local pending_fetches = {}
    vim.fn.jobstart = function(cmd, opts)
      table.insert(pending_fetches, opts)
      return #pending_fetches -- mock job id
    end

    _G.pending_fetches = pending_fetches
    _G.Org_fetch_org_list = M.fetch_org_list
    _G.done_count = 0
  ]])

  -- Start two fetches back-to-back, before either can complete.
  child.lua([[
    _G.Org_fetch_org_list(function() _G.done_count = _G.done_count + 1 end) -- caller 1
    _G.Org_fetch_org_list(function() _G.done_count = _G.done_count + 1 end) -- caller 2
  ]])

  -- Exactly one `sf org list` CLI process spawned for both callers.
  eq(child.lua_get([[#_G.pending_fetches]]), 1)

  -- Complete that one job.
  child.lua([[
    local opts = _G.pending_fetches[1]
    opts.on_stdout(nil, {
      '{"result":{"nonScratchOrgs":[{"alias":"org1","username":"user1","isScratch":false,"isSandbox":false,"isDefaultUsername":false,"isDefaultDevHubUsername":false}],"scratchOrgs":[]}}',
    })
    opts.on_exit()
  ]])

  -- Both waiters ran, and the org list reflects the one completed fetch.
  eq(child.lua_get([[_G.done_count]]), 2)
  eq(child.lua_get([[#(M.__test.orgs)]]), 1)
end

T["fetch_org_list"]["a call after the in-flight job completes spawns a genuinely fresh fetch"] = function()
  child.lua([[
    local util = require("sf.util")
    util.is_sf_cmd_installed = function() end

    local call_count = 0
    vim.fn.jobstart = function(cmd, opts)
      call_count = call_count + 1
      local org_json = '{"alias":"org' .. call_count .. '","username":"user' .. call_count .. '","isScratch":false,"isSandbox":false,"isDefaultUsername":false,"isDefaultDevHubUsername":false}'
      opts.on_stdout(nil, { '{"result":{"nonScratchOrgs":[' .. org_json .. '],"scratchOrgs":[]}}' })
      opts.on_exit()
      return call_count
    end

    M.fetch_org_list(function() end)
    M.fetch_org_list(function() end) -- nothing in flight anymore -- must spawn again, not reuse a stale result
    _G.call_count = call_count
  ]])

  eq(child.lua_get([[_G.call_count]]), 2)
end

T["store_orgs"] = new_set({ hooks = { pre_case = mock_test } })

T["store_orgs"]["upserts idempotently: calling it twice with the same payload does not duplicate rows"] = function()
  child.lua([[
    H = M.__test
    H.orgs = {}
    local payload = { '{"result":{"nonScratchOrgs":[{"alias":"org1","username":"user1","isScratch":false,"isSandbox":false,"isDefaultUsername":false,"isDefaultDevHubUsername":false}],"scratchOrgs":[]}}' }
    H.store_orgs(payload)
    H.store_orgs(payload)
  ]])
  eq(child.lua_get([[#H.orgs]]), 1)
end
--
-- T['get()']['target_org empty then err'] = function()
--   expect.error(function() child.lua([[M.get()]]) end)
-- end

T["with_orgs"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        H = M.__test
        H.orgs = {}
        util = require("sf.util")
        util.show = function() end
        util.show_err = function() end
      ]])
    end,
  },
})

T["with_orgs"]["seeds from the on-disk snapshot instantly, then refreshes in the background"] = function()
  child.lua([[
    util.read_cache_json = function(file_name)
      if file_name == H.ORG_LIST_CACHE_FILE then
        return { { alias = "cached_org", username = "user@example.com" } }
      end
      return nil
    end

    -- Never calls on_done in this test -- only care that it was reached,
    -- and that it was reached *after* fn already ran with the seeded data.
    _G.background_fetch_started = false
    H.fetch_org_list = function(_)
      _G.background_fetch_started = true
    end

    _G.fn_called_with = nil
    H.with_orgs(function()
      _G.fn_called_with = vim.deepcopy(H.orgs)
    end)
  ]])

  eq(child.lua_get([[_G.fn_called_with ~= nil]]), true)
  eq(child.lua_get([[_G.fn_called_with[1].alias]]), "cached_org")
  eq(child.lua_get([[_G.background_fetch_started]]), true)
end

T["with_orgs"]["falls back to a blocking fetch when there is no disk snapshot either"] = function()
  child.lua([[
    util.read_cache_json = function() return nil end

    _G.fetch_called = false
    H.fetch_org_list = function(on_done)
      _G.fetch_called = true
      H.orgs = { { alias = "fresh_org" } }
      on_done()
    end

    _G.fn_called_with = nil
    H.with_orgs(function()
      _G.fn_called_with = vim.deepcopy(H.orgs)
    end)
  ]])

  eq(child.lua_get([[_G.fetch_called]]), true)
  eq(child.lua_get([[_G.fn_called_with[1].alias]]), "fresh_org")
end

T["with_orgs"]["already-populated helpers.orgs short-circuits both the disk read and the fetch"] = function()
  child.lua([[
    H.orgs = { { alias = "already_loaded" } }
    util.read_cache_json = function() error("must not be called") end
    H.fetch_org_list = function() error("must not be called") end

    _G.fn_called_with = nil
    H.with_orgs(function()
      _G.fn_called_with = vim.deepcopy(H.orgs)
    end)
  ]])

  eq(child.lua_get([[_G.fn_called_with[1].alias]]), "already_loaded")
end

T["mark_default"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[H = M.__test]])
      child.lua([[
        H.orgs = {
          { alias = "one", is_default = true },
          { alias = "two", is_default = false },
        }
      ]])
    end,
  },
})

T["mark_default"]["flips is_default onto the given alias and off every other org"] = function()
  child.lua([[H.mark_default("two")]])
  eq(child.lua_get([[H.orgs[1].is_default]]), false)
  eq(child.lua_get([[H.orgs[2].is_default]]), true)
end

T["write_target_org_to_config"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[H = M.__test]])
      child.lua([[
        TMP_HOME = vim.fn.tempname()
        vim.fn.mkdir(TMP_HOME .. "/.sf", "p")
        vim.fn.writefile({ vim.json.encode({ ["api-version"] = "60.0" }) }, TMP_HOME .. "/.sf/config.json")
        vim.uv.os_homedir = function() return TMP_HOME end
      ]])
    end,
  },
})

T["write_target_org_to_config"]["merges target-org into the existing global config"] = function()
  child.lua([[OK, ERR = H.write_target_org_to_config("my-org", true)]])
  eq(child.lua_get([[OK]]), true)

  local saved = child.lua_get([[vim.json.decode(table.concat(vim.fn.readfile(TMP_HOME .. "/.sf/config.json"), "\n"))]])
  eq(saved["target-org"], "my-org")
  eq(saved["api-version"], "60.0")
end

T["set_global_target_org"] = new_set()

T["set_global_target_org"]["does not open selector when org list is empty"] = function()
  child.lua([[
    vim.ui.select = function() error("must not be called") end
    M.set_global_target_org()
  ]])
end

T["set_target_org_to"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[H = M.__test]])
      child.lua([[
        util = require("sf.util")
        util.show_err = function() end
        util.set_target_org = function() end
        H.orgs = {
          { alias = "org1", username = "user1", is_default = true, is_default_devhub = false },
          { alias = "org2", username = "user2", is_default = false, is_default_devhub = false },
        }
        -- Mock write_target_org_to_config to succeed
        original_write = H.write_target_org_to_config
        H.write_target_org_to_config = function(alias, global)
          return true
        end
      ]])
    end,
  },
})

T["set_target_org_to"]["public wrapper calls mark_default"] = function()
  child.lua([[
    -- Spy on mark_default
    original_mark_default = H.mark_default
    mark_default_called = {}
    H.mark_default = function(alias)
      table.insert(mark_default_called, alias)
      original_mark_default(alias)
    end
    
    M.set_target_org_to("org2", false)
  ]])
  
  local called = child.lua_get([[#mark_default_called > 0 and mark_default_called[1] == "org2"]])
  eq(called, true)
end

T["set_target_org_to"]["marks the given alias as default"] = function()
  child.lua([[
    M.set_target_org_to("org2", false)
  ]])
  
  eq(child.lua_get([[H.orgs[2].is_default]]), true)
end

T["open_org"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        util = require("sf.util")
        util.silent_job_call = function() end
        M = require('sf.org')
      ]])
    end,
  },
})

T["open_org"]["does not crash when opening an org"] = function()
  -- Just verify it doesn't error - a successful call
  child.lua([[M.open_org("test-org")]])
end

T["parse_log_list"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[H = M.__test]])
    end,
  },
})

T["parse_log_list"]["parses apex list log --json output into flat array"] = function()
  -- Outer wrapper uses a higher bracket level ([=[ ]=]) specifically so
  -- the embedded JSON literal below it can safely use plain [[ ]] --
  -- Lua long-bracket strings do not nest, so a bare [[ ]] pair here would
  -- have closed the outer string early and left the rest as a syntax error.
  child.lua([=[
    local json = [[{
      "result": [
        {
          "Id": "log1",
          "LogUser": { "Name": "user1" },
          "StartTime": "2024-01-01T10:00:00.000+0000",
          "LogLength": 1024,
          "Status": "Success"
        },
        {
          "Id": "log2",
          "LogUser": { "Name": "user2" },
          "StartTime": "2024-01-02T11:00:00.000+0000",
          "LogLength": 2048,
          "Status": "Success"
        }
      ]
    }]]
    logs, err = H.parse_log_list(json)
  ]=])
  
  eq(child.lua_get([[#logs]]), 2)
  eq(child.lua_get([[logs[1].id]]), "log1")
  eq(child.lua_get([[logs[1].user]]), "user1")
  eq(child.lua_get([[logs[1].status]]), "Success")
  eq(child.lua_get([[logs[2].id]]), "log2")
  eq(child.lua_get([[logs[2].user]]), "user2")
end

T["parse_log_list"]["returns empty array when no logs in result"] = function()
  child.lua([=[
    local json = [[{ "result": [] }]]
    logs, err = H.parse_log_list(json)
  ]=])
  
  eq(child.lua_get([[#logs]]), 0)
  eq(child.lua_get([[err == nil]]), true)
end

T["parse_log_list"]["returns error on invalid JSON"] = function()
  child.lua([[
    logs, err = H.parse_log_list("invalid json {")
  ]])
  
  eq(child.lua_get([[#logs]]), 0)
  expect.match(child.lua_get([[err]]), "Failed")
end

T["parse_log_list"]["parses Operation field from log entries"] = function()
  child.lua([=[
    local json = [[
      {
        "result": [
          {
            "Id": "log1",
            "LogUser": { "Name": "alice" },
            "StartTime": "2024-01-01T10:00:00.000+0000",
            "LogLength": 1024,
            "Status": "Success",
            "Operation": "/aura"
          },
          {
            "Id": "log2",
            "LogUser": { "Name": "bob" },
            "StartTime": "2024-01-02T11:00:00.000+0000",
            "LogLength": 2048,
            "Status": "Success",
            "Operation": "AsyncQueued execution of MyJob"
          },
          {
            "Id": "log3",
            "LogUser": { "Name": "carol" },
            "StartTime": "2024-01-03T12:00:00.000+0000",
            "LogLength": 512,
            "Status": "Error"
          }
        ]
      }
    ]]
    logs, err = H.parse_log_list(json)
  ]=])

  eq(child.lua_get([[#logs]]), 3)
  eq(child.lua_get([[logs[1].operation]]), "/aura")
  eq(child.lua_get([[logs[2].operation]]), "AsyncQueued execution of MyJob")
  -- Record without Operation field should have empty string
  eq(child.lua_get([[logs[3].operation]]), "")
end

T["open_dashboard"] = new_set()

T["open_dashboard"]["fetches the org list first, then opens once orgs are populated"] = function()
  child.lua([[
    H = M.__test
    H.orgs = {}
    H.fetch_org_list = function(on_done)
      H.orgs = { { alias = "one" } }
      on_done()
    end

    local dashboard_module = require("sf.ui.org_dashboard")
    local original_open = dashboard_module.open
    _dashboard_open_called = false
    dashboard_module.open = function()
      _dashboard_open_called = true
    end

    M.open_dashboard()
    dashboard_module.open = original_open
  ]])

  eq(child.lua_get([[_dashboard_open_called]]), true)
end

T["open_dashboard"]["does not open dashboard when the fetch still yields no orgs"] = function()
  child.lua([[
    util = require("sf.util")
    H = M.__test
    H.orgs = {}
    H.fetch_org_list = function(on_done) on_done() end

    _show_err_message = nil
    util.show_err = function(msg)
      _show_err_message = msg
    end

    local dashboard_module = require("sf.ui.org_dashboard")
    local original_open = dashboard_module.open
    _dashboard_open_called = false
    dashboard_module.open = function()
      _dashboard_open_called = true
    end

    M.open_dashboard()
    dashboard_module.open = original_open
  ]])

  eq(child.lua_get([[_show_err_message ~= nil]]), true)
  eq(child.lua_get([[_dashboard_open_called]]), false)
end

T["open_dashboard"]["opens dashboard when orgs are available"] = function()
  child.lua([[
    util = require("sf.util")
    H = M.__test
    H.orgs = {
      { alias = "org1", username = "user1", is_default = true, is_default_devhub = false },
      { alias = "org2", username = "user2", is_default = false, is_default_devhub = false },
    }
    
    -- Mock the dashboard.open to avoid creating actual windows
    local dashboard_module = require("sf.ui.org_dashboard")
    local original_open = dashboard_module.open
    dashboard_module.open = function(orgs, opts)
      _dashboard_open_called = true
      _dashboard_orgs_count = #orgs
      _dashboard_opts_prompt = opts.prompt
    end
    
    M.open_dashboard()
    dashboard_module.open = original_open
  ]])
  
  eq(child.lua_get([[_dashboard_open_called]]), true)
  eq(child.lua_get([[_dashboard_orgs_count]]), 2)
  eq(child.lua_get([[_dashboard_opts_prompt]]), "Org Dashboard")
end

T["set_target_org"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        util = require("sf.util")
        H = M.__test
        util.set_target_org = function() end
        H.orgs = {
          { alias = "org1", username = "user1", is_default = false, is_default_devhub = false },
          { alias = "org2", username = "user2", is_default = true, is_default_devhub = false },
        }
        -- Mock write_target_org_to_config to succeed by default
        H.write_target_org_to_config = function(alias, global)
          return true
        end
      ]])
    end,
  },
})

T["set_target_org"]["does not open selector when the org list is (still) empty after fetching"] = function()
  child.lua([[
    H.orgs = {}
    H.fetch_org_list = function(on_done) on_done() end
    _G.called = false
    vim.ui.select = function() _G.called = true end
    M.set_target_org()
  ]])
  eq(child.lua_get([[_G.called]]), false) -- vim.ui.select should not be called
end

T["set_target_org"]["fetches the org list first when empty, then opens the selector"] = function()
  child.lua([[
    H.orgs = {}
    H.fetch_org_list = function(on_done)
      H.orgs = { { alias = "one", username = "one@example.com" } }
      on_done()
    end
    _G.called = false
    vim.ui.select = function() _G.called = true end
    M.set_target_org()
  ]])
  eq(child.lua_get([[_G.called]]), true)
end

T["set_target_org"]["calls vim.ui.select with formatted org items"] = function()
  child.lua([[
    _G.called = false
    _G.called_prompt = nil
    vim.ui.select = function(items, opts)
      _G.called = true
      _G.called_prompt = opts.prompt
    end
    M.set_target_org()
  ]])
  eq(child.lua_get([[_G.called]]), true)
  eq(child.lua_get([[_G.called_prompt]]), "Local target_org:")
end

T["set_target_org"]["writes config and marks default when record is selected"] = function()
  child.lua([[
    _G.write_called = false
    _G.write_alias = nil
    _G.write_global = nil
    H.write_target_org_to_config = function(alias, global)
      _G.write_called = true
      _G.write_alias = alias
      _G.write_global = global
      return true
    end
    
    _G.mark_called = false
    _G.mark_alias = nil
    local original_mark = H.mark_default
    H.mark_default = function(alias)
      _G.mark_called = true
      _G.mark_alias = alias
      original_mark(alias)
    end
    
    _G.select_callback = nil
    vim.ui.select = function(items, opts, callback)
      _G.select_callback = callback
    end
    
    M.set_target_org()
    
    -- Invoke the callback with org2
    if _G.select_callback then
      _G.select_callback(H.orgs[2])
    end
  ]])
  eq(child.lua_get([[_G.write_called]]), true)
  eq(child.lua_get([[_G.write_alias]]), "org2")
  eq(child.lua_get([[_G.write_global]]), false)
  eq(child.lua_get([[_G.mark_called]]), true)
  eq(child.lua_get([[_G.mark_alias]]), "org2")
end

T["set_target_org"]["ignores nil choice (user canceled)"] = function()
  child.lua([[
    _G.write_called = false
    H.write_target_org_to_config = function()
      _G.write_called = true
      return true
    end
    
    _G.select_callback = nil
    vim.ui.select = function(items, opts, callback)
      _G.select_callback = callback
    end
    
    M.set_target_org()
    
    -- Invoke the callback with nil (user canceled)
    if _G.select_callback then
      _G.select_callback(nil)
    end
  ]])
  eq(child.lua_get([[_G.write_called]]), false)
end

T["set_target_org"]["shows error when config write fails"] = function()
  child.lua([[
    _G.err_msg = nil
    util.show_err = function(msg)
      _G.err_msg = msg
    end
    
    H.write_target_org_to_config = function(alias, global)
      return false, "disk full"
    end
    
    _G.select_callback = nil
    vim.ui.select = function(items, opts, callback)
      _G.select_callback = callback
    end
    
    M.set_target_org()
    
    if _G.select_callback then
      _G.select_callback(H.orgs[1])
    end
  ]])
  eq(child.lua_get([[_G.err_msg ~= nil]]), true)
  expect.match(child.lua_get([[_G.err_msg]]), "disk full")
end

T["set_global_target_org"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        util = require("sf.util")
        H = M.__test
        util.set_target_org = function() end
        H.orgs = {
          { alias = "org1", username = "user1", is_default = false, is_default_devhub = false },
          { alias = "org2", username = "user2", is_default = true, is_default_devhub = false },
        }
        H.write_target_org_to_config = function(alias, global)
          return true
        end
      ]])
    end,
  },
})

T["set_global_target_org"]["calls vim.ui.select with formatted org items"] = function()
  child.lua([[
    _G.called = false
    _G.called_prompt = nil
    vim.ui.select = function(items, opts)
      _G.called = true
      _G.called_prompt = opts.prompt
    end
    M.set_global_target_org()
  ]])
  eq(child.lua_get([[_G.called]]), true)
  eq(child.lua_get([[_G.called_prompt]]), "Global target_org:")
end

T["set_global_target_org"]["writes config globally and notifies when record is selected"] = function()
  child.lua([[
    _G.write_called = false
    _G.write_global = nil
    H.write_target_org_to_config = function(alias, global)
      _G.write_called = true
      _G.write_global = global
      return true
    end
    
    _G.notify_msg = nil
    vim.notify = function(msg)
      _G.notify_msg = msg
    end
    
    _G.select_callback = nil
    vim.ui.select = function(items, opts, callback)
      _G.select_callback = callback
    end
    
    M.set_global_target_org()
    
    if _G.select_callback then
      _G.select_callback(H.orgs[2])
    end
  ]])
  eq(child.lua_get([[_G.write_called]]), true)
  eq(child.lua_get([[_G.write_global]]), true)
  eq(child.lua_get([[_G.notify_msg ~= nil]]), true)
  expect.match(child.lua_get([[_G.notify_msg]]), "org2")
end

T["set_global_target_org"]["ignores nil choice (user canceled)"] = function()
  child.lua([[
    _G.write_called = false
    H.write_target_org_to_config = function()
      _G.write_called = true
      return true
    end
    
    _G.select_callback = nil
    vim.ui.select = function(items, opts, callback)
      _G.select_callback = callback
    end
    
    M.set_global_target_org()
    
    if _G.select_callback then
      _G.select_callback(nil)
    end
  ]])
  eq(child.lua_get([[_G.write_called]]), false)
end

T["diff_in_org"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        util = require("sf.util")
        H = M.__test
        H.orgs = {
          { alias = "org1", username = "user1", is_default = false, is_default_devhub = false },
          { alias = "org2", username = "user2", is_default = true, is_default_devhub = false },
        }
      ]])
    end,
  },
})

T["diff_in_org"]["does not open selector when the org list is (still) empty after fetching"] = function()
  child.lua([[
    H.orgs = {}
    H.fetch_org_list = function(on_done) on_done() end
    _G.called = false
    vim.ui.select = function() _G.called = true end
    M.diff_in_org()
  ]])
  eq(child.lua_get([[_G.called]]), false)
end

T["diff_in_org"]["calls vim.ui.select with formatted org items"] = function()
  child.lua([[
    _G.called = false
    _G.called_prompt = nil
    vim.ui.select = function(items, opts)
      _G.called = true
      _G.called_prompt = opts.prompt
    end
    M.diff_in_org()
  ]])
  eq(child.lua_get([[_G.called]]), true)
  eq(child.lua_get([[_G.called_prompt]]), "Diff in org:")
end

T["diff_in_org"]["calls helpers.diff_in with selected org alias"] = function()
  child.lua([[
    _G.diff_called = false
    _G.diff_alias = nil
    local original_diff_in = H.diff_in
    H.diff_in = function(org)
      _G.diff_called = true
      _G.diff_alias = org
    end
    
    _G.select_callback = nil
    vim.ui.select = function(items, opts, callback)
      _G.select_callback = callback
    end
    
    M.diff_in_org()
    
    if _G.select_callback then
      _G.select_callback(H.orgs[1])
    end
  ]])
  eq(child.lua_get([[_G.diff_called]]), true)
  eq(child.lua_get([[_G.diff_alias]]), "org1")
end

T["diff_in_org"]["ignores nil choice (user canceled)"] = function()
  child.lua([[
    _G.diff_called = false
    H.diff_in = function()
      _G.diff_called = true
    end
    
    _G.select_callback = nil
    vim.ui.select = function(items, opts, callback)
      _G.select_callback = callback
    end
    
    M.diff_in_org()
    
    if _G.select_callback then
      _G.select_callback(nil)
    end
  ]])
  eq(child.lua_get([[_G.diff_called]]), false)
end

T["download_log"] = new_set()

T["download_log"]["fetches the body via the Tooling API (scoped to the given alias) and writes it to disk"] = function()
  child.lua([[
    H = M.__test
    rest_api = require("sf.sub.rest_api")

    _G._session_alias = nil
    rest_api.get_session = function(alias, cb)
      _G._session_alias = alias
      cb({ token = "tok", url = "https://x", api_version = "60.0" }, nil)
    end

    _G._body_log_id = nil
    rest_api.download_log_body = function(session, log_id, cb)
      _G._body_log_id = log_id
      cb("13:46:23.0 (1)|EXECUTION_STARTED", nil)
    end

    _G._dir = vim.fn.tempname() .. "/"
    _G._done_path = nil
    H.download_log("07Lxyz", _G._dir, function(path)
      _G._done_path = path
    end, "myorg")
  ]])

  eq(child.lua_get([[_G._session_alias]]), "myorg")
  eq(child.lua_get([[_G._body_log_id]]), "07Lxyz")
  local done_path = child.lua_get([[_G._done_path]])
  eq(done_path, child.lua_get([[_G._dir]]) .. "07Lxyz.log")
  eq(child.lua_get([[vim.fn.filereadable(_G._done_path) == 1]]), true)
  local written = child.lua_get([[table.concat(vim.fn.readfile(_G._done_path), "\n")]])
  eq(written, "13:46:23.0 (1)|EXECUTION_STARTED")

  child.lua([[vim.fn.delete(_G._dir, "rf")]])
end

T["download_log"]["does not call on_done when the session can't be resolved"] = function()
  child.lua([[
    H = M.__test
    rest_api = require("sf.sub.rest_api")

    rest_api.get_session = function(_, cb)
      cb(nil, "no default org")
    end

    _G._on_done_called = false
    H.download_log("07Lxyz", vim.fn.tempname() .. "/", function()
      _G._on_done_called = true
    end, "myorg")
  ]])

  eq(child.lua_get([[_G._on_done_called]]), false)
end

return T
