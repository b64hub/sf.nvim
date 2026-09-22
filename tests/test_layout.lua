local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local expect, eq = MiniTest.expect, MiniTest.expect.equality
local new_set = MiniTest.new_set

local test_set = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[layout = require("sf.ui.layout")]])
    end,
    post_once = child.stop,
  },
})

test_set["float_geometry_pair: with default left_ratio (0.3)"] = function()
  -- Set a known viewport: 100 columns, 50 lines
  child.lua([[vim.o.columns = 100; vim.o.lines = 50]])
  local pair = child.lua_get([[
    layout.float_geometry_pair({ position = "center", width = 0.8, height = 0.6 })
  ]])

  -- Outer geometry for 0.8 of 100 cols = 80, minus 2 border cells = 78 content
  -- Left width = floor((78 - 2) * 0.3) = floor(22.8) = 22
  -- Right width = 78 - 2 - 22 = 54
  eq(pair.left.width, 22)
  eq(pair.right.width, 54)

  -- They should share row and height
  eq(pair.left.row, pair.right.row)
  eq(pair.left.height, pair.right.height)
end

test_set["float_geometry_pair: left and right do not overlap"] = function()
  child.lua([[vim.o.columns = 100; vim.o.lines = 50]])
  local pair = child.lua_get([[
    layout.float_geometry_pair({ position = "center", width = 0.8, height = 0.6 })
  ]])

  -- Left box (with border): col to col + width + 2
  -- Right box (with border) starts at: col + width + 2
  -- So left's rightmost cell + border: left.col + left.width + 2
  -- Right's leftmost cell: right.col
  -- They should not overlap: left.col + left.width + 2 <= right.col
  local left_right_edge = pair.left.col + pair.left.width + 2
  eq(left_right_edge <= pair.right.col, true)
end

test_set["float_geometry_pair: fit within screen columns"] = function()
  child.lua([[vim.o.columns = 100; vim.o.lines = 50]])
  local pair = child.lua_get([[
    layout.float_geometry_pair({ position = "center", width = 0.8, height = 0.6 })
  ]])

  -- Right box's rightmost cell (with border): col + width + 2
  local right_right_edge = pair.right.col + pair.right.width + 2
  eq(right_right_edge <= child.o.columns, true)
end

test_set["float_geometry_pair: custom left_ratio"] = function()
  child.lua([[vim.o.columns = 100; vim.o.lines = 50]])
  local pair = child.lua_get([[
    layout.float_geometry_pair({ position = "center", width = 0.8, height = 0.6, left_ratio = 0.4 })
  ]])

  -- Outer: 80 cols - 2 border = 78 content
  -- Left width = floor((78 - 2) * 0.4) = floor(30.4) = 30
  -- Right width = 78 - 2 - 30 = 46
  eq(pair.left.width, 30)
  eq(pair.right.width, 46)
end

test_set["float_geometry_pair: small viewport"] = function()
  child.lua([[vim.o.columns = 20; vim.o.lines = 10]])
  local pair = child.lua_get([[
    layout.float_geometry_pair({ position = "center", width = 0.9, height = 0.9, left_ratio = 0.3 })
  ]])

  -- width = 0.9 is a fraction (not an absolute cell count -- resolve()
  -- treats v >= 1 as an absolute cell count, per float_geometry's existing
  -- contract, so this deliberately stays < 1).
  -- Outer: floor(20 * 0.9) = 18, minus 2 border = 16 content
  -- Left = floor((16 - 2) * 0.3) = floor(4.2) = 4
  -- Right = 16 - 2 - 4 = 10
  eq(pair.left.width, 4)
  eq(pair.right.width, 10)

  -- Still no overlap
  local left_right_edge = pair.left.col + pair.left.width + 2
  eq(left_right_edge <= pair.right.col, true)
end

test_set["float_geometry_pair: respects position and margins"] = function()
  child.lua([[vim.o.columns = 100; vim.o.lines = 50]])
  local pair = child.lua_get([[
    layout.float_geometry_pair({ position = "top_left", width = 0.5, height = 0.5, margin = { row = 2, col = 3 } })
  ]])

  -- Both should use the col/row from the outer geometry
  eq(pair.left.col, pair.right.col - pair.left.width - 2)
  eq(pair.left.row, pair.right.row)
end

return test_set
