local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local eq = MiniTest.expect.equality
local new_set = MiniTest.new_set

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[state = require('sf.state')]])
      child.lua([[cache = state.__test]])
    end,
    post_once = child.stop,
  },
})

T["set_target_org"] = new_set()

T["set_target_org"]["clears cached trace flags on org change"] = function()
  child.lua([[cache.trace_flags = { { id = "1", log_type = "DEVELOPER_LOG", expires_at_epoch = os.time() + 60 } }]])
  child.lua([[state.set_target_org("some-other-org")]])
  eq(child.lua_get([[state.get_trace_flags()]]), {})
end

T["set_target_org"]["does not clear trace flags when org is unchanged"] = function()
  child.lua([[state.set_target_org("same-org")]])
  child.lua([[cache.trace_flags = { { id = "1", log_type = "DEVELOPER_LOG", expires_at_epoch = os.time() + 60 } }]])
  child.lua([[state.set_target_org("same-org")]])
  eq(#child.lua_get([[state.get_trace_flags()]]), 1)
end

return T
