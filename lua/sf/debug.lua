-- Apex Replay Debugger integration (nvim-dap), replicating what the VS Code
-- extension host does before it spawns the DAP adapter: fetch
-- `lineBreakpointInfo` from apex_ls and read the log file into
-- `logFileContents` (this adapter version does not read the log itself, see
-- docs/replay-debugger-notes.md).

local util = require("sf.util")
local Api = require("sf.sub.rest_api")

local Debug = {}
local helpers = {}

local DEBUG_LEVEL_NAME = "ReplayDebuggerLevels"

--- @return table
local function cfg()
  return vim.g.sf.replay_debugger
end

--- Find the "apexReplayDebug.js" adapter entry point.
--- @return string|nil
helpers.resolve_adapter_path = function()
  local c = cfg()
  if not util.is_empty_str(c.adapter_path) then
    return c.adapter_path
  end

  local candidates = {
    vim.fn.stdpath("data") .. "/sf-nvim/apex-replay-debugger/extension/dist/apexReplayDebug.js",
  }

  -- ponytail: picks the vscode extension dir with the newest mtime rather than
  -- parsing/comparing semver folder-name suffixes; good enough to find "the
  -- one you just installed".
  local vscode_matches = vim.fn.glob(
    vim.fn.expand("~/.vscode/extensions/salesforce.salesforcedx-vscode-apex-replay-debugger-*"),
    false,
    true
  )
  table.sort(vscode_matches, function(a, b)
    local sa, sb = vim.uv.fs_stat(a), vim.uv.fs_stat(b)
    return (sa and sa.mtime.sec or 0) > (sb and sb.mtime.sec or 0)
  end)
  for _, dir in ipairs(vscode_matches) do
    table.insert(candidates, dir .. "/extension/dist/apexReplayDebug.js")
  end

  for _, path in ipairs(candidates) do
    if util.file_readable(path) then
      return path
    end
  end

  return nil
end

--- Ask apex_ls for the valid breakpoint lines per Apex type, required by the
--- adapter's `launch` request as `lineBreakpointInfo`.
--- @param cb fun(info: table[]|nil, err: string|nil)
helpers.fetch_line_breakpoint_info = function(cb)
  local clients = vim.lsp.get_clients({ name = "apex_ls" })
  if #clients == 0 then
    return cb(nil, "apex_ls not running - open a .cls file first")
  end

  local done = false
  vim.defer_fn(function()
    if done then
      return
    end
    done = true
    cb(nil, "apex_ls did not answer debugger/lineBreakpoints within " .. cfg().lsp_timeout .. "ms")
  end, cfg().lsp_timeout)

  clients[1]:request("debugger/lineBreakpoints", nil, function(err, result)
    if done then
      return
    end
    done = true

    vim.schedule(function()
      if err then
        return cb(nil, "apex_ls error: " .. vim.inspect(err))
      end
      if not result or vim.tbl_isempty(result) then
        return cb(
          nil,
          "apex_ls returned no breakpoint info - is the project indexed? "
            .. "If this persists, delete the stale apex.db under .sfdx/tools/ and restart apex_ls."
        )
      end

      result = helpers.filter_ignored(result)
      helpers.cache = result
      cb(result, nil)
    end)
  end)
end

--- Convert one `.forceignore` line into an unanchored Lua search pattern.
--- ponytail: approximates gitignore/forceignore glob semantics (`**`, `*`,
--- leading "/") rather than full spec compliance (no negation, no character
--- classes; a bare "dist" can also false-match a real dir named "distfoo").
--- Good enough to keep generated build output out of the debugger; swap for
--- a real gitignore matcher if that ever bites.
helpers.ignore_pattern_to_lua = function(pattern)
  local anchored = pattern:sub(1, 1) == "/"
  if anchored then
    pattern = pattern:sub(2)
  end
  local escaped = pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%1")
  escaped = escaped:gsub("%*%*", "\1")
  escaped = escaped:gsub("%*", "[^/]*")
  escaped = escaped:gsub("\1", ".*")
  return anchored and ("^" .. escaped) or escaped
end

--- @return string[]
helpers.load_forceignore_patterns = function()
  local path = util.get_sf_root() .. ".forceignore"
  if not util.file_readable(path) then
    return {}
  end
  local patterns = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    line = vim.trim(line)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      table.insert(patterns, line)
    end
  end
  return patterns
end

--- Drop `lineBreakpointInfo` entries whose file is `.forceignore`d (e.g.
--- generated `dist/` build output duplicating real source). Without this,
--- the adapter's typeref->file mapping is last-one-wins, so stepping can
--- resolve into the ignored copy instead of the real source file.
--- @param info table[]
--- @return table[]
helpers.filter_ignored = function(info)
  local patterns = helpers.load_forceignore_patterns()
  if #patterns == 0 then
    return info
  end

  local root = util.get_sf_root()
  local filtered = {}
  for _, entry in ipairs(info) do
    local ok, fname = pcall(vim.uri_to_fname, entry.uri)
    local rel = ok and (fname:sub(1, #root) == root and fname:sub(#root + 1) or fname) or entry.uri
    local ignored = false
    for _, pattern in ipairs(patterns) do
      if rel:find(helpers.ignore_pattern_to_lua(pattern)) then
        ignored = true
        break
      end
    end
    if not ignored then
      table.insert(filtered, entry)
    end
  end
  return filtered
end

--- Resolve the adapter's "apexReplayDebug.js" path (explicit config, else
--- auto-detected). Returns nil if not found. Exposed for `:checkhealth`.
--- @return string|nil
Debug.resolve_adapter_path = helpers.resolve_adapter_path

--- Register the "apex-replay" adapter with nvim-dap. Safe to call even when
--- nvim-dap isn't installed.
Debug.setup_dap = function()
  helpers.setup_cache_invalidation()

  local ok, dap = pcall(require, "dap")
  if not ok then
    return
  end

  dap.adapters["apex-replay"] = function(callback, _config)
    local adapter_path = helpers.resolve_adapter_path()
    if not adapter_path then
      return util.show_err(
        "sf.nvim: Apex Replay Debugger adapter not found. Set `replay_debugger.adapter_path` "
          .. "or install it (see docs/replay-debugger-notes.md)."
      )
    end

    callback({
      type = "executable",
      command = cfg().node_path,
      args = { adapter_path },
      enrich_config = function(config, on_config)
        if config.lineBreakpointInfo then
          return on_config(config)
        end
        if helpers.cache then
          local c = vim.deepcopy(config)
          c.lineBreakpointInfo = helpers.cache
          return on_config(c)
        end
        helpers.fetch_line_breakpoint_info(function(info, err)
          if not info then
            return util.show_err("sf.nvim: " .. err)
          end
          local c = vim.deepcopy(config)
          c.lineBreakpointInfo = info
          on_config(c)
        end)
      end,
    })
  end
end

--- Launch the Apex Replay Debugger against a local log file.
--- @param log_path string absolute path to a .log file
Debug.launch = function(log_path)
  local ok, dap = pcall(require, "dap")
  if not ok then
    return util.show_err("sf.nvim: nvim-dap not installed.")
  end

  if not util.file_readable(log_path) then
    return util.show_err("sf.nvim: log file not readable: " .. log_path)
  end

  local c = cfg()
  if vim.fn.executable(c.node_path) ~= 1 then
    return util.show_err("sf.nvim: node executable not found: " .. c.node_path)
  end
  if not helpers.resolve_adapter_path() then
    return util.show_err("sf.nvim: Apex Replay Debugger adapter not found. Set `replay_debugger.adapter_path`.")
  end

  -- The adapter reads `logFileContents` (plain text), not `logFile` - see
  -- docs/replay-debugger-notes.md.
  local contents = table.concat(vim.fn.readfile(log_path), "\n")
  local log_file_name = vim.fn.fnamemodify(log_path, ":t")

  dap.run({
    type = "apex-replay",
    request = "launch",
    name = "Apex Replay: " .. log_file_name,
    logFileContents = contents,
    logFilePath = vim.fn.fnamemodify(log_path, ":p"),
    logFileName = log_file_name,
    stopOnEntry = c.stop_on_entry,
    trace = c.trace,
  })

  helpers.set_last_log(vim.fn.fnamemodify(log_path, ":p"))
end

--- Clear the `debugger/lineBreakpoints` cache whenever an Apex file is saved,
--- since line numbers may have shifted.
helpers.setup_cache_invalidation = function()
  local group = vim.api.nvim_create_augroup("SfReplayDebugger", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.cls", "*.trigger" },
    callback = function()
      helpers.cache = nil
    end,
  })
end

--- @param path string absolute path
helpers.set_last_log = function(path)
  helpers.last_log_path = path
  util.write_cache_text("debug/last_log.txt", path)
end

--- Resolve `replay_debugger.log_globs` into absolute glob patterns.
--- @return string[]
helpers.log_search_globs = function()
  local root = util.get_sf_root()
  local cache_dir = util.get_cache_dir()
  local resolved = {}
  for _, pat in ipairs(cfg().log_globs) do
    if pat:sub(1, 1) == "/" then
      table.insert(resolved, pat)
    elseif pat:sub(1, #"<cache_dir>/") == "<cache_dir>/" then
      table.insert(resolved, cache_dir .. pat:sub(#"<cache_dir>/" + 1))
    else
      table.insert(resolved, root .. pat)
    end
  end
  return resolved
end

--- Find local replay-ready logs, newest first, deduplicated by absolute path.
--- @return { path: string, mtime: integer }[]
helpers.list_local_logs = function()
  local seen = {}
  local logs = {}
  for _, pattern in ipairs(helpers.log_search_globs()) do
    for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
      local abs = vim.fn.fnamemodify(path, ":p")
      if not seen[abs] then
        seen[abs] = true
        local stat = vim.uv.fs_stat(abs)
        table.insert(logs, { path = abs, mtime = stat and stat.mtime.sec or 0 })
      end
    end
  end
  table.sort(logs, function(a, b)
    return a.mtime > b.mtime
  end)
  return logs
end

--- Debug current log buffer, if the current buffer is a `.log`/`sflog` file.
Debug.replay_current_log = function()
  local path = vim.api.nvim_buf_get_name(0)
  if vim.bo.filetype ~= "sflog" and not path:match("%.log$") then
    return util.show_warn("sf.nvim: current buffer is not a .log file")
  end
  Debug.launch(path)
end

--- Pick a local log (from `.sfdx/tools/debug/` and the plugin's downloaded
--- logs folder, see `replay_debugger.log_globs`) and launch it.
Debug.replay_local_log = function()
  local root = util.get_sf_root()
  local logs = helpers.list_local_logs()
  if #logs == 0 then
    return util.show_warn("sf.nvim: no local logs found (checked replay_debugger.log_globs)")
  end

  local display = function(log)
    local rel = log.path:sub(1, #root) == root and log.path:sub(#root + 1) or log.path
    return string.format("%s | %s", rel, os.date("%Y-%m-%d %H:%M:%S", log.mtime))
  end

  if util.is_installed("fzf-lua") then
    local entries = {}
    local by_entry = {}
    for _, log in ipairs(logs) do
      local entry = display(log)
      table.insert(entries, entry)
      by_entry[entry] = log.path
    end
    require("fzf-lua").fzf_exec(entries, {
      previewer = "builtin",
      actions = {
        ["default"] = function(selected)
          Debug.launch(by_entry[selected[1]])
        end,
      },
    })
  else
    vim.ui.select(logs, {
      prompt = "Replay log:",
      format_item = display,
    }, function(choice)
      if choice then
        Debug.launch(choice.path)
      end
    end)
  end
end

--- Pick a log from the org (fzf-lua), download it into
--- `.sfdx/tools/debug/logs/` and launch it.
Debug.replay_org_log = function()
  local dir = util.get_sf_root() .. ".sfdx/tools/debug/logs/"
  require("sf.org").pick_log(dir, Debug.launch)
end

--- Relaunch the most recently launched replay log.
Debug.replay_last_log = function()
  local path = helpers.last_log_path
  if not path then
    path = util.read_cache_text("debug/last_log.txt")
  end
  if not path or not util.file_readable(path) then
    return util.show_warn("sf.nvim: no previous replay log found")
  end
  Debug.launch(path)
end

--- Clear the cached `lineBreakpointInfo` and fetch a fresh copy from apex_ls.
Debug.refresh_breakpoint_info = function()
  helpers.cache = nil
  helpers.fetch_line_breakpoint_info(function(info, err)
    if not info then
      return util.show_err("sf.nvim: " .. err)
    end
    util.show(string.format("sf.nvim: breakpoint info refreshed (%d types)", #info))
  end)
end

--- ponytail: matches on a raw 15/18-char User Id ("005..."); anything else is
--- treated as a username/email and resolved via a query. Good enough since
--- Salesforce usernames never start with "005".
--- @param session table
--- @param user string|nil username/email/Id; nil = the org's own user
--- @param cb fun(user_id: string|nil, err: string|nil)
helpers.resolve_target_user = function(session, user, cb)
  if not util.is_empty_str(user) and user:match("^005%w%w%w%w%w%w%w%w%w%w%w%w%w%w%w?%w?%w?$") then
    return cb(user, nil)
  end

  local username = util.is_empty_str(user) and session.username or user
  Api.query(session, string.format("SELECT Id FROM User WHERE Username='%s'", username), function(records, err)
    if not records or #records == 0 then
      return cb(nil, err or ("no user found with username '" .. username .. "'"))
    end
    cb(records[1].Id, nil)
  end)
end

--- Find the `ReplayDebuggerLevels` DebugLevel (ApexCode=FINEST, Visualforce=FINER),
--- creating it if missing.
--- @param session table
--- @param cb fun(debug_level_id: string|nil, err: string|nil)
helpers.find_or_create_debug_level = function(session, cb)
  Api.query(session, string.format("SELECT Id FROM DebugLevel WHERE DeveloperName='%s'", DEBUG_LEVEL_NAME), function(records, err)
    if not records then
      return cb(nil, err)
    end
    if #records > 0 then
      return cb(records[1].Id, nil)
    end

    Api.create(session, "DebugLevel", {
      DeveloperName = DEBUG_LEVEL_NAME,
      MasterLabel = DEBUG_LEVEL_NAME,
      ApexCode = "FINEST",
      Visualforce = "FINER",
    }, cb)
  end)
end

--- ISO8601 UTC timestamp `minutes` from now (or now, if `minutes` is nil/0).
--- @param minutes number|nil
--- @return string
helpers.iso_utc = function(minutes)
  return os.date("!%Y-%m-%dT%H:%M:%S.000Z", os.time() + (minutes or 0) * 60)
end

--- Renews the user's existing TraceFlag (whether still active or already
--- expired) if one exists for that user/LogType, creating one only when
--- they have none at all - one TraceFlag record per user, ever, instead of
--- a fresh (soon-orphaned) row every time a previous one expired.
--- @param session table
--- @param user_id string
--- @param debug_level_id string
--- @param minutes number
--- @param cb fun(ok: boolean, err: string|nil)
helpers.upsert_trace_flag = function(session, user_id, debug_level_id, minutes, cb)
  local soql = string.format(
    "SELECT Id, ExpirationDate FROM TraceFlag WHERE TracedEntityId='%s' AND LogType='DEVELOPER_LOG' ORDER BY ExpirationDate DESC LIMIT 1",
    user_id
  )
  Api.query(session, soql, function(records, err)
    if not records then
      return cb(false, err)
    end

    local existing = records[1]

    if existing then
      return Api.update(session, "TraceFlag", existing.Id, {
        DebugLevelId = debug_level_id,
        ExpirationDate = helpers.iso_utc(minutes),
      }, cb)
    end

    Api.create(session, "TraceFlag", {
      TracedEntityId = user_id,
      DebugLevelId = debug_level_id,
      LogType = "DEVELOPER_LOG",
      StartDate = helpers.iso_utc(0),
      ExpirationDate = helpers.iso_utc(minutes),
    }, function(id, create_err)
      cb(id ~= nil, create_err)
    end)
  end)
end

--- Parse a Salesforce datetime string (e.g. "2024-01-01T00:00:00.000+0000")
--- into a Unix timestamp.
--- @param s string
--- @return integer
helpers.parse_sf_datetime = function(s)
  local y, mo, d, h, mi, se = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return 0
  end
  -- os.time(table) assumes *local* time; the parsed fields are UTC, so
  -- correct by the current local/UTC offset.
  local t = { year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(se) }
  local now = os.time()
  local utc_now = os.date("!*t", now)
  local local_now = os.date("*t", now)
  utc_now.isdst = local_now.isdst
  local offset = os.difftime(os.time(local_now), os.time(utc_now))
  return os.time(t) + offset
end

--- Salesforce enforces a 24h max TraceFlag duration.
local MAX_TRACE_FLAG_MINUTES = 24 * 60

--- Enable Apex replay-ready debug logging: creates (or reuses) a
--- `ReplayDebuggerLevels` DebugLevel and an active TraceFlag, for the current org
--- user by default.
--- @param opts number|table|nil number = minutes (back-compat shorthand), or
---   `{ minutes = number, user = string, alias = string }`. `user` is a
---   username/email/Id to trace instead of the org's own user. `alias` is an
---   org alias to target instead of the global target_org. minutes defaults to
---   `replay_debugger.trace_flag_hours * 60`, capped at 24h.
Debug.enable_replay_logging = function(opts)
  opts = type(opts) == "number" and { minutes = opts } or (opts or {})
  local minutes = math.min(opts.minutes or (cfg().trace_flag_hours * 60), MAX_TRACE_FLAG_MINUTES)

  if not Api.has_curl() then
    return util.show_err("sf.nvim: `curl` is required for replay logging (Tooling API calls).")
  end
  if not opts.alias and util.is_empty_str(util.target_org) then
    return util.show_err("sf.nvim: Target_org empty!")
  end

  -- Three sequential Tooling API round trips (resolve user -> debug level ->
  -- trace flag) follow, easily 1-3s -- a progress handle gives immediate
  -- "it's working" feedback instead of the notify-only final result the
  -- user would otherwise only see (or miss) after that delay.
  local handle = require("sf.ui.progress").start({ msg = "Enabling replay logging..." })

  -- `Api.get_session(nil, cb)` behaves identically to `Api.get_session(cb)`
  -- (its own dispatch treats a non-function first argument as the alias,
  -- and a nil alias skips the `set_org` override) -- so a single call
  -- covers both the alias and no-alias cases, no branch needed.
  Api.get_session(opts.alias, function(session, err)
    if not session then
      return handle:finish(false, "sf.nvim: " .. err)
    end
    helpers.enable_replay_logging_with_session(session, opts.user, minutes, handle)
  end)
end

--- @param session table already-fetched org session (avoids a redundant
---   `sf org display` call when the caller already has one, e.g. the user
---   picker below)
--- @param user string|nil
--- @param minutes number
--- @param handle table progress handle (`sf.ui.progress.start`) driving the
---   "Enabling replay logging..." toast/spinner while these calls run
helpers.enable_replay_logging_with_session = function(session, user, minutes, handle)
  helpers.resolve_target_user(session, user, function(user_id, user_err)
    if not user_id then
      return handle:finish(false, "sf.nvim: " .. user_err)
    end
    helpers.find_or_create_debug_level(session, function(debug_level_id, dl_err)
      if not debug_level_id then
        return handle:finish(false, "sf.nvim: " .. dl_err)
      end
      helpers.upsert_trace_flag(session, user_id, debug_level_id, minutes, function(ok, tf_err)
        if not ok then
          return handle:finish(false, "sf.nvim: failed to enable replay logging" .. (tf_err and (": " .. tf_err) or ""))
        end
        handle:finish(true, string.format("sf.nvim: replay logging enabled for %s (%d min)", user or session.username, minutes))
        require("sf.state").refresh_trace_flags()
      end)
    end)
  end)
end

--- Interactively pick an active user (fzf-lua, else `vim.ui.select`) and
--- enable replay logging for them.
--- @param minutes number|nil
Debug.pick_user_and_enable_replay_logging = function(minutes)
  if not Api.has_curl() then
    return util.show_err("sf.nvim: `curl` is required for replay logging (Tooling API calls).")
  end
  if util.is_empty_str(util.target_org) then
    return util.show_err("sf.nvim: Target_org empty!")
  end

  local resolved_minutes = math.min(minutes or (cfg().trace_flag_hours * 60), MAX_TRACE_FLAG_MINUTES)

  Api.get_session(function(session, err)
    if not session then
      return util.show_err("sf.nvim: " .. err)
    end
    Api.query_std(session, "SELECT Username, Name FROM User WHERE IsActive = true ORDER BY Name LIMIT 50", function(records, qerr)
      if not records or #records == 0 then
        return util.show_err("sf.nvim: " .. (qerr or "no active users found"))
      end

      local entries, by_entry = {}, {}
      for _, user_record in ipairs(records) do
        local entry = string.format("%s (%s)", user_record.Name, user_record.Username)
        table.insert(entries, entry)
        by_entry[entry] = user_record.Username
      end

      local on_choice = function(username)
        if username then
          local handle = require("sf.ui.progress").start({ msg = "Enabling replay logging..." })
          helpers.enable_replay_logging_with_session(session, username, resolved_minutes, handle)
        end
      end

      if util.is_installed("fzf-lua") then
        require("fzf-lua").fzf_exec(entries, {
          actions = {
            ["default"] = function(selected)
              on_choice(by_entry[selected[1]])
            end,
          },
        })
      else
        vim.ui.select(entries, { prompt = "Enable replay logging for:" }, function(choice)
          on_choice(choice and by_entry[choice])
        end)
      end
    end)
  end)
end

--- Disable replay logging by expiring the active `TraceFlag` for the given
--- user (default: the current org user).
--- @param user string|nil username/email/Id
Debug.disable_replay_logging = function(user)
  if not Api.has_curl() then
    return util.show_err("sf.nvim: `curl` is required for replay logging (Tooling API calls).")
  end
  if util.is_empty_str(util.target_org) then
    return util.show_err("sf.nvim: Target_org empty!")
  end

  local handle = require("sf.ui.progress").start({ msg = "Disabling replay logging..." })

  Api.get_session(function(session, err)
    if not session then
      return handle:finish(false, "sf.nvim: " .. err)
    end
    helpers.resolve_target_user(session, user, function(user_id, user_err)
      if not user_id then
        return handle:finish(false, "sf.nvim: " .. user_err)
      end

      local soql = string.format(
        "SELECT Id FROM TraceFlag WHERE TracedEntityId='%s' AND LogType='DEVELOPER_LOG' ORDER BY ExpirationDate DESC LIMIT 1",
        user_id
      )
      Api.query(session, soql, function(records, query_err)
        if not records or #records == 0 then
          return handle:finish(false, "sf.nvim: " .. (query_err or "no replay logging TraceFlag found for that user"))
        end
        Api.delete(session, "TraceFlag", records[1].Id, function(ok, delete_err)
          if not ok then
            return handle:finish(false, "sf.nvim: " .. (delete_err or "failed to disable replay logging"))
          end
          handle:finish(true, "sf.nvim: replay logging disabled")
          require("sf.state").refresh_trace_flags()
        end)
      end)
    end)
  end)
end

--- Ask (via `vim.ui.select`) whether to enable or disable replay logging,
--- based on whether a TraceFlag is currently active -- the same prompt the
--- lualine trace-flag component uses on click, now also reachable without a
--- mouse (see |Sf.toggle_replay_debug_logging|).
Debug.toggle_replay_logging = function()
  local flags = require("sf.state").get_trace_flags()
  if #flags > 0 then
    vim.ui.select({ "Yes", "No" }, { prompt = "Disable replay logging for target_org?" }, function(choice)
      if choice == "Yes" then
        Debug.disable_replay_logging()
      end
    end)
  else
    vim.ui.select({ "Yes", "No" }, { prompt = "Enable replay logging for target_org?" }, function(choice)
      if choice == "Yes" then
        Debug.enable_replay_logging()
      end
    end)
  end
end

--- Run the Apex test under the cursor, then download and launch the newest
--- log produced by that run. Warns (rather than failing) if replay logging
--- doesn't look enabled, since the log may then lack the required levels.
Debug.run_test_and_replay = function()
  require("sf.test").run_current_test(function()
    helpers.launch_newest_org_log()
  end)
end

helpers.launch_newest_org_log = function()
  Api.get_session(function(session, err)
    if not session then
      return util.show_err("sf.nvim: " .. err)
    end
    Api.query(session, "SELECT Id FROM ApexLog ORDER BY StartTime DESC LIMIT 1", function(records, qerr)
      if not records or #records == 0 then
        return util.show_warn("sf.nvim: no logs found in org - run `:SF debug enable` first? (" .. (qerr or "") .. ")")
      end

      local dir = util.get_sf_root() .. ".sfdx/tools/debug/logs/"
      require("sf.org").download_log(records[1].Id, dir, Debug.launch)
    end)
  end)
end

--- Download the Apex Replay Debugger adapter from Open VSX into
--- `stdpath("data")/sf-nvim/apex-replay-debugger/` (the default auto-detect
--- location, see `helpers.resolve_adapter_path`). Requires `curl` and `unzip`.
Debug.install_adapter = function()
  if not Api.has_curl() or vim.fn.executable("unzip") ~= 1 then
    return util.show_err("sf.nvim: `curl` and `unzip` are required to install the adapter.")
  end

  local meta_url = "https://open-vsx.org/api/salesforce/salesforcedx-vscode-apex-replay-debugger/latest"
  util.show("sf.nvim: fetching adapter metadata...")
  vim.system(
    { "curl", "-sL", meta_url },
    {},
    vim.schedule_wrap(function(obj)
      if obj.code ~= 0 or util.is_empty_str(obj.stdout) then
        return util.show_err("sf.nvim: failed to fetch adapter metadata")
      end

      local ok, meta = pcall(vim.json.decode, obj.stdout)
      local download_url = ok and vim.tbl_get(meta, "downloads", "universal")
      local version = ok and meta.version
      if not download_url then
        return util.show_err("sf.nvim: could not find a download URL in adapter metadata")
      end

      local dest_dir = vim.fn.stdpath("data") .. "/sf-nvim/apex-replay-debugger"
      local tmp_vsix = vim.fn.tempname() .. ".vsix"
      util.show("sf.nvim: downloading adapter v" .. version .. "...")

      vim.system(
        { "curl", "-sL", "-o", tmp_vsix, download_url },
        {},
        vim.schedule_wrap(function(dl)
          if dl.code ~= 0 then
            return util.show_err("sf.nvim: failed to download adapter")
          end

          vim.fn.mkdir(dest_dir, "p")
          vim.system(
            { "unzip", "-oq", tmp_vsix, "-d", dest_dir },
            {},
            vim.schedule_wrap(function(uz)
              vim.fn.delete(tmp_vsix)
              if uz.code ~= 0 then
                return util.show_err("sf.nvim: failed to unzip adapter: " .. (uz.stderr or ""))
              end
              util.show(string.format("sf.nvim: installed Apex Replay Debugger adapter v%s to %s", version, dest_dir))
            end)
          )
        end)
      )
    end)
  )
end

Debug.__test = helpers

return Debug
