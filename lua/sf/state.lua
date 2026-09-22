-- Central cached state for org/trace-flag info, read by the statusline.
-- No I/O happens here: producers elsewhere (org.lua, debug.lua) update this
-- and fire events; the statusline only ever reads the cache.
local state = {}

local cache = {
  org = { alias = "", is_scratch = nil, is_prod = nil, is_sandbox = nil, username = nil },
  trace_flags = {}, -- { { id, log_type, debug_level, expires_at_epoch } }
  user_id_cache = {}, -- session.username -> User.Id, avoids a query per refresh
}

--- Update the cached target org and notify listeners if it actually changed:
--- fires `User SfOrgChanged` and schedules a `redrawstatus`.
---@param alias string
---@param meta table|nil { is_scratch, is_prod, is_sandbox, username }
function state.set_target_org(alias, meta)
  meta = meta or {}
  local changed = cache.org.alias ~= alias

  cache.org = {
    alias = alias,
    is_scratch = meta.is_scratch,
    is_prod = meta.is_prod,
    is_sandbox = meta.is_sandbox,
    username = meta.username,
  }

  if changed then
    -- Trace flags are per-org; don't keep showing the previous org's status
    -- while the async refetch (triggered by the `SfOrgChanged` autocmd) is
    -- in flight, or if it fails silently.
    cache.trace_flags = {}
    vim.api.nvim_exec_autocmds("User", { pattern = "SfOrgChanged", data = { alias = alias } })
    vim.schedule(function()
      pcall(vim.cmd.redrawstatus)
    end)
  end
end

--- @return table cached { alias, is_scratch, is_prod, is_sandbox, username }
function state.get()
  return cache.org
end

--- @return table[] cached active TraceFlags: { id, log_type, debug_level, expires_at_epoch }
function state.get_trace_flags()
  return cache.trace_flags
end

--- Parse a Salesforce datetime string (e.g. "2024-01-01T00:00:00.000+0000")
--- into a Unix timestamp. Duplicated from `debug.lua`'s private helper of
--- the same shape (not exported there) rather than reaching into it.
---@param s string|nil
---@return integer
local function parse_sf_datetime(s)
  if not s then
    return 0
  end
  local y, mo, d, h, mi, se = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return 0
  end
  local t = { year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(se) }
  local now = os.time()
  local utc_now = os.date("!*t", now)
  local local_now = os.date("*t", now)
  utc_now.isdst = local_now.isdst
  local offset = os.difftime(os.time(local_now), os.time(utc_now))
  return os.time(t) + offset
end

---@param session table { username, ... }
---@param cb fun(user_id: string|nil)
local function resolve_user_id(session, cb)
  local cached = cache.user_id_cache[session.username]
  if cached then
    return cb(cached)
  end

  local Api = require("sf.sub.rest_api")
  local soql = string.format("SELECT Id FROM User WHERE Username = '%s'", session.username)
  Api.query_std(session, soql, function(records)
    local id = records and records[1] and records[1].Id
    if id then
      cache.user_id_cache[session.username] = id
    end
    cb(id)
  end)
end

--- Async, cached refresh of active TraceFlags for the current target org's
--- user. Never blocks, never surfaces an error to the user -- the
--- statusline must stay silent and simply keep the last known value on
--- failure. Safe to call often (event-driven + a background timer).
function state.refresh_trace_flags()
  local Api = require("sf.sub.rest_api")
  if not Api.has_curl() then
    return
  end

  Api.get_session(function(session)
    if not session then
      return
    end

    resolve_user_id(session, function(user_id)
      if not user_id then
        return
      end

      local soql = string.format(
        "SELECT Id, LogType, StartDate, ExpirationDate, DebugLevel.DeveloperName FROM TraceFlag WHERE TracedEntityId = '%s'",
        user_id
      )
      Api.query(session, soql, function(records)
        if not records then
          return
        end

        local now = os.time()
        local flags = {}
        for _, r in ipairs(records) do
          local expires_at = parse_sf_datetime(r.ExpirationDate)
          if expires_at > now then
            table.insert(flags, {
              id = r.Id,
              log_type = r.LogType,
              debug_level = r.DebugLevel and r.DebugLevel.DeveloperName,
              expires_at_epoch = expires_at,
            })
          end
        end

        cache.trace_flags = flags
        vim.schedule(function()
          pcall(vim.cmd.redrawstatus)
        end)
      end)
    end)
  end)
end

state.__test = cache

return state
