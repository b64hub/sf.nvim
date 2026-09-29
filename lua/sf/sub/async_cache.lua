-- Generic TTL + in-flight-coalescing cache for one kind of keyed async
-- fetch. Extracted from rest_api.lua's `get_org_display` cache, which
-- needed exactly this shape (multiple simultaneous callers for the same
-- key spawn one underlying fetch and all receive its result) to solve the
-- "thundering herd" during org-detail prefetch; reused as-is for `sf org
-- list` to fix the same problem on the org-list side -- mashing the
-- lualine icon (or the dashboard's manual refresh key) before the first
-- fetch lands used to spawn one `sf org list`/`sf org display` CLI process
-- per click instead of sharing the one already in flight.
--
-- ttl_seconds = 0 (the default): never serves a stale completed result --
-- every call not currently in flight starts a fresh fetch, but concurrent
-- calls for the same key while one is in flight still coalesce onto it.
-- Use this for "give me the latest data" fetches (e.g. org list), where a
-- manual refresh must not just replay a minutes-old snapshot.
--
-- ttl_seconds > 0: also caches the completed result for that long, so a
-- repeat call within the window returns instantly with no CLI spawn at
-- all. Use this for data that's slow to fetch but doesn't need to be
-- second-fresh (e.g. `sf org display`).
local async_cache = {}

local cache_methods = {}
local cache_metatable = { __index = cache_methods }

--- Creates a new cache. `opts.fetch(key, cb)` must eventually call
--- `cb(result, err)` exactly once per invocation -- may resolve
--- synchronously (before `fetch` returns) or asynchronously.
---@param opts table { ttl_seconds: number|nil, fetch: fun(key: string, cb: fun(result: any, err: string|nil)) }
---@return table cache with :get(key, cb) and :invalidate(key|nil)
function async_cache.new(opts)
  return setmetatable({
    ttl_seconds = opts.ttl_seconds or 0,
    fetch = opts.fetch,
    entries = {}, -- key -> { result, err, fetched_at, fetching, waiters }
  }, cache_metatable)
end

--- Clears one cached entry, or every entry when `key` is omitted.
---@param key string|nil
function cache_methods:invalidate(key)
  if key then
    self.entries[key] = nil
  else
    self.entries = {}
  end
end

--- Fetches `key`, coalescing concurrent callers onto the one in-flight
--- fetch and, when `ttl_seconds` > 0, serving a completed result again
--- without refetching until it expires. Errors are never cached: an
--- errored lookup is retried on the next call regardless of TTL.
---@param key string
---@param cb fun(result: any, err: string|nil)
function cache_methods:get(key, cb)
  local now = vim.uv.now()
  local entry = self.entries[key]

  if entry then
    if entry.fetching then
      table.insert(entry.waiters, cb)
      return
    end
    if self.ttl_seconds > 0 and (now - entry.fetched_at) < self.ttl_seconds * 1000 then
      return cb(entry.result, entry.err)
    end
  end

  self.entries[key] = { result = nil, err = nil, fetched_at = now, fetching = true, waiters = { cb } }

  self.fetch(key, function(result, err)
    local current = self.entries[key]
    if not current then
      -- Invalidated mid-flight: nothing to update, and its waiters (this
      -- callback included) never fire -- same limitation the extracted
      -- get_org_display cache always had; invalidating a key that is
      -- currently fetching is not a supported use case.
      return
    end
    current.result = result
    current.err = err
    current.fetching = false
    local waiters = current.waiters
    current.waiters = {}
    if err or self.ttl_seconds <= 0 then
      self.entries[key] = nil
    end
    for _, waiter in ipairs(waiters) do
      waiter(result, err)
    end
  end)
end

return async_cache
