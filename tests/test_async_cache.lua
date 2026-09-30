local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local eq = helpers.expect.equality
local new_set = MiniTest.new_set

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[Cache = require('sf.sub.async_cache')]])
    end,
    post_once = child.stop,
  },
})

T["get()"] = new_set()

T["get()"]["spawns once for two concurrent callers of the same key (coalescing)"] = function()
  child.lua([[
    _G.spawn_count = 0
    local pending
    C = Cache.new({
      fetch = function(_, cb)
        _G.spawn_count = _G.spawn_count + 1
        pending = cb -- deferred: don't resolve yet, so both calls below overlap in flight
      end,
    })
    _G.results = {}
    C:get("k", function(result) table.insert(_G.results, result) end)
    C:get("k", function(result) table.insert(_G.results, result) end)
    pending("data")
  ]])

  eq(child.lua_get([[_G.spawn_count]]), 1)
  eq(child.lua_get([[_G.results]]), { "data", "data" })
end

T["get()"]["ttl_seconds = 0 (default): never serves a stale result, always refetches once idle"] = function()
  child.lua([[
    _G.spawn_count = 0
    C = Cache.new({
      fetch = function(_, cb)
        _G.spawn_count = _G.spawn_count + 1
        cb(_G.spawn_count) -- resolves synchronously
      end,
    })
    C:get("k", function() end)
    C:get("k", function() end) -- first call already resolved and cleared -- must spawn again
  ]])

  eq(child.lua_get([[_G.spawn_count]]), 2)
end

T["get()"]["ttl_seconds > 0: a repeat call within the window is served from cache, no refetch"] = function()
  child.lua([[
    _G.spawn_count = 0
    C = Cache.new({
      ttl_seconds = 300,
      fetch = function(_, cb)
        _G.spawn_count = _G.spawn_count + 1
        cb("v" .. _G.spawn_count)
      end,
    })
    _G.results = {}
    C:get("k", function(result) table.insert(_G.results, result) end)
    C:get("k", function(result) table.insert(_G.results, result) end)
  ]])

  eq(child.lua_get([[_G.spawn_count]]), 1)
  eq(child.lua_get([[_G.results]]), { "v1", "v1" })
end

T["get()"]["errors are never cached: the next call re-spawns regardless of ttl"] = function()
  child.lua([[
    _G.spawn_count = 0
    C = Cache.new({
      ttl_seconds = 300,
      fetch = function(_, cb)
        _G.spawn_count = _G.spawn_count + 1
        if _G.spawn_count == 1 then
          cb(nil, "boom")
        else
          cb("ok", nil)
        end
      end,
    })
    _G.results = {}
    C:get("k", function(result, err) table.insert(_G.results, { result = result, err = err }) end)
    C:get("k", function(result, err) table.insert(_G.results, { result = result, err = err }) end)
  ]])

  eq(child.lua_get([[_G.spawn_count]]), 2)
  local results = child.lua_get([[_G.results]])
  eq(results[1].err, "boom")
  eq(results[2].result, "ok")
end

T["get()"]["different keys never coalesce onto each other"] = function()
  child.lua([[
    _G.spawn_count = 0
    C = Cache.new({
      fetch = function(_, cb)
        _G.spawn_count = _G.spawn_count + 1
        cb(_G.spawn_count)
      end,
    })
    C:get("a", function() end)
    C:get("b", function() end)
  ]])

  eq(child.lua_get([[_G.spawn_count]]), 2)
end

T["invalidate()"] = new_set()

T["invalidate()"]["clears one key so the next get() re-spawns"] = function()
  child.lua([[
    _G.spawn_count = 0
    C = Cache.new({
      ttl_seconds = 300,
      fetch = function(_, cb)
        _G.spawn_count = _G.spawn_count + 1
        cb("v")
      end,
    })
    C:get("a", function() end)
    C:invalidate("a")
    C:get("a", function() end)
  ]])

  eq(child.lua_get([[_G.spawn_count]]), 2)
end

T["invalidate()"]["with no key clears every entry"] = function()
  child.lua([[
    _G.spawn_count = 0
    C = Cache.new({
      ttl_seconds = 300,
      fetch = function(_, cb)
        _G.spawn_count = _G.spawn_count + 1
        cb("v")
      end,
    })
    C:get("a", function() end)
    C:get("b", function() end)
    C:invalidate()
    C:get("a", function() end)
    C:get("b", function() end)
  ]])

  eq(child.lua_get([[_G.spawn_count]]), 4)
end

return T
