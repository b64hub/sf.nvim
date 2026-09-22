local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local expect, eq = MiniTest.expect, MiniTest.expect.equality
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
--
-- T['get()']['target_org empty then err'] = function()
--   expect.error(function() child.lua([[M.get()]]) end)
-- end

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
        util.job_call = function() end
        M = require('sf.org')
      ]])
    end,
  },
})

T["open_org"]["does not crash when opening an org"] = function()
  -- Just verify it doesn't error - a successful call
  child.lua([[M.open_org("test-org")]])
end

return T
