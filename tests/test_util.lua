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

return T
