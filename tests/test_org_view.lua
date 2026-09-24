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

test_set["render_columns: ragged input aligns to widest cell per column"] = function()
  child.lua([[
    rows = {
      { cells = { "a", "bb", "ccc" }, highlight = nil },
      { cells = { "longer", "x", "yy" }, highlight = nil },
    }
    lines, hls = org_view.render_columns(rows)
  ]])
  local lines = child.lua_get([[lines]])
  eq(#lines, 2)
  -- Column 1 is padded to "longer" (6 chars) so column 2 starts at the
  -- same byte offset on both rows; column 2 is padded to "bb" (2 chars)
  -- so column 3 starts at the same offset on both rows too. The last
  -- column is never padded (matches render_list_lines' convention of
  -- never padding its trailing segment), so assert alignment via offsets
  -- rather than a hand-counted literal, the same idiom
  -- "render_list_lines: alias column aligned across rows" already uses.
  eq(lines[1]:find("bb", 1, true), lines[2]:find("x", 1, true))
  eq(lines[1]:find("ccc", 1, true), lines[2]:find("yy", 1, true))
end

test_set["render_columns: highlight produces whole-line segment"] = function()
  child.lua([[
    rows = {
      { cells = { "text" }, highlight = "SfWarn" },
    }
    lines, hls = org_view.render_columns(rows)
  ]])
  local hls = child.lua_get([[hls]])
  eq(#hls, 1)
  eq(#hls[1], 1)
  eq(hls[1][1].group, "SfWarn")
  eq(hls[1][1].col_start, 0)
  eq(hls[1][1].col_end, 4)
end

test_set["render_columns: nil highlight produces empty segment"] = function()
  child.lua([[
    rows = {
      { cells = { "text" }, highlight = nil },
    }
    lines, hls = org_view.render_columns(rows)
  ]])
  local hls = child.lua_get([[hls]])
  eq(#hls, 1)
  eq(#hls[1], 0)
end

test_set["render_columns: empty input returns empty tables"] = function()
  child.lua([[
    lines, hls = org_view.render_columns({})
  ]])
  local lines = child.lua_get([[lines]])
  local hls = child.lua_get([[hls]])
  eq(#lines, 0)
  eq(#hls, 0)
end

-- Regression: an unmanaged package's null NamespacePrefix decodes to
-- vim.NIL (a truthy userdata sentinel, not Lua nil -- see rest_api.lua's
-- cli_json_call), which used to crash here with "attempt to get length of
-- a userdata value" on `#cell`. Also cover a plain non-string cell (e.g. a
-- number slipping through unformatted) since both are the same class of
-- "cell isn't a string" caller mistake.
test_set["render_columns: vim.NIL and non-string cells do not error"] = function()
  child.lua([[
    rows = {
      { cells = { "Pkg", vim.NIL, 3 } },
    }
    lines, hls = org_view.render_columns(rows)
  ]])
  local lines = child.lua_get([[lines]])
  eq(#lines, 1)
  expect.match(lines[1], "Pkg")
  expect.match(lines[1], "3")
end

test_set["fetch_org_display: calls rest_api.get_org_display and forwards alias"] = function()
  child.lua([[
    local api = require("sf.sub.rest_api")
    local captured_alias
    local original_get_org_display = api.get_org_display
    api.get_org_display = function(alias, cb)
      captured_alias = alias
      cb({ accessToken = "tok", instanceUrl = "https://x", apiVersion = "60.0", username = "u@x.com" }, nil)
    end
    
    _G._result = nil
    _G._err = nil
    org_view.fetch_org_display({ alias = "test_org" }, function(result, err)
      _G._result = result
      _G._err = err
    end)
    
    api.get_org_display = original_get_org_display
    _G._captured_alias = captured_alias
  ]])
  
  eq(child.lua_get([[_G._captured_alias]]), "test_org")
  local result = child.lua_get([[_G._result]])
  eq(result.username, "u@x.com")
end

test_set["fetch_org_display: surfaces error from get_org_display"] = function()
  child.lua([[
    local api = require("sf.sub.rest_api")
    local original_get_org_display = api.get_org_display
    api.get_org_display = function(alias, cb)
      cb(nil, "some error")
    end
    
    _G._result = nil
    _G._err = nil
    org_view.fetch_org_display({ alias = "test_org" }, function(result, err)
      _G._result = result
      _G._err = err
    end)
    
    api.get_org_display = original_get_org_display
  ]])
  
  eq(child.lua_get([[_G._result == nil]]), true)
  eq(child.lua_get([[_G._err == "could not parse `sf org display` output"]]), true)
end

test_set["fetch_org_display: does not call vim.system directly"] = function()
  child.lua([[
    local api = require("sf.sub.rest_api")
    local vim_system_called = false
    local original_vim_system = vim.system
    vim.system = function()
      vim_system_called = true
    end
    local original_get_org_display = api.get_org_display
    api.get_org_display = function(alias, cb)
      cb({ accessToken = "tok", instanceUrl = "https://x", apiVersion = "60.0", username = "u@x.com" }, nil)
    end
    
    org_view.fetch_org_display({ alias = "test_org" }, function() end)
    
    api.get_org_display = original_get_org_display
    vim.system = original_vim_system
    _G._vim_system_called = vim_system_called
  ]])
  
  eq(child.lua_get([[_G._vim_system_called]]), false)
end

return test_set
