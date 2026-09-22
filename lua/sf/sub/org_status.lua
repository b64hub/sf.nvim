-- Org instance status via status.salesforce.com. Two-hop fetch: SOQL for
-- the org's InstanceName, then an unauthenticated GET to the public status
-- API for that instance (no bearer token needed or sent).

local rest_api = require("sf.sub.rest_api")

local org_status = {}

--- Parse the `https://api.status.salesforce.com/v1/instances/<name>/status`
--- response shape into `{ status, message, incidents }`.
---
--- ponytail: the exact response shape is reconstructed from memory of the
--- public status.salesforce.com API (not verified against a live fixture
--- here) -- best-effort mapping: top-level `status` string (e.g. "OK",
--- "MAJOR_INCIDENT", "MINOR_INCIDENT", "MAINTENANCE"), and an `Incidents`
--- array of `{ message, severity, id, ... }`. Defensive against any field
--- being missing/wrong-typed so a shape mismatch degrades to "unknown"
--- instead of erroring. Upgrade path: tighten this once a real response is
--- captured and can be pinned as a fixture.
---@param decoded table|nil
---@return table { status: string, message: string|nil, incidents: table[] }
function org_status.parse_instance_status(decoded)
  if type(decoded) ~= "table" then
    return { status = "unknown", message = nil, incidents = {} }
  end

  local status = type(decoded.status) == "string" and decoded.status or "unknown"

  local incidents = {}
  local raw_incidents = decoded.Incidents or decoded.incidents
  if type(raw_incidents) == "table" then
    for _, incident in ipairs(raw_incidents) do
      if type(incident) == "table" then
        table.insert(incidents, {
          id = incident.id,
          message = incident.message,
          severity = incident.severity,
        })
      end
    end
  end

  local message = nil
  if incidents[1] and type(incidents[1].message) == "string" then
    message = incidents[1].message
  end

  return { status = status, message = message, incidents = incidents }
end

--- @param session table `Api.get_session` result: { token, url, api_version, username }
--- @param callback fun(status_table: table|nil, err: string|nil)
function org_status.fetch(session, callback)
  rest_api.query_std(session, "SELECT InstanceName FROM Organization LIMIT 1", function(records, err)
    local instance_name = records and records[1] and records[1].InstanceName
    if not instance_name then
      return callback(nil, err or "could not determine org instance name")
    end

    -- Unauthenticated call: the status API is public, no Authorization
    -- header is sent (curl_json never adds one on its own).
    rest_api.curl_json({
      "https://api.status.salesforce.com/v1/instances/" .. instance_name .. "/status",
    }, function(decoded, curl_err)
      if not decoded then
        return callback(nil, curl_err)
      end
      callback(org_status.parse_instance_status(decoded), nil)
    end)
  end)
end

return org_status
