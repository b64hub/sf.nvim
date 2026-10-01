local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local eq = helpers.expect.equality
local new_set = MiniTest.new_set

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.sf_setup()
      child.lua([[
        Debug = require("sf.debug")
        Api = require("sf.sub.rest_api")
        H = Debug.__test
      ]])
    end,
    post_once = child.stop,
  },
})

T["upsert_trace_flag"] = new_set()

T["upsert_trace_flag"]["creates a new TraceFlag when the user has none yet"] = function()
  child.lua([[
    Api.query = function(_, _, cb) cb({}, nil) end
    Api.update = function() error("update should not be called when there is no existing record") end
    Api.create = function(_, _, fields, cb)
      _G._create_fields = fields
      cb("newId", nil)
    end

    H.upsert_trace_flag({}, "005user", "debugLevelId", 60, function(ok)
      _G._ok = ok
    end)
  ]])

  eq(child.lua_get("_G._ok"), true)
  eq(child.lua_get("_G._create_fields.TracedEntityId"), "005user")
  eq(child.lua_get("_G._create_fields.DebugLevelId"), "debugLevelId")
end

T["upsert_trace_flag"]["renews (updates) an existing but expired TraceFlag instead of creating a new one"] = function()
  child.lua([[
    Api.query = function(_, _, cb)
      cb({ { Id = "existingId", ExpirationDate = "2000-01-01T00:00:00.000+0000" } }, nil)
    end
    Api.update = function(_, sobject, id, fields, cb)
      _G._update_sobject = sobject
      _G._update_id = id
      _G._update_fields = fields
      cb(true, nil)
    end
    Api.create = function() error("create should not be called for an already-existing record") end

    H.upsert_trace_flag({}, "005user", "debugLevelId", 60, function(ok)
      _G._ok = ok
    end)
  ]])

  eq(child.lua_get("_G._ok"), true)
  eq(child.lua_get("_G._update_sobject"), "TraceFlag")
  eq(child.lua_get("_G._update_id"), "existingId")
  eq(child.lua_get("_G._update_fields.DebugLevelId"), "debugLevelId")
end

T["upsert_trace_flag"]["renews (updates) an existing still-active TraceFlag too, rather than only expired ones"] = function()
  child.lua([[
    Api.query = function(_, _, cb)
      cb({ { Id = "activeId", ExpirationDate = os.date("!%Y-%m-%dT%H:%M:%S.000+0000", os.time() + 3600) } }, nil)
    end
    Api.update = function(_, _, id, _, cb)
      _G._update_id = id
      cb(true, nil)
    end
    Api.create = function() error("create should not be called for an already-existing record") end

    H.upsert_trace_flag({}, "005user", "debugLevelId", 60, function(ok)
      _G._ok = ok
    end)
  ]])

  eq(child.lua_get("_G._ok"), true)
  eq(child.lua_get("_G._update_id"), "activeId")
end

T["upsert_trace_flag"]["propagates a query failure without creating or updating"] = function()
  child.lua([[
    Api.query = function(_, _, cb) cb(nil, "boom") end
    Api.update = function() error("update should not be called on query failure") end
    Api.create = function() error("create should not be called on query failure") end

    H.upsert_trace_flag({}, "005user", "debugLevelId", 60, function(ok, err)
      _G._ok = ok
      _G._err = err
    end)
  ]])

  eq(child.lua_get("_G._ok"), false)
  eq(child.lua_get("_G._err"), "boom")
end

return T
