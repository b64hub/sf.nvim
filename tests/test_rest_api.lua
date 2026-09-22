local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local eq = helpers.expect.equality
local new_set = MiniTest.new_set

local test_set = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.sf_setup()
      child.lua([[
        Api = require("sf.sub.rest_api")
        Util = require("sf.util")
        Util.target_org = "t_org"
      ]])
    end,
    post_once = child.stop,
  },
})

test_set["get_session: old form get_session(cb) still works, uses target_org"] = function()
  child.lua([[
    local captured
    local original_call = Util.silent_system_call
    Util.silent_system_call = function(cmd)
      captured = cmd
    end
    Api.get_session(function() end)
    Util.silent_system_call = original_call
    _G._captured_cmd = captured
  ]])

  local cmd = child.lua_get([[_G._captured_cmd]])
  eq(vim.tbl_contains(cmd, "-o"), true)
  local org_index
  for index, value in ipairs(cmd) do
    if value == "-o" then
      org_index = index
    end
  end
  eq(cmd[org_index + 1], "t_org")
end

test_set["get_session: new form get_session(alias, cb) scopes to the given alias"] = function()
  child.lua([[
    local captured
    local original_call = Util.silent_system_call
    Util.silent_system_call = function(cmd)
      captured = cmd
    end
    Api.get_session("other_org", function() end)
    Util.silent_system_call = original_call
    _G._captured_cmd = captured
  ]])

  local cmd = child.lua_get([[_G._captured_cmd]])
  local org_index
  for index, value in ipairs(cmd) do
    if value == "-o" then
      org_index = index
    end
  end
  eq(cmd[org_index + 1], "other_org")
end

test_set["get_session: new-form callback still receives session on success"] = function()
  child.lua([[
    local original_call = Util.silent_system_call
    Util.silent_system_call = function(_, _, _, cb)
      cb({ stdout = vim.json.encode({
        result = { accessToken = "tok", instanceUrl = "https://x", apiVersion = "60.0", username = "u@x.com" },
      }) })
    end
    _G._session = nil
    Api.get_session("other_org", function(session)
      _G._session = session
    end)
    Util.silent_system_call = original_call
  ]])

  local session = child.lua_get([[_G._session]])
  eq(session.token, "tok")
  eq(session.username, "u@x.com")
end

return test_set
