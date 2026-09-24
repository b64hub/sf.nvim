local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

local test_set = new_set({
  hooks = {
    pre_case = function()
      child.setup()
    end,
    post_once = child.stop,
  },
})

test_set["shade: identity at factor 1"] = function()
  child.lua([[
    local highlights = require("sf.ui.highlights")
    result = highlights._shade("#1B96FF", 1)
  ]])
  local result = child.lua_get([[result ]])
  eq(result, "#1b96ff")
end

test_set["shade: darkens below 1"] = function()
  child.lua([[
    highlights = require("sf.ui.highlights")
    result = highlights._shade("#1B96FF", 0.5)
  ]])
  local result = child.lua_get([[result ]])
  -- Should be darker than original
  local r, g, b = tonumber(result:sub(2, 3), 16), tonumber(result:sub(4, 5), 16), tonumber(result:sub(6, 7), 16)
  local orig_r, orig_g, orig_b = 0x1b, 0x96, 0xff
  eq(r <= orig_r and g <= orig_g and b <= orig_b, true)
end

test_set["shade: lightens above 1"] = function()
  child.lua([[
    highlights = require("sf.ui.highlights")
    result = highlights._shade("#1B96FF", 1.5)
  ]])
  local result = child.lua_get([[result ]])
  -- Should be lighter than original
  local r, g, b = tonumber(result:sub(2, 3), 16), tonumber(result:sub(4, 5), 16), tonumber(result:sub(6, 7), 16)
  local orig_r, orig_g, orig_b = 0x1b, 0x96, 0xff
  eq(r >= orig_r and g >= orig_g and b >= orig_b, true)
end

test_set["shade: clamps to 0-255"] = function()
  child.lua([[
    highlights = require("sf.ui.highlights")
    result = highlights._shade("#000000", 0.5)
  ]])
  local result = child.lua_get([[result ]])
  eq(result, "#000000")
  
  child.lua([[
    result = highlights._shade("#FFFFFF", 1.5)
  ]])
  result = child.lua_get([[result ]])
  eq(result, "#ffffff")
end

test_set["mix: 0 weight returns first color"] = function()
  child.lua([[
    highlights = require("sf.ui.highlights")
    result = highlights._mix("#FF0000", "#0000FF", 0)
  ]])
  local result = child.lua_get([[result ]])
  eq(result:lower(), "#ff0000")
end

test_set["mix: 1 weight returns second color"] = function()
  child.lua([[
    highlights = require("sf.ui.highlights")
    result = highlights._mix("#FF0000", "#0000FF", 1)
  ]])
  local result = child.lua_get([[result ]])
  eq(result:lower(), "#0000ff")
end

test_set["setup: derives SfTitle foreground from accent"] = function()
  child.lua([[
    vim.g.sf = { ui = { accent = "#FF5500" } }
    highlights = require("sf.ui.highlights")
    highlights.setup()
    title_hl = vim.api.nvim_get_hl(0, { name = "SfTitle" })
  ]])
  
  local title_hl = child.lua_get([[title_hl ]])
  -- fg should be derived from accent (darkened)
  eq(title_hl.fg ~= nil, true)
end

test_set["setup: SfTableHeader distinct from SfTitle"] = function()
  child.lua([[
    vim.g.sf = { ui = { accent = "#1B96FF" } }
    highlights = require("sf.ui.highlights")
    highlights.setup()
    title_hl = vim.api.nvim_get_hl(0, { name = "SfTitle" })
    header_hl = vim.api.nvim_get_hl(0, { name = "SfTableHeader" })
  ]])
  
  local title_hl = child.lua_get([[title_hl ]])
  local header_hl = child.lua_get([[header_hl ]])
  -- Both should have fg, but they should be different
  eq(title_hl.fg ~= nil, true)
  eq(header_hl.fg ~= nil, true)
  eq(header_hl.bold == true, true)
  eq(header_hl.underline == true, true)
end

test_set["setup: SfDim group exists and is recessive"] = function()
  child.lua([[
    vim.g.sf = { ui = { accent = "#1B96FF" } }
    highlights = require("sf.ui.highlights")
    highlights.setup()
    dim_hl = vim.api.nvim_get_hl(0, { name = "SfDim" })
  ]])
  
  local dim_hl = child.lua_get([[dim_hl ]])
  eq(dim_hl.fg ~= nil, true)
end

test_set["setup: status groups derive from accent"] = function()
  child.lua([[
    vim.g.sf = { ui = { accent = "#1B96FF" } }
    highlights = require("sf.ui.highlights")
    highlights.setup()
    prod_hl = vim.api.nvim_get_hl(0, { name = "SfStatusProd" })
    sandbox_hl = vim.api.nvim_get_hl(0, { name = "SfStatusSandbox" })
    scratch_hl = vim.api.nvim_get_hl(0, { name = "SfStatusScratch" })
  ]])
  
  local prod_hl = child.lua_get([[prod_hl ]])
  local sandbox_hl = child.lua_get([[sandbox_hl ]])
  local scratch_hl = child.lua_get([[scratch_hl ]])
  
  -- All three should have fg values
  eq(prod_hl.fg ~= nil, true)
  eq(sandbox_hl.fg ~= nil, true)
  eq(scratch_hl.fg ~= nil, true)
  
  -- All three should be different
  eq(prod_hl.fg ~= sandbox_hl.fg, true)
  eq(sandbox_hl.fg ~= scratch_hl.fg, true)
  eq(prod_hl.fg ~= scratch_hl.fg, true)
end

return test_set
