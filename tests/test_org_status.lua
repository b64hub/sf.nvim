local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local eq = helpers.expect.equality
local new_set = MiniTest.new_set

local test_set = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[org_status = require("sf.sub.org_status")]])
    end,
    post_once = child.stop,
  },
})

test_set["parse_instance_status: healthy status with full instance info"] = function()
  child.lua([[
    decoded = {
      key = "DEU146S",
      location = "EMEA",
      environment = "sandbox",
      releaseVersion = "Summer '26 Patch 14.21",
      maintenanceWindow = "Saturdays 2:00 PM - 6:00 PM PST",
      status = "OK",
      Products = {},
      Incidents = {},
      Maintenances = {},
      GeneralMessages = {},
    }
  ]])
  local result = child.lua_get([[org_status.parse_instance_status(decoded)]])
  eq(result.status, "OK")
  eq(result.instance_name, "DEU146S")
  eq(result.location, "EMEA")
  eq(result.environment, "sandbox")
  eq(result.release_version, "Summer '26 Patch 14.21")
  eq(result.maintenance_window, "Saturdays 2:00 PM - 6:00 PM PST")
  eq(result.products, {})
  eq(result.incidents, {})
  eq(result.maintenances, {})
  eq(result.messages, {})
end

-- Real status.salesforce.com shape (captured from a live sandbox instance
-- while building this): incident `id` is a NUMBER, `severity` lives on the
-- first `IncidentImpacts` entry (not on the incident itself), and `message`
-- is an object of { rootCause, actionPlan, pathToResolution } -- often all
-- null, in which case `additionalInformation` is the only usable summary.
test_set["parse_instance_status: incidents use the real API shape"] = function()
  child.lua([[
    decoded = {
      status = "OK",
      Incidents = {
        {
          id = 20004367,
          status = "Resolved",
          type = "Degradation",
          additionalInformation = "Private Connect",
          message = { rootCause = "Root cause identified", actionPlan = nil, pathToResolution = nil },
          IncidentImpacts = { { severity = "minor" } },
        },
        {
          id = 20004370,
          status = "Resolved",
          type = "Degradation",
          additionalInformation = "",
          message = { rootCause = nil, actionPlan = nil, pathToResolution = nil },
          IncidentImpacts = {},
        },
      },
    }
  ]])
  local result = child.lua_get([[org_status.parse_instance_status(decoded)]])
  eq(#result.incidents, 2)
  eq(result.incidents[1].id, "20004367") -- numeric id coerced to string
  eq(result.incidents[1].severity, "minor")
  eq(result.incidents[1].message, "Root cause identified") -- rootCause wins
  -- Second incident: message has no rootCause and additionalInformation is
  -- empty, so message falls all the way through to nil, not an error.
  eq(result.incidents[2].message, nil)
  eq(result.incidents[2].severity, nil)
end

test_set["parse_instance_status: incident falls back to additionalInformation when message has no rootCause"] = function()
  child.lua([[
    decoded = {
      status = "OK",
      Incidents = {
        {
          id = 1,
          message = { rootCause = nil },
          additionalInformation = "Private Connect",
        },
      },
    }
  ]])
  local result = child.lua_get([[org_status.parse_instance_status(decoded)]])
  eq(result.incidents[1].message, "Private Connect")
end

test_set["parse_instance_status: products, maintenances (sorted by start) and messages"] = function()
  child.lua([[
    decoded = {
      status = "OK",
      Products = {
        { key = "Salesforce_Services", name = "Salesforce Services", altDisplayName = "Sales and Service", isActive = true },
      },
      Maintenances = {
        { name = "Spring '27 Major Release", status = "Confirmed", plannedStartTime = "2027-02-19T22:30:00.000Z", plannedEndTime = "2027-02-19T23:00:00.000Z" },
        { name = "Winter '27 Major Release", status = "Confirmed", plannedStartTime = "2026-10-09T21:30:00.000Z", plannedEndTime = "2026-10-09T22:00:00.000Z" },
      },
      GeneralMessages = {
        { subject = "Security Advisory", status = "Active", startDate = "2026-03-08T04:00:00.000Z", endDate = nil },
      },
    }
  ]])
  local result = child.lua_get([[org_status.parse_instance_status(decoded)]])
  eq(#result.products, 1)
  eq(result.products[1].name, "Sales and Service") -- altDisplayName preferred
  eq(result.products[1].is_active, true)

  eq(#result.maintenances, 2)
  -- Sorted by planned_start ascending regardless of input order.
  eq(result.maintenances[1].name, "Winter '27 Major Release")
  eq(result.maintenances[2].name, "Spring '27 Major Release")

  eq(#result.messages, 1)
  eq(result.messages[1].subject, "Security Advisory")
  eq(result.messages[1].end_date, nil)
end

test_set["parse_instance_status: malformed/unexpected shape does not error"] = function()
  child.lua([[decoded = { unexpected = "shape", Incidents = "not-a-table" }]])
  local result = child.lua_get([[org_status.parse_instance_status(decoded)]])
  eq(result.status, "unknown")
  eq(result.instance_name, nil)
  eq(result.incidents, {})
  eq(result.products, {})
  eq(result.maintenances, {})
  eq(result.messages, {})
end

test_set["parse_instance_status: nil input does not error"] = function()
  local result = child.lua_get([[org_status.parse_instance_status(nil)]])
  eq(result.status, "unknown")
  eq(result.incidents, {})
end

-- Regression: a real org returned incidents with non-string/non-number id
-- and a non-object message, which crashed render_status_section's `..`
-- concat ("attempt to concatenate a table value") since parse_instance_status
-- copied those fields through unchecked. Must coerce to nil, not error.
test_set["parse_instance_status: incident with an unrecognized id shape does not error"] = function()
  child.lua([[
    decoded = {
      status = "MAJOR_INCIDENT",
      Incidents = {
        { id = { raw = "nested" }, message = { text = "nested" }, additionalInformation = "" },
      },
    }
  ]])
  local result = child.lua_get([[org_status.parse_instance_status(decoded)]])
  eq(result.status, "MAJOR_INCIDENT")
  eq(#result.incidents, 1)
  eq(result.incidents[1].id, nil)
  eq(result.incidents[1].message, nil)
end

return test_set
