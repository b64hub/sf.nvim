local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

local test_set = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[org_view = require("sf.ui.org_view")]])
    end,
    post_once = child.stop,
  },
})

-- pad

test_set["pad: empty string to width"] = function()
  eq(child.lua_get([[org_view.pad("", 5)]]), "     ")
end

test_set["pad: partial fill"] = function()
  eq(child.lua_get([[org_view.pad("hi", 5)]]), "hi   ")
end

test_set["pad: exact width"] = function()
  eq(child.lua_get([[org_view.pad("hello", 5)]]), "hello")
end

test_set["pad: longer than width"] = function()
  eq(child.lua_get([[org_view.pad("toolong", 3)]]), "toolong")
end

test_set["pad: nil input"] = function()
  eq(child.lua_get([[org_view.pad(nil, 3)]]), "   ")
end

-- highlight_for

test_set["highlight_for: prod org"] = function()
  child.lua([[record = { is_prod = true, is_sandbox = false, is_scratch = false }]])
  eq(child.lua_get([[org_view.highlight_for(record)]]), "SfStatusProd")
end

test_set["highlight_for: sandbox org"] = function()
  child.lua([[record = { is_prod = false, is_sandbox = true, is_scratch = false }]])
  eq(child.lua_get([[org_view.highlight_for(record)]]), "SfStatusSandbox")
end

test_set["highlight_for: scratch org"] = function()
  child.lua([[record = { is_prod = false, is_sandbox = false, is_scratch = true }]])
  eq(child.lua_get([[org_view.highlight_for(record)]]), "SfStatusScratch")
end

test_set["highlight_for: generic org (no type set)"] = function()
  child.lua([[record = { is_prod = false, is_sandbox = false, is_scratch = false }]])
  eq(child.lua_get([[org_view.highlight_for(record)]]), "SfStatusOrg")
end

-- days_until

test_set["days_until: nil input"] = function()
  eq(child.lua_get([[org_view.days_until(nil, 1000000000)]]), vim.NIL)
end

test_set["days_until: empty string"] = function()
  eq(child.lua_get([[org_view.days_until("", 1000000000)]]), vim.NIL)
end

test_set["days_until: unparseable date"] = function()
  eq(child.lua_get([[org_view.days_until("not a date", 1000000000)]]), vim.NIL)
end

test_set["days_until: expired (past date)"] = function()
  -- now_timestamp 1000000000 = 2001-09-09 01:46:40 UTC; expiry the day before.
  eq(child.lua_get([[org_view.days_until("2001-09-08T00:00:00.000Z", 1000000000)]]), "expired")
end

test_set["days_until: today"] = function()
  eq(child.lua_get([[org_view.days_until("2001-09-09T00:00:00.000Z", 1000000000)]]), "today")
end

test_set["days_until: 6 days until expiry"] = function()
  eq(child.lua_get([[org_view.days_until("2001-09-15T00:00:00.000Z", 1000000000)]]), "6d")
end

test_set["days_until: 7 days until expiry (boundary, still short-form)"] = function()
  eq(child.lua_get([[org_view.days_until("2001-09-16T00:00:00.000Z", 1000000000)]]), "7d")
end

test_set["days_until: beyond the short-form window"] = function()
  eq(child.lua_get([[org_view.days_until("2001-09-17T00:00:00.000Z", 1000000000)]]), vim.NIL)
end

test_set["days_until: defaults now_timestamp to os.time()"] = function()
  -- Far enough out that it's nil regardless of exactly when this runs.
  -- `lua_get` prepends `return `, so the statement has to be set up via
  -- `lua()` first and only the final expression evaluated via `lua_get()`.
  child.lua([[far_future = os.date("%Y-%m-%d", os.time() + 100000 * 86400) .. "T00:00:00.000Z"]])
  local result = child.lua_get([[org_view.days_until(far_future)]])
  eq(result, vim.NIL)
end

-- render_list_lines

test_set["render_list_lines: marker - default target org only"] = function()
  child.lua([[
    records = {
      { alias = "org1", username = "u1", is_prod = true, is_default = true, is_default_devhub = false },
    }
  ]])
  local line = child.lua_get([[(org_view.render_list_lines(records))[1] ]])
  expect.match(line, "^\u{25CF} ")
end

test_set["render_list_lines: marker - default devhub only"] = function()
  child.lua([[
    records = {
      { alias = "devhub", username = "dh", is_prod = true, is_default = false, is_default_devhub = true },
    }
  ]])
  local line = child.lua_get([[(org_view.render_list_lines(records))[1] ]])
  expect.match(line, "^\u{25C6} ")
end

test_set["render_list_lines: marker - both default and devhub"] = function()
  child.lua([[
    records = {
      { alias = "both", username = "b", is_prod = true, is_default = true, is_default_devhub = true },
    }
  ]])
  local line = child.lua_get([[(org_view.render_list_lines(records))[1] ]])
  expect.match(line, "^\u{25C8} ")
end

test_set["render_list_lines: marker - neither"] = function()
  child.lua([[
    records = {
      { alias = "other", username = "o", is_prod = true, is_default = false, is_default_devhub = false },
    }
  ]])
  local line = child.lua_get([[(org_view.render_list_lines(records))[1] ]])
  eq(line:sub(1, 2), "  ")
end

test_set["render_list_lines: scratch expiry shown for near-term dates"] = function()
  child.lua([[
    records = {
      {
        alias = "scratch_soon",
        username = "u",
        is_scratch = true,
        is_default = false,
        is_default_devhub = false,
        expiration_date = os.date("%Y-%m-%d", os.time() + 2 * 86400) .. "T00:00:00.000Z",
      },
    }
  ]])
  local line = child.lua_get([[(org_view.render_list_lines(records))[1] ]])
  expect.match(line, "expires")
end

test_set["render_list_lines: scratch expiry hidden for far-future dates"] = function()
  child.lua([[
    records = {
      {
        alias = "scratch_far",
        username = "u",
        is_scratch = true,
        is_default = false,
        is_default_devhub = false,
        expiration_date = os.date("%Y-%m-%d", os.time() + 100000 * 86400) .. "T00:00:00.000Z",
      },
    }
  ]])
  local line = child.lua_get([[(org_view.render_list_lines(records))[1] ]])
  expect.no_match(line, "expires")
end

test_set["render_list_lines: alias column aligned across rows"] = function()
  child.lua([[
    records = {
      { alias = "a", username = "long_username_here", is_prod = true, is_default = false, is_default_devhub = false },
      { alias = "longer_alias", username = "u", is_sandbox = true, is_default = false, is_default_devhub = false },
    }
  ]])
  local lines = child.lua_get([[org_view.render_list_lines(records)]])
  eq(#lines, 2)
  -- Alias column is padded to the longest alias ("longer_alias" = 12 chars),
  -- so the username column must start at the same byte offset on both rows.
  eq(lines[1]:find("long_username_here", 1, true), lines[2]:find("u", 1, true))
end

return test_set
