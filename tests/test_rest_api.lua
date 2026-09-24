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
        -- get_org_display's TTL/coalescing cache is module-local state that
        -- otherwise survives across test cases in this shared child Neovim
        -- (several cases below never invoke their mock's callback at all,
        -- which would leave a permanently "fetching" cache entry that then
        -- silently swallows a later case's real call for the same alias).
        Api.invalidate_org_display()
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

-- Regression: a real "unmanaged package" InstalledSubscriberPackage query
-- returns `NamespacePrefix: null`. vim.json.decode's default behaviour
-- turns JSON null into `vim.NIL`, a truthy userdata sentinel -- so
-- `record.NamespacePrefix or "unmanaged"` silently kept `vim.NIL` instead
-- of falling back, and org_view.render_columns crashed on `#cell` further
-- downstream ("attempt to get length of a userdata value"). Both
-- cli_json_call and curl_json must decode with `luanil = { object = true }`
-- so a null field comes back as real Lua `nil`, the only value every
-- `field or default` call site actually guards against.
test_set["cli_json_call (via get_session): decodes JSON null as Lua nil, not vim.NIL"] = function()
  child.lua([[
    local original_call = Util.silent_system_call
    Util.silent_system_call = function(_, _, _, cb)
      cb({ stdout = vim.json.encode({
        result = { accessToken = "tok", instanceUrl = "https://x", apiVersion = "60.0", username = vim.NIL },
      }) })
    end
    _G._session = nil
    Api.get_session("other_org", function(session)
      _G._session = session
    end)
    Util.silent_system_call = original_call
  ]])

  eq(child.lua_get([[_G._session.username == nil]]), true)
end

test_set["curl_json: decodes JSON null as Lua nil, not vim.NIL"] = function()
  child.lua([[
    local original_call = Util.silent_system_call
    Util.silent_system_call = function(_, _, _, cb)
      local body = vim.json.encode({
        records = { { Name = "Pkg", NamespacePrefix = vim.NIL } },
      })
      cb({ stdout = body .. "\nHTTPSTATUS:200" })
    end
    _G._decoded = nil
    Api.curl_json({}, function(decoded)
      _G._decoded = decoded
    end)
    Util.silent_system_call = original_call
  ]])

  eq(child.lua_get([[_G._decoded.records[1].NamespacePrefix == nil]]), true)
  eq(child.lua_get([[_G._decoded.records[1].Name]]), "Pkg")
end

test_set["get_org_display: two calls for the same alias spawn silent_system_call once (coalescing)"] = function()
  child.lua([[
    local call_count = 0
    local original_call = Util.silent_system_call
    Util.silent_system_call = function(cmd, _, _, cb)
      call_count = call_count + 1
      cb({ stdout = vim.json.encode({
        result = { accessToken = "tok", instanceUrl = "https://x", apiVersion = "60.0", username = "u@x.com" },
      }) })
    end
    
    _G._results = {}
    Api.get_org_display("my_org", function(result, err)
      table.insert(_G._results, { result = result, err = err })
    end)
    Api.get_org_display("my_org", function(result, err)
      table.insert(_G._results, { result = result, err = err })
    end)
    
    Util.silent_system_call = original_call
    _G._call_count = call_count
  ]])

  eq(child.lua_get([[_G._call_count]]), 1)
  local results = child.lua_get([[_G._results]])
  eq(#results, 2)
  eq(results[1].result.accessToken, "tok")
  eq(results[2].result.accessToken, "tok")
end

test_set["get_org_display: third call after invalidate spawns again"] = function()
  child.lua([[
    local call_count = 0
    local original_call = Util.silent_system_call
    Util.silent_system_call = function(cmd, _, _, cb)
      call_count = call_count + 1
      cb({ stdout = vim.json.encode({
        result = { accessToken = "tok", instanceUrl = "https://x", apiVersion = "60.0", username = "u@x.com" },
      }) })
    end
    
    _G._results = {}
    Api.get_org_display("my_org", function(result, err)
      table.insert(_G._results, { result = result, err = err })
    end)
    Api.get_org_display("my_org", function(result, err)
      table.insert(_G._results, { result = result, err = err })
    end)
    
    Api.invalidate_org_display("my_org")
    
    Api.get_org_display("my_org", function(result, err)
      table.insert(_G._results, { result = result, err = err })
    end)
    
    Util.silent_system_call = original_call
    _G._call_count = call_count
  ]])

  eq(child.lua_get([[_G._call_count]]), 2)
  local results = child.lua_get([[_G._results]])
  eq(#results, 3)
end

test_set["get_org_display: errored call is not cached; next call re-spawns"] = function()
  child.lua([[
    local call_count = 0
    local original_call = Util.silent_system_call
    Util.silent_system_call = function(cmd, _, _, cb)
      call_count = call_count + 1
      if call_count == 1 then
        -- First call fails (simulated by malformed output)
        cb({ stdout = "not valid json" })
      else
        -- Second call succeeds
        cb({ stdout = vim.json.encode({
          result = { accessToken = "tok", instanceUrl = "https://x", apiVersion = "60.0", username = "u@x.com" },
        }) })
      end
    end
    
    _G._results = {}
    Api.get_org_display("my_org", function(result, err)
      table.insert(_G._results, { result = result, err = err })
    end)
    Api.get_org_display("my_org", function(result, err)
      table.insert(_G._results, { result = result, err = err })
    end)
    
    Util.silent_system_call = original_call
    _G._call_count = call_count
  ]])

  -- The mock resolves synchronously, so these two get_org_display calls
  -- never actually overlap in flight: the first fully completes (spawn,
  -- cache-miss error, drain its one waiter) before the second even starts.
  -- One result per call, not one-per-call-times-two.
  eq(child.lua_get([[_G._call_count]]), 2)
  local results = child.lua_get([[_G._results]])
  eq(#results, 2)
  eq(results[1].err ~= nil, true) -- first call: parse failure, not cached
  eq(results[2].result.accessToken, "tok") -- second call: fresh spawn succeeds
end

test_set["get_session now uses cached get_org_display"] = function()
  child.lua([[
    local call_count = 0
    local original_call = Util.silent_system_call
    Util.silent_system_call = function(cmd, _, _, cb)
      call_count = call_count + 1
      cb({ stdout = vim.json.encode({
        result = { accessToken = "tok", instanceUrl = "https://x", apiVersion = "60.0", username = "u@x.com" },
      }) })
    end
    
    _G._sessions = {}
    Api.get_session("my_org", function(session)
      table.insert(_G._sessions, session)
    end)
    Api.get_session("my_org", function(session)
      table.insert(_G._sessions, session)
    end)
    
    Util.silent_system_call = original_call
    _G._call_count = call_count
  ]])

  eq(child.lua_get([[_G._call_count]]), 1)
  local sessions = child.lua_get([[_G._sessions]])
  eq(#sessions, 2)
  eq(sessions[1].token, "tok")
  eq(sessions[2].token, "tok")
end

return test_set