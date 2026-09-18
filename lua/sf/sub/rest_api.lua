-- Thin client for the Salesforce REST/Tooling APIs, authenticated via one
-- `sf org display` call (reuses the CLI's own auth resolution - avoids
-- reimplementing OAuth/JWT/web-login flows) and then plain `curl` for
-- everything else.
--
-- Much faster than shelling out to `sf data ...` for every single
-- query/create/update/delete: each `sf` CLI invocation pays a multi-second
-- Node startup cost that a raw HTTP request skips (measured ~0.3s via curl
-- vs ~6s via the CLI for an equivalent Tooling query). Useful anywhere the
-- plugin currently does several sequential `sf data`/`sf org` CLI calls.

local U = require("sf.util")
local B = require("sf.sub.cmd_builder")

local M = {}

---@param cmd table
---@param err_msg string
---@param cb fun(result: table|nil, err: string|nil)
local function cli_json_call(cmd, err_msg, cb)
  U.silent_system_call(cmd, nil, err_msg, function(obj)
    local ok, decoded = pcall(vim.json.decode, obj.stdout)
    if not ok or not decoded then
      return cb(nil, err_msg .. ": could not parse response")
    end
    cb(decoded, nil)
  end)
end

---@return boolean
M.has_curl = function()
  return vim.fn.executable("curl") == 1
end

--- One `sf org display` call gets everything needed to talk to the REST/
--- Tooling APIs directly afterwards: access token, instance URL, API
--- version, and the org's own username.
---@param cb fun(session: table|nil, err: string|nil)
M.get_session = function(cb)
  local cmd = B:new():cmd("org"):act("display"):addParams("--json"):buildAsTable()
  cli_json_call(cmd, "Failed to get org session", function(result, err)
    local r = result and result.result
    if not r or U.is_empty_str(r.accessToken) then
      return cb(nil, err or "failed to read org session (accessToken missing)")
    end
    cb({ token = r.accessToken, url = r.instanceUrl, api_version = r.apiVersion, username = r.username }, nil)
  end)
end

---@param args string[] curl args (method/url/headers/body); auth is omitted,
---  callers pass their own `session.token`
---@param cb fun(decoded: table|nil, err: string|nil) `decoded.status` is the
---  HTTP status; `decoded.records`/`.id`/`.success` depend on the endpoint
M.curl_json = function(args, cb)
  local cmd = vim.list_extend({ "curl", "-s", "-w", "\nHTTPSTATUS:%{http_code}" }, args)
  U.silent_system_call(cmd, nil, "API request failed", function(obj)
    local body, status = (obj.stdout or ""):match("^(.-)\nHTTPSTATUS:(%d+)%s*$")
    status = tonumber(status) or 0
    if U.is_empty_str(body) then
      return cb({ status = status }, nil)
    end

    local ok, decoded = pcall(vim.json.decode, body)
    if not ok then
      return cb(nil, "failed to parse API response: " .. body)
    end
    if decoded[1] and decoded[1].message and decoded[1].errorCode then
      return cb(nil, decoded[1].message)
    end
    decoded.status = status
    cb(decoded, nil)
  end)
end

---@param session table {token, url, api_version}
---@param soql string
---@param cb fun(records: table[]|nil, err: string|nil)
M.query = function(session, soql, cb)
  M.curl_json({
    "-G",
    string.format("%s/services/data/v%s/tooling/query", session.url, session.api_version),
    "--data-urlencode",
    "q=" .. soql,
    "-H",
    "Authorization: Bearer " .. session.token,
  }, function(decoded, err)
    if not decoded then
      return cb(nil, err)
    end
    cb(decoded.records or {}, nil)
  end)
end

--- Same as `M.query` but against the standard (non-Tooling) REST query
--- endpoint - needed for fields the Tooling API's object representation
--- doesn't expose (e.g. `User.IsActive` errors as an unknown column via
--- `/tooling/query`, but works fine via plain `/query`).
---@param session table
---@param soql string
---@param cb fun(records: table[]|nil, err: string|nil)
M.query_std = function(session, soql, cb)
  M.curl_json({
    "-G",
    string.format("%s/services/data/v%s/query", session.url, session.api_version),
    "--data-urlencode",
    "q=" .. soql,
    "-H",
    "Authorization: Bearer " .. session.token,
  }, function(decoded, err)
    if not decoded then
      return cb(nil, err)
    end
    cb(decoded.records or {}, nil)
  end)
end

---@param session table
---@param sobject string
---@param fields table
---@param cb fun(id: string|nil, err: string|nil)
M.create = function(session, sobject, fields, cb)
  M.curl_json({
    "-X",
    "POST",
    string.format("%s/services/data/v%s/tooling/sobjects/%s/", session.url, session.api_version, sobject),
    "-H",
    "Authorization: Bearer " .. session.token,
    "-H",
    "Content-Type: application/json",
    "-d",
    vim.json.encode(fields),
  }, function(decoded, err)
    if not decoded or not decoded.id then
      return cb(nil, err or "create failed")
    end
    cb(decoded.id, nil)
  end)
end

---@param session table
---@param sobject string
---@param id string
---@param fields table
---@param cb fun(ok: boolean, err: string|nil)
M.update = function(session, sobject, id, fields, cb)
  M.curl_json({
    "-X",
    "PATCH",
    string.format("%s/services/data/v%s/tooling/sobjects/%s/%s", session.url, session.api_version, sobject, id),
    "-H",
    "Authorization: Bearer " .. session.token,
    "-H",
    "Content-Type: application/json",
    "-d",
    vim.json.encode(fields),
  }, function(decoded, err)
    cb(decoded ~= nil and decoded.status == 204, err)
  end)
end

---@param session table
---@param sobject string
---@param id string
---@param cb fun(ok: boolean, err: string|nil)
M.delete = function(session, sobject, id, cb)
  M.curl_json({
    "-X",
    "DELETE",
    string.format("%s/services/data/v%s/tooling/sobjects/%s/%s", session.url, session.api_version, sobject, id),
    "-H",
    "Authorization: Bearer " .. session.token,
  }, function(decoded, err)
    cb(decoded ~= nil and decoded.status == 204, err)
  end)
end

return M
