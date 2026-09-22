local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local eq = helpers.expect.equality
local new_set = MiniTest.new_set

local test_set = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[org_status = require("sf.sub.org_status")]])
    end,
    post_once = child.stop,
  },
})

test_set["parse_instance_status: healthy status"] = function()
  child.lua([[
    decoded = {
      status = "OK",
      Incidents = {},
    }
  ]])
  local result = child.lua_get([[org_status.parse_instance_status(decoded)]])
  eq(result.status, "OK")
  eq(result.message, nil)
  eq(result.incidents, {})
end

test_set["parse_instance_status: degraded status with incidents"] = function()
  child.lua([[
    decoded = {
      status = "MAJOR_INCIDENT",
      Incidents = {
        { id = "INC1", message = "Some functionality is degraded", severity = "major" },
        { id = "INC2", message = "Another issue", severity = "minor" },
      },
    }
  ]])
  local result = child.lua_get([[org_status.parse_instance_status(decoded)]])
  eq(result.status, "MAJOR_INCIDENT")
  eq(result.message, "Some functionality is degraded")
  eq(#result.incidents, 2)
  eq(result.incidents[1].id, "INC1")
  eq(result.incidents[2].severity, "minor")
end

test_set["parse_instance_status: malformed/unexpected shape does not error"] = function()
  child.lua([[decoded = { unexpected = "shape", Incidents = "not-a-table" }]])
  local result = child.lua_get([[org_status.parse_instance_status(decoded)]])
  eq(result.status, "unknown")
  eq(result.message, nil)
  eq(result.incidents, {})
end

test_set["parse_instance_status: nil input does not error"] = function()
  local result = child.lua_get([[org_status.parse_instance_status(nil)]])
  eq(result.status, "unknown")
  eq(result.incidents, {})
end

return test_set
