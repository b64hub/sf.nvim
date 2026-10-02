-- Two small, composable cache primitives -- the one place in the plugin
-- that knows about disk layout/storage specifics, so callers (org.lua,
-- org_dashboard.lua, rest_api.lua, ...) never shell out to
-- vim.fn.readfile/writefile/mkdir directly.
--
-- `cache.new`: generic TTL + in-flight-coalescing cache for one kind of
-- keyed async fetch. Originally extracted from rest_api.lua's
-- `get_org_display` cache, which needed exactly this shape (multiple
-- simultaneous callers for the same key spawn one underlying fetch and all
-- receive its result) to solve the "thundering herd" during org-detail
-- prefetch; reused as-is for `sf org list` to fix the same problem on the
-- org-list side -- mashing the lualine icon (or the dashboard's manual
-- refresh key) before the first fetch lands used to spawn one `sf org
-- list`/`sf org display` CLI process per click instead of sharing the one
-- already in flight. Purely in-memory: nothing here ever touches disk.
--
-- `cache.disk_store`: a JSON file (or one of several, chosen per key) is
-- loaded into memory at most once and treated as authoritative from then
-- on -- every `:set` mutates that in-memory table and dumps the WHOLE
-- table back to disk in one synchronous call, rather than re-reading the
-- file and merging. This is what makes it safe for several keys to share
-- one file (e.g. every view the org dashboard caches for one org, in one
-- `orgs/<alias>.json`): a read-modify-write that spans an async fetch is
-- the actual race (two such sequences for different keys can interleave
-- at the await boundary and the second write clobbers the first's
-- contribution -- single-threaded Neovim does NOT protect against this,
-- the suspension point is the vulnerability, not CPU parallelism), and
-- mutate-then-dump has no suspension point between the mutation and the
-- write, so it can't lose a concurrent sibling key's update. Cross-process
-- races (two Neovim instances touching the same file) are deliberately
-- not handled the same way file-per-key already didn't handle them --
-- ponytail: last-write-wins across nvim instances, no advisory lock. Every
-- file involved is atomically renamed into place (see
-- util.write_cache_json), so the loser's write is simply overwritten with
-- a complete, valid file, never a torn one, and the next read just
-- refetches -- add a lockfile only if shared-project workflows actually
-- show lost snapshots.

local util = require("sf.util")

local cache = {}

local cache_methods = {}
local cache_metatable = { __index = cache_methods }

--- Creates a new in-memory cache. `opts.fetch(key, cb)` must eventually
--- call `cb(result, err)` exactly once per invocation -- may resolve
--- synchronously (before `fetch` returns) or asynchronously.
---@param opts table { ttl_seconds: number|nil, fetch: fun(key: string, cb: fun(result: any, err: string|nil)) }
---@return table cache with :get(key, cb) and :invalidate(key|nil)
function cache.new(opts)
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

local disk_store_methods = {}
local disk_store_metatable = { __index = disk_store_methods }

--- A disk-backed key-value store, addressed through `locate(key)`.
---@param locate fun(key: string): string, string|nil returns (file, subkey)
---  for `key` -- `file` is a path relative to the cache dir (e.g.
---  "orgs/myorg.json"); when `subkey` is non-nil it addresses one key
---  inside that file's JSON object (several cache keys sharing one file),
---  when nil the file's whole content IS the value (e.g. a single-key
---  store like a last-known-good snapshot).
---@return table store with :get(key), :set(key, value), :invalidate(key),
---  and :delete_file(file)
function cache.disk_store(locate)
  return setmetatable({ locate = locate, loaded = {} }, disk_store_metatable)
end

--- Characters outside `[%w%-_.]` become `_`. Required, not cosmetic: an
--- alias is user-settable CLI config and may contain `/`, which would
--- otherwise turn a cache filename into a path traversal / a write into a
--- nonexistent subdirectory (silently swallowed by write_cache_json's
--- pcall, so that org would just never persist).
---@param s string
---@return string
function cache.sanitize_filename(s)
  return (s:gsub("[^%w%-_.]", "_"))
end

---@param file string
---@return table
function disk_store_methods:_load(file)
  if self.loaded[file] == nil then
    self.loaded[file] = util.read_cache_json(file) or {}
  end
  return self.loaded[file]
end

--- @param key string
--- @return any|nil the value currently on disk for `key`, or nil on a
---   cache miss (never read, or the file/subkey doesn't exist yet)
function disk_store_methods:get(key)
  local file, subkey = self.locate(key)
  local tbl = self:_load(file)
  if subkey == nil then
    return next(tbl) ~= nil and tbl or nil
  end
  return tbl[subkey]
end

--- Persist `value` for `key`: mutate the in-memory table for its file,
--- then dump the WHOLE table back to disk in one call -- see the module
--- doc comment for why this never races a sibling key sharing the file.
---@param key string
---@param value any
function disk_store_methods:set(key, value)
  local file, subkey = self.locate(key)
  if subkey == nil then
    self.loaded[file] = value
    util.write_cache_json(file, value)
    return
  end
  local tbl = self:_load(file)
  tbl[subkey] = value
  util.write_cache_json(file, tbl)
end

--- Drops one key from its file (mutate + dump, same as `:set`).
---@param key string
function disk_store_methods:invalidate(key)
  local file, subkey = self.locate(key)
  if subkey == nil then
    self:delete_file(file)
    return
  end
  local tbl = self:_load(file)
  tbl[subkey] = nil
  util.write_cache_json(file, tbl)
end

--- Deletes an entire file this store owns, regardless of key shape -- e.g.
--- when an org is removed, every view cached for it should go with it
--- instead of leaking on disk forever.
---@param file string
function disk_store_methods:delete_file(file)
  self.loaded[file] = nil
  util.delete_cache_file(file)
end

return cache
