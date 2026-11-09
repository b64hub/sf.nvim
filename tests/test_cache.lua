local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local eq = MiniTest.expect.equality
local new_set = MiniTest.new_set

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[Cache = require('sf.cache')]])
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

T["sanitize_filename()"] = new_set()

T["sanitize_filename()"]["replaces anything outside word chars/-/_/. with an underscore"] = function()
  eq(child.lua_get([[Cache.sanitize_filename("my/org")]]), "my_org")
  eq(child.lua_get([[Cache.sanitize_filename("../../etc")]]), ".._.._etc")
  eq(child.lua_get([[Cache.sanitize_filename("my-org_1.sandbox")]]), "my-org_1.sandbox")
end

T["disk_store"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        TMP_CACHE_DIR = vim.fn.tempname() .. "/"
        vim.fn.mkdir(TMP_CACHE_DIR, "p")
        util = require("sf.util")
        util.get_cache_dir = function() return TMP_CACHE_DIR end
      ]])
    end,
  },
})

T["disk_store"]["set() then get() round-trips a sub-keyed value"] = function()
  child.lua([[
    Store = Cache.disk_store(function(key)
      local alias, subkey = key:match("^(.*):([^:]+)$")
      return "orgs/" .. alias .. ".json", subkey
    end)
    Store:set("myorg:details", { foo = "bar" })
  ]])

  eq(child.lua_get([[Store:get("myorg:details")]]), { foo = "bar" })
  -- Written through to disk, not only held in memory.
  local on_disk = child.lua_get([[util.read_cache_json("orgs/myorg.json")]])
  eq(on_disk.details, { foo = "bar" })
end

T["disk_store"]["two sub-keys sharing one file never clobber each other (the prefetch race)"] = function()
  child.lua([[
    Store = Cache.disk_store(function(key)
      local alias, subkey = key:match("^(.*):([^:]+)$")
      return "orgs/" .. alias .. ".json", subkey
    end)
    -- Simulates org_dashboard's prefetch_record_views: several views for
    -- the same org settle back-to-back, each only knowing its own result.
    Store:set("myorg:details", { d = 1 })
    Store:set("myorg:limits", { l = 2 })
    Store:set("myorg:packages", { p = 3 })
  ]])

  local on_disk = child.lua_get([[util.read_cache_json("orgs/myorg.json")]])
  eq(on_disk.details, { d = 1 })
  eq(on_disk.limits, { l = 2 })
  eq(on_disk.packages, { p = 3 })
end

T["disk_store"]["get() is a cache miss (nil) before anything is ever set"] = function()
  child.lua([[
    Store = Cache.disk_store(function(key)
      return "orgs/" .. key .. ".json", nil
    end)
  ]])
  eq(child.lua_get([[Store:get("never_written") == nil]]), true)
end

T["disk_store"]["invalidate() drops only that sub-key, dumping the rest back unchanged"] = function()
  child.lua([[
    Store = Cache.disk_store(function(key)
      local alias, subkey = key:match("^(.*):([^:]+)$")
      return "orgs/" .. alias .. ".json", subkey
    end)
    Store:set("myorg:details", { d = 1 })
    Store:set("myorg:limits", { l = 2 })
    Store:invalidate("myorg:details")
  ]])

  eq(child.lua_get([[Store:get("myorg:details") == nil]]), true)
  eq(child.lua_get([[Store:get("myorg:limits")]]), { l = 2 })
end

T["disk_store"]["delete_file() removes the whole file, e.g. when an org is deleted"] = function()
  child.lua([[
    Store = Cache.disk_store(function(key)
      local alias, subkey = key:match("^(.*):([^:]+)$")
      return "orgs/" .. alias .. ".json", subkey
    end)
    Store:set("myorg:details", { d = 1 })
    Store:delete_file("orgs/myorg.json")
  ]])

  eq(child.lua_get([[Store:get("myorg:details") == nil]]), true)
  eq(child.lua_get([[vim.fn.filereadable(TMP_CACHE_DIR .. "orgs/myorg.json")]]), 0)
end

T["disk_store"]["nil subkey: the file IS the value, e.g. a single-key last-known-good snapshot"] = function()
  child.lua([[
    Store = Cache.disk_store(function(_)
      return "orgs.json", nil
    end)
    Store:set("orgs", { { alias = "one" }, { alias = "two" } })
  ]])

  eq(child.lua_get([[Store:get("orgs")]]), { { alias = "one" }, { alias = "two" } })
  eq(child.lua_get([[util.read_cache_json("orgs.json")]]), { { alias = "one" }, { alias = "two" } })
end

return T
