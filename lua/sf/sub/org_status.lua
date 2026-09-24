-- Org instance status via status.salesforce.com. Two-hop fetch: SOQL for
-- the org's InstanceName, then an unauthenticated GET to the public status
-- API for that instance (no bearer token needed or sent).

local rest_api = require("sf.sub.rest_api")

local org_status = {}

---@param value any
---@return string|nil coerced to a string only when it already is one
local function as_string(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

---@param value any
---@return string|nil the real API returns incident/maintenance ids as
---  numbers, not strings -- accept either, coerce to string, reject anything
---  else (e.g. the nested-table shape a malformed response once returned).
local function coerce_id(value)
  if type(value) == "string" then
    return value
  elseif type(value) == "number" then
    return tostring(value)
  end
  return nil
end

--- Extract a short, human-readable summary from an incident's `message`
--- field. On the real API this is an object of
--- `{ rootCause, actionPlan, pathToResolution }` (any of which may be
--- null), not a string -- fall back to `additionalInformation`, then nil.
---@param incident table
---@return string|nil
local function summarize_incident_message(incident)
  local message = incident.message
  if type(message) == "table" then
    local root_cause = as_string(message.rootCause)
    if root_cause then
      return root_cause
    end
  else
    local as_plain_string = as_string(message)
    if as_plain_string then
      return as_plain_string
    end
  end
  return as_string(incident.additionalInformation)
end

--- Get the first impact from an incident if it is a table.
---@param incident table
---@return table|nil
local function first_impact(incident)
  local impacts = incident.IncidentImpacts
  if type(impacts) == "table" and type(impacts[1]) == "table" then
    return impacts[1]
  end
  return nil
end

--- Severity lives on the incident's first `IncidentImpacts` entry, not on
--- the incident itself.
---@param incident table
---@return string|nil
local function incident_severity(incident)
  local impact = first_impact(incident)
  if impact then
    return as_string(impact.severity)
  end
  return nil
end

--- Parse the `https://api.status.salesforce.com/v1/instances/<name>/status`
--- response shape. Verified against a live fixture (a real Hyperforce
--- sandbox instance, captured while building this) -- top-level `key` is
--- the instance name (confusingly not called `instanceName`),
--- `status`/`location`/`environment`/`releaseVersion`/`maintenanceWindow`
--- are plain strings, and `Products`/`Incidents`/`Maintenances`/
--- `GeneralMessages` are arrays. Still defensive against any field being
--- missing/wrong-typed regardless, so an unexpected shape degrades
--- gracefully instead of erroring.
---@param decoded table|nil
---@return table status_info {
---  status: string,
---  instance_name: string|nil, location: string|nil, environment: string|nil,
---  release_version: string|nil, maintenance_window: string|nil,
---  products: { { name: string, is_active: boolean }, ... },
---  incidents: { { id: string|nil, status: string|nil, type: string|nil,
---                 severity: string|nil, message: string|nil,
---                 impact_start: string|nil, impact_end: string|nil,
---                 created_at: string|nil }, ... },
---  maintenances: { { name: string, status: string, planned_start: string|nil,
---                     planned_end: string|nil }, ... } sorted by planned_start,
---  messages: { { subject: string, status: string, start_date: string|nil,
---                end_date: string|nil }, ... },
--- }
function org_status.parse_instance_status(decoded)
  if type(decoded) ~= "table" then
    decoded = {}
  end

  local products = {}
  if type(decoded.Products) == "table" then
    for _, product in ipairs(decoded.Products) do
      if type(product) == "table" then
        table.insert(products, {
          name = as_string(product.altDisplayName) or as_string(product.name) or as_string(product.key) or "unknown",
          is_active = product.isActive == true,
        })
      end
    end
  end

  local incidents = {}
  if type(decoded.Incidents) == "table" then
    for _, incident in ipairs(decoded.Incidents) do
      if type(incident) == "table" then
        local impact = first_impact(incident)
        local impact_type = impact and as_string(impact.type) or nil
        table.insert(incidents, {
          id = coerce_id(incident.id),
          status = as_string(incident.status),
          type = impact_type or as_string(incident.type), -- prefer impact type over incident type
          severity = incident_severity(incident),
          message = summarize_incident_message(incident),
          impact_start = impact and as_string(impact.startTime) or nil,
          impact_end = impact and as_string(impact.endTime) or nil,
          created_at = as_string(incident.createdAt),
        })
      end
    end
  end

  local maintenances = {}
  if type(decoded.Maintenances) == "table" then
    for _, maintenance in ipairs(decoded.Maintenances) do
      if type(maintenance) == "table" then
        table.insert(maintenances, {
          name = as_string(maintenance.name) or "(unnamed maintenance)",
          status = as_string(maintenance.status) or "unknown",
          planned_start = as_string(maintenance.plannedStartTime),
          planned_end = as_string(maintenance.plannedEndTime),
        })
      end
    end
    table.sort(maintenances, function(row_a, row_b)
      return (row_a.planned_start or "") < (row_b.planned_start or "")
    end)
  end

  local messages = {}
  if type(decoded.GeneralMessages) == "table" then
    for _, general_message in ipairs(decoded.GeneralMessages) do
      if type(general_message) == "table" then
        table.insert(messages, {
          subject = as_string(general_message.subject) or "(no subject)",
          status = as_string(general_message.status) or "unknown",
          start_date = as_string(general_message.startDate),
          end_date = as_string(general_message.endDate),
        })
      end
    end
  end

  return {
    status = as_string(decoded.status) or "unknown",
    instance_name = as_string(decoded.key),
    location = as_string(decoded.location),
    environment = as_string(decoded.environment),
    release_version = as_string(decoded.releaseVersion),
    maintenance_window = as_string(decoded.maintenanceWindow),
    products = products,
    incidents = incidents,
    maintenances = maintenances,
    messages = messages,
  }
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
