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

local util = require("sf.util")
local cmd_builder = require("sf.sub.cmd_builder")

local rest_api = {}

---@param cmd table
---@param err_msg string
---@param cb fun(result: table|nil, err: string|nil)
local function cli_json_call(cmd, err_msg, cb)
  util.silent_system_call(cmd, nil, err_msg, function(obj)
    -- luanil = { object = true }: decode JSON `null` as Lua `nil`, not
    -- Neovim's `vim.NIL` sentinel. `vim.NIL` is a userdata value that is
    -- truthy, so every `field or default` fallback downstream (there are
    -- many, across dashboard_views.lua/org_view.lua) silently returns
    -- `vim.NIL` instead of `default` for a real API field the CLI/API
    -- legitimately returned as null -- e.g. an unmanaged package's null
    -- `NamespacePrefix`, which crashed org_view.render_columns with
    -- "attempt to get length of a userdata value". Fixing it once at every
    -- decode boundary is the shared-function fix per this repo's own
    -- root-cause ladder, instead of type-checking every downstream cell.
    local ok, decoded = pcall(vim.json.decode, obj.stdout, { luanil = { object = true } })
    if not ok or not decoded then
      return cb(nil, err_msg .. ": could not parse response")
    end
    cb(decoded, nil)
  end)
end

-- Module-local cache for `sf org display` results with TTL and in-flight coalescing.
-- Entry: { result = ..., err = ..., fetched_at = ..., waiters = { cb, ... } }
local org_display_cache = {}
local org_display_ttl_seconds = 300 -- 5 minutes; access tokens expire, so cache must not live forever

--- Clears the org_display cache entirely or for one alias.
---@param alias string|nil optional; when omitted, clears all cached entries
function rest_api.invalidate_org_display(alias)
  if alias then
    org_display_cache[alias] = nil
  else
    org_display_cache = {}
  end
end

--- Fetches the raw `sf org display` result with TTL caching and in-flight
--- coalescing: multiple simultaneous callers for the same alias spawn once
--- and all receive the same result (or error), solving the "thundering herd"
--- during prefetch.
---@param alias string org alias (required, no fallback to target_org here)
---@param cb fun(result: table|nil, err: string|nil) receives the decoded
---  `result` table from `sf org display --json`, not the full response
function rest_api.get_org_display(alias, cb)
  local now = vim.uv.now()
  local cache_entry = org_display_cache[alias]

  -- Entry exists and is not expired
  if cache_entry and (now - cache_entry.fetched_at) < org_display_ttl_seconds * 1000 then
    if cache_entry.fetching then
      -- In-flight: append to waiters; completion will call us back
      table.insert(cache_entry.waiters, cb)
      return
    end
    -- Complete (not fetching): if error, return it; if data, return it
    return cb(cache_entry.result, cache_entry.err)
  end

  -- Cache miss or expired: spawn a new fetch
  org_display_cache[alias] = {
    result = nil,
    err = nil,
    fetched_at = now,
    fetching = true,
    waiters = { cb }, -- first waiter is the caller
  }

  local builder = cmd_builder:new():cmd("org"):act("display"):addParams("--json"):set_org(alias)
  local cmd = builder:buildAsTable()

  cli_json_call(cmd, "Failed to get org display", function(decoded, err)
    -- `cli_json_call` hands back the FULL `sf org display --json` response
    -- ({ status = 0, result = {...} }), not the inner `result` object this
    -- function documents/returns -- unwrap it here, once, so every caller
    -- (get_session, and any future direct get_org_display caller) sees the
    -- flat org-display fields the docstring promises.
    local result = decoded and decoded.result
    if decoded and not result and not err then
      err = "Failed to get org display: missing result"
    end
    local entry = org_display_cache[alias]
    if entry then
      entry.result = result
      entry.err = err
      entry.fetching = false
      local waiters = entry.waiters
      entry.waiters = {}
      -- Do not cache errors: an errored lookup must be retried on the next call.
      -- Drop the cache entry so a future call will spawn again.
      if err then
        org_display_cache[alias] = nil
      end
      -- Drain waiters
      for _, waiter_cb in ipairs(waiters) do
        waiter_cb(result, err)
      end
    end
  end)
end

---@return boolean
rest_api.has_curl = function()
  return vim.fn.executable("curl") == 1
end

--- One `sf org display` call gets everything needed to talk to the REST/
--- Tooling APIs directly afterwards: access token, instance URL, API
--- version, and the org's own username.
---@param alias_or_cb string|fun(session: table|nil, err: string|nil) optional org alias
---  to scope the session to (defaults to `util.target_org` via `set_org`'s
---  own fallback when omitted); may be omitted entirely, in which case this
---  argument is the callback (backwards-compatible with `get_session(cb)`)
---@param maybe_cb fun(session: table|nil, err: string|nil)|nil required when
---  an alias is passed as the first argument
rest_api.get_session = function(alias_or_cb, maybe_cb)
  local alias, cb
  if type(alias_or_cb) == "function" then
    alias, cb = nil, alias_or_cb
  else
    alias, cb = alias_or_cb, maybe_cb
  end

  -- Resolve alias: passed explicitly, or fall back to util.target_org via set_org
  local resolved_alias = alias or util.target_org

  -- get_org_display requires an alias; use cached result if available
  rest_api.get_org_display(resolved_alias, function(result, err)
    if not result or util.is_empty_str(result.accessToken) then
      return cb(nil, err or "failed to read org session (accessToken missing)")
    end
    cb({ token = result.accessToken, url = result.instanceUrl, api_version = result.apiVersion, username = result.username }, nil)
  end)
end

---@param args string[] curl args (method/url/headers/body); auth is omitted,
---  callers pass their own `session.token`
---@param cb fun(decoded: table|nil, err: string|nil) `decoded.status` is the
---  HTTP status; `decoded.records`/`.id`/`.success` depend on the endpoint
rest_api.curl_json = function(args, cb)
  local cmd = vim.list_extend({ "curl", "-s", "-w", "\nHTTPSTATUS:%{http_code}" }, args)
  util.silent_system_call(cmd, nil, "API request failed", function(obj)
    local body, status = (obj.stdout or ""):match("^(.-)\nHTTPSTATUS:(%d+)%s*$")
    status = tonumber(status) or 0
    if util.is_empty_str(body) then
      return cb({ status = status }, nil)
    end

    -- luanil = { object = true }: see cli_json_call's comment above -- same
    -- vim.NIL-vs-nil footgun applies to every REST/Tooling API response
    -- decoded here (query, curl_json, and everything built on them).
    local ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true } })
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
rest_api.query = function(session, soql, cb)
  rest_api.curl_json({
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

--- Same as `rest_api.query` but against the standard (non-Tooling) REST query
--- endpoint - needed for fields the Tooling API's object representation
--- doesn't expose (e.g. `User.IsActive` errors as an unknown column via
--- `/tooling/query`, but works fine via plain `/query`).
---@param session table
---@param soql string
---@param cb fun(records: table[]|nil, err: string|nil)
rest_api.query_std = function(session, soql, cb)
  rest_api.curl_json({
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
rest_api.create = function(session, sobject, fields, cb)
  rest_api.curl_json({
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
rest_api.update = function(session, sobject, id, fields, cb)
  rest_api.curl_json({
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
rest_api.delete = function(session, sobject, id, cb)
  rest_api.curl_json({
    "-X",
    "DELETE",
    string.format("%s/services/data/v%s/tooling/sobjects/%s/%s", session.url, session.api_version, sobject, id),
    "-H",
    "Authorization: Bearer " .. session.token,
  }, function(decoded, err)
    cb(decoded ~= nil and decoded.status == 204, err)
  end)
end

return rest_api
