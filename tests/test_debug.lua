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
  -- StartDate must be reset to now on renewal: Salesforce caps a TraceFlag
  -- at 24h from its StartDate, so renewing while StartDate is still the
  -- old (already >24h gone) value made ExpirationDate updates fail with
  -- "Trace flags can be active for up to 24 hours..." even for a brand
  -- new, well-within-24h ExpirationDate.
  local start_date = child.lua_get("_G._update_fields.StartDate")
  eq(type(start_date), "string")
  eq(start_date == "2000-01-01T00:00:00.000+0000", false)
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

T["find_or_create_debug_level"] = new_set()

T["find_or_create_debug_level"]["creates a new DebugLevel when none exists"] = function()
  child.lua([[
    Api.query = function(_, _, cb) cb({}, nil) end
    Api.update = function() error("update should not be called when there is no existing record") end
    Api.create = function(_, _, fields, cb)
      _G._create_fields = fields
      cb("newId", nil)
    end

    H.find_or_create_debug_level({}, function(id, err)
      _G._id, _G._err = id, err
    end)
  ]])

  eq(child.lua_get("_G._id"), "newId")
  eq(child.lua_get("_G._create_fields.ApexCode"), "FINEST")
  eq(child.lua_get("_G._create_fields.Visualforce"), "FINER")
end

T["find_or_create_debug_level"]["reuses an existing DebugLevel already at the required levels"] = function()
  child.lua([[
    Api.query = function(_, _, cb)
      cb({ { Id = "existingId", ApexCode = "FINEST", Visualforce = "FINER" } }, nil)
    end
    Api.update = function() error("update should not be called when levels already match") end
    Api.create = function() error("create should not be called for an already-existing record") end

    H.find_or_create_debug_level({}, function(id, err)
      _G._id, _G._err = id, err
    end)
  ]])

  eq(child.lua_get("_G._id"), "existingId")
end

T["find_or_create_debug_level"]["raises an existing but insufficient DebugLevel to the required levels"] = function()
  child.lua([[
    Api.query = function(_, _, cb)
      cb({ { Id = "existingId", ApexCode = "DEBUG", Visualforce = "FINE" } }, nil)
    end
    Api.update = function(_, sobject, id, fields, cb)
      _G._update_sobject, _G._update_id, _G._update_fields = sobject, id, fields
      cb(true, nil)
    end
    Api.create = function() error("create should not be called for an already-existing record") end

    H.find_or_create_debug_level({}, function(id, err)
      _G._id, _G._err = id, err
    end)
  ]])

  eq(child.lua_get("_G._id"), "existingId")
  eq(child.lua_get("_G._update_sobject"), "DebugLevel")
  eq(child.lua_get("_G._update_id"), "existingId")
  eq(child.lua_get("_G._update_fields.ApexCode"), "FINEST")
  eq(child.lua_get("_G._update_fields.Visualforce"), "FINER")
end

T["resolve_log_file"] = new_set()

T["resolve_log_file"]["passes a config through unchanged when logFileContents is already set"] = function()
  child.lua([[
    _G._resolved, _G._err = H.resolve_log_file({ logFileContents = "abc" })
  ]])

  eq(child.lua_get("_G._err"), vim.NIL)
  eq(child.lua_get("_G._resolved.logFileContents"), "abc")
end

T["resolve_log_file"]["reads a `logFile` path into logFileContents/logFilePath/logFileName"] = function()
  child.lua([[
    local path = vim.fn.tempname() .. ".log"
    vim.fn.writefile({ "line one", "line two" }, path)
    _G._resolved, _G._err = H.resolve_log_file({ logFile = path })
    _G._path = path
  ]])

  eq(child.lua_get("_G._err"), vim.NIL)
  eq(child.lua_get("_G._resolved.logFileContents"), "line one\nline two")
  eq(child.lua_get("_G._resolved.logFilePath"), child.lua_get("_G._path"))
  eq(child.lua_get("_G._resolved.logFile"), vim.NIL)
end

T["resolve_log_file"]["errors on an empty log file instead of letting the adapter crash"] = function()
  child.lua([[
    local path = vim.fn.tempname() .. ".log"
    vim.fn.writefile({}, path)
    _G._resolved, _G._err = H.resolve_log_file({ logFile = path })
  ]])

  eq(child.lua_get("_G._resolved"), vim.NIL)
  eq(child.lua_get("_G._err") ~= vim.NIL, true)
end

T["resolve_log_file"]["errors when neither logFileContents nor logFile is set"] = function()
  child.lua([[
    _G._resolved, _G._err = H.resolve_log_file({})
  ]])

  eq(child.lua_get("_G._resolved"), vim.NIL)
  eq(child.lua_get("_G._err") ~= vim.NIL, true)
end

return T
