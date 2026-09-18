-- Apex Replay Debugger integration (nvim-dap), replicating what the VS Code
-- extension host does before it spawns the DAP adapter: fetch
-- `lineBreakpointInfo` from apex_ls and read the log file into
-- `logFileContents` (this adapter version does not read the log itself, see
-- docs/replay-debugger-notes.md).

local U = require("sf.util")

local Debug = {}
local H = {}

--- @return table
local function cfg()
  return vim.g.sf.replay_debugger
end

--- Find the "apexReplayDebug.js" adapter entry point.
--- @return string|nil
H.resolve_adapter_path = function()
  local c = cfg()
  if not U.is_empty_str(c.adapter_path) then
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
    if U.file_readable(path) then
      return path
    end
  end

  return nil
end

--- Ask apex_ls for the valid breakpoint lines per Apex type, required by the
--- adapter's `launch` request as `lineBreakpointInfo`.
--- @param cb fun(info: table[]|nil, err: string|nil)
H.fetch_line_breakpoint_info = function(cb)
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

      result = H.filter_ignored(result)
      H.cache = result
      H.write_cache(result)
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
H.ignore_pattern_to_lua = function(pattern)
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
H.load_forceignore_patterns = function()
  local path = U.get_sf_root() .. ".forceignore"
  if not U.file_readable(path) then
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
H.filter_ignored = function(info)
  local patterns = H.load_forceignore_patterns()
  if #patterns == 0 then
    return info
  end

  local root = U.get_sf_root()
  local filtered = {}
  for _, entry in ipairs(info) do
    local ok, fname = pcall(vim.uri_to_fname, entry.uri)
    local rel = ok and (fname:sub(1, #root) == root and fname:sub(#root + 1) or fname) or entry.uri
    local ignored = false
    for _, pattern in ipairs(patterns) do
      if rel:find(H.ignore_pattern_to_lua(pattern)) then
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

--- @param info table[]
H.write_cache = function(info)
  local dir = U.get_plugin_folder_path() .. "debug/"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "-p")
  end
  vim.fn.writefile({ vim.json.encode(info) }, dir .. "lineBreakpointInfo.json")
end

--- Resolve the adapter's "apexReplayDebug.js" path (explicit config, else
--- auto-detected). Returns nil if not found. Exposed for `:checkhealth`.
--- @return string|nil
Debug.resolve_adapter_path = H.resolve_adapter_path

--- Register the "apex-replay" adapter with nvim-dap. Safe to call even when
--- nvim-dap isn't installed.
Debug.setup_dap = function()
  H.setup_cache_invalidation()

  local ok, dap = pcall(require, "dap")
  if not ok then
    return
  end

  dap.adapters["apex-replay"] = function(callback, _config)
    local adapter_path = H.resolve_adapter_path()
    if not adapter_path then
      return U.show_err(
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
        if H.cache then
          local c = vim.deepcopy(config)
          c.lineBreakpointInfo = H.cache
          return on_config(c)
        end
        H.fetch_line_breakpoint_info(function(info, err)
          if not info then
            return U.show_err("sf.nvim: " .. err)
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
    return U.show_err("sf.nvim: nvim-dap not installed.")
  end

  if not U.file_readable(log_path) then
    return U.show_err("sf.nvim: log file not readable: " .. log_path)
  end

  local c = cfg()
  if vim.fn.executable(c.node_path) ~= 1 then
    return U.show_err("sf.nvim: node executable not found: " .. c.node_path)
  end
  if not H.resolve_adapter_path() then
    return U.show_err("sf.nvim: Apex Replay Debugger adapter not found. Set `replay_debugger.adapter_path`.")
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

  H.set_last_log(vim.fn.fnamemodify(log_path, ":p"))
end

--- Clear the `debugger/lineBreakpoints` cache whenever an Apex file is saved,
--- since line numbers may have shifted.
H.setup_cache_invalidation = function()
  local group = vim.api.nvim_create_augroup("SfReplayDebugger", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.cls", "*.trigger" },
    callback = function()
      H.cache = nil
    end,
  })
end

--- @param path string absolute path
H.set_last_log = function(path)
  H.last_log_path = path
  local dir = U.get_plugin_folder_path() .. "debug/"
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "-p")
  end
  vim.fn.writefile({ path }, dir .. "last_log.txt")
end

--- Resolve `replay_debugger.log_globs` into absolute glob patterns.
--- @return string[]
H.log_search_globs = function()
  local root = U.get_sf_root()
  local plugin_dir = U.get_plugin_folder_path()
  local resolved = {}
  for _, pat in ipairs(cfg().log_globs) do
    if pat:sub(1, 1) == "/" then
      table.insert(resolved, pat)
    elseif pat:sub(1, #"<plugin_folder>/") == "<plugin_folder>/" then
      table.insert(resolved, plugin_dir .. pat:sub(#"<plugin_folder>/" + 1))
    else
      table.insert(resolved, root .. pat)
    end
  end
  return resolved
end

--- Find local replay-ready logs, newest first, deduplicated by absolute path.
--- @return { path: string, mtime: integer }[]
H.list_local_logs = function()
  local seen = {}
  local logs = {}
  for _, pattern in ipairs(H.log_search_globs()) do
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
    return U.show_warn("sf.nvim: current buffer is not a .log file")
  end
  Debug.launch(path)
end

--- Pick a local log (from `.sfdx/tools/debug/` and the plugin's downloaded
--- logs folder, see `replay_debugger.log_globs`) and launch it.
Debug.replay_local_log = function()
  local root = U.get_sf_root()
  local logs = H.list_local_logs()
  if #logs == 0 then
    return U.show_warn("sf.nvim: no local logs found (checked replay_debugger.log_globs)")
  end

  local display = function(log)
    local rel = log.path:sub(1, #root) == root and log.path:sub(#root + 1) or log.path
    return string.format("%s | %s", rel, os.date("%Y-%m-%d %H:%M:%S", log.mtime))
  end

  if U.is_installed("fzf-lua") then
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
  local dir = U.get_sf_root() .. ".sfdx/tools/debug/logs/"
  require("sf.org").pick_log(dir, Debug.launch)
end

--- Relaunch the most recently launched replay log.
Debug.replay_last_log = function()
  local path = H.last_log_path
  if not path then
    local file = U.get_plugin_folder_path() .. "debug/last_log.txt"
    if U.file_readable(file) then
      path = vim.fn.readfile(file)[1]
    end
  end
  if not path or not U.file_readable(path) then
    return U.show_warn("sf.nvim: no previous replay log found")
  end
  Debug.launch(path)
end

--- Clear the cached `lineBreakpointInfo` and fetch a fresh copy from apex_ls.
Debug.refresh_breakpoint_info = function()
  H.cache = nil
  H.fetch_line_breakpoint_info(function(info, err)
    if not info then
      return U.show_err("sf.nvim: " .. err)
    end
    U.show(string.format("sf.nvim: breakpoint info refreshed (%d types)", #info))
  end)
end

return Debug
