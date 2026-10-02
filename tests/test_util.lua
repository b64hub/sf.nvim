local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local eq = MiniTest.expect.equality
local new_set = MiniTest.new_set

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[util = require('sf.util')]])
    end,
    post_once = child.stop,
  },
})

T["format_bytes"] = new_set()

T["format_bytes"]["bytes"] = function()
  eq(child.lua_get([[util.format_bytes(512)]]), "512 B")
end

T["format_bytes"]["kilobytes"] = function()
  eq(child.lua_get([[util.format_bytes(49356)]]), "48.2 KB")
end

T["format_bytes"]["megabytes"] = function()
  eq(child.lua_get([[util.format_bytes(3251634)]]), "3.1 MB")
end

T["cache json"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        TMP_CACHE_DIR = vim.fn.tempname() .. "/"
        vim.fn.mkdir(TMP_CACHE_DIR, "p")
        util.get_cache_dir = function() return TMP_CACHE_DIR end
      ]])
    end,
  },
})

T["cache json"]["write then read round-trips a table"] = function()
  child.lua([[util.write_cache_json("orgs.json", { { alias = "one" }, { alias = "two" } })]])

  local result = child.lua_get([[util.read_cache_json("orgs.json")]])
  eq(#result, 2)
  eq(result[1].alias, "one")
  eq(result[2].alias, "two")
end

T["cache json"]["read returns nil on a cache miss"] = function()
  eq(child.lua_get([[util.read_cache_json("never_written.json") == nil]]), true)
end

T["cache json"]["read returns nil (not an error) when the cache dir can't be resolved"] = function()
  child.lua([[util.get_cache_dir = function() error("not in a sf project folder") end]])
  eq(child.lua_get([[util.read_cache_json("orgs.json") == nil]]), true)
end

T["cache json"]["write is a silent no-op when the cache dir can't be resolved"] = function()
  child.lua([[util.get_cache_dir = function() error("not in a sf project folder") end]])
  -- Must not throw -- a cache write failure should never break the caller.
  child.lua([[util.write_cache_json("orgs.json", { 1, 2, 3 })]])
end

T["cache json"]["write creates a nested parent directory (e.g. a file-per-org layout)"] = function()
  child.lua([[util.write_cache_json("orgs/myalias.json", { details = true })]])
  eq(child.lua_get([[util.read_cache_json("orgs/myalias.json")]]), { details = true })
end

T["cache json"]["a write never leaves a stray .tmp file behind"] = function()
  child.lua([[util.write_cache_json("orgs.json", { 1, 2, 3 })]])
  eq(child.lua_get([[vim.fn.filereadable(TMP_CACHE_DIR .. "orgs.json.tmp")]]), 0)
end

T["cache text"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        TMP_CACHE_DIR = vim.fn.tempname() .. "/"
        vim.fn.mkdir(TMP_CACHE_DIR, "p")
        util.get_cache_dir = function() return TMP_CACHE_DIR end
      ]])
    end,
  },
})

T["cache text"]["write then read round-trips a plain string, not JSON-encoded"] = function()
  child.lua([[util.write_cache_text("debug/last_log.txt", "/tmp/foo.log")]])
  eq(child.lua_get([[util.read_cache_text("debug/last_log.txt")]]), "/tmp/foo.log")
end

T["cache text"]["read returns nil on a cache miss"] = function()
  eq(child.lua_get([[util.read_cache_text("never_written.txt") == nil]]), true)
end

T["delete_cache_file"] = new_set({
  hooks = {
    pre_case = function()
      child.lua([[
        TMP_CACHE_DIR = vim.fn.tempname() .. "/"
        vim.fn.mkdir(TMP_CACHE_DIR, "p")
        util.get_cache_dir = function() return TMP_CACHE_DIR end
      ]])
    end,
  },
})

T["delete_cache_file"]["removes a file written via write_cache_json"] = function()
  child.lua([[
    util.write_cache_json("orgs.json", { 1 })
    util.delete_cache_file("orgs.json")
  ]])
  eq(child.lua_get([[util.read_cache_json("orgs.json") == nil]]), true)
end

T["delete_cache_file"]["silent no-op when the file never existed"] = function()
  child.lua([[util.delete_cache_file("never_written.json")]])
end

return T
