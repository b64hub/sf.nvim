local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

-- Exercises the trace-flags view's private `format_trace_flag_expiry`
-- formatter indirectly through its public `render(record, data)` function
-- (the formatter itself is a local, not exported) -- these tests fix the
-- expiration timestamp relative to the real clock at run time, so no
-- injectable "now" is needed the way org_view.days_until has one.
local test_set = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[dashboard_views = require("sf.ui.dashboard_views")]])
    end,
    post_once = child.stop,
  },
})

--- @param child_process table the mini.test child process handle
--- @param expiration_date string ISO8601 UTC datetime
--- @return string the first rendered line for a single trace flag with that expiry
local function render_first_line(child_process, expiration_date)
  child_process.lua(
    string.format(
      [[
        local trace_flags_view
        for _, view in ipairs(dashboard_views) do
          if view.id == "trace_flags" then
            trace_flags_view = view
            break
          end
        end
        local data = {
          {
            Id = "test-id",
            DebugLevel = { DeveloperName = "SFNVIM_REPLAY" },
            ExpirationDate = %q,
            TracedEntity = { Name = "testuser@example.com" },
          },
        }
        rendered_lines = trace_flags_view.render({}, data)
      ]],
      expiration_date
    )
  )
  return child_process.lua_get([[rendered_lines[1] ]])
end

test_set["trace_flags render: far in the future shows hours remaining"] = function()
  local expiration_date = os.date("!%Y-%m-%dT%H:%M:%S.000Z", os.time() + 24 * 60 * 60)
  local line = render_first_line(child, expiration_date)
  expect.match(line, "expires in")
  expect.match(line, "h")
end

test_set["trace_flags render: about to expire shows minutes remaining"] = function()
  local expiration_date = os.date("!%Y-%m-%dT%H:%M:%S.000Z", os.time() + 5 * 60)
  local line = render_first_line(child, expiration_date)
  expect.match(line, "expires in")
  expect.match(line, "min")
end

test_set["trace_flags render: already expired"] = function()
  local expiration_date = os.date("!%Y-%m-%dT%H:%M:%S.000Z", os.time() - 60)
  local line = render_first_line(child, expiration_date)
  expect.match(line, "expired")
end

test_set["trace_flags render: no trace flags"] = function()
  child.lua([[
    local trace_flags_view
    for _, view in ipairs(dashboard_views) do
      if view.id == "trace_flags" then
        trace_flags_view = view
        break
      end
    end
    rendered_lines = trace_flags_view.render({}, {})
  ]])
  local line = child.lua_get([[rendered_lines[1] ]])
  expect.match(line, "No active")
end

return test_set
