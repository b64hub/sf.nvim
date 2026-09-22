local util = require("sf.util")
local cmd_builder = require("sf.sub.cmd_builder")

local helpers = {}
local Org = {}

function Org.fetch_org_list()
  helpers.fetch_org_list()
end

function Org.set_target_org()
  helpers.set_target_org()
end

function Org.set_global_target_org()
  helpers.set_global_target_org()
end

function Org.diff_in_target_org()
  helpers.diff_in_target_org()
end

function Org.diff_in_org()
  helpers.diff_in_org()
end

function Org.open()
  -- local cmd = 'sf org open -o ' .. util.get()
  local cmd = cmd_builder:new():cmd("org"):act("open"):build()
  local err_msg = "Command failed: " .. cmd
  util.job_call(cmd, nil, err_msg)
end

function Org.open_current_file()
  -- local cmd = vim.fn.expandcmd('sf org open --source-file "%:p" -o ') .. util.get()
  local cmd = cmd_builder:new():cmd("org"):act("open"):addParams("-f", "%:p"):build()
  local err_msg = "Command failed: " .. cmd
  util.job_call(cmd, nil, err_msg)
end

--- Set the target org for a specific alias (local or global) and update cached state.
---@param alias string
---@param global boolean whether to set globally (~/.sf/config.json) or locally (.sf/config.json)
function Org.set_target_org_to(alias, global)
  local ok, err = helpers.write_target_org_to_config(alias, global)
  if not ok then
    return util.show_err(
      string.format("%s - set target_org failed! %s", alias, err)
    )
  end
  helpers.mark_default(alias)
  local record = nil
  for _, record_entry in ipairs(helpers.orgs) do
    if record_entry.alias == alias then
      record = record_entry
      break
    end
  end
  util.set_target_org(alias, record)
end

--- Open a specific org (not necessarily the target_org) in the browser.
---@param alias string
function Org.open_org(alias)
  helpers.open_org(alias)
end

function Org.pull_log()
  helpers.pick_org_log(util.get_plugin_folder_path() .. "logs/", function(path)
    util.try_open_file(path)
  end)
end

--- Pick a log from the org's log list (fzf-lua) and download it into `dir`.
--- Reused by the replay debugger to download into the sfdx-conventional
--- `.sfdx/tools/debug/logs/` folder instead.
---@param dir string absolute directory to download the log into (created if missing)
---@param on_done fun(path: string) called with the downloaded log's local path
function Org.pick_log(dir, on_done)
  helpers.pick_org_log(dir, on_done)
end

--- Download a single log by Id into `dir` (created if missing).
--- @param log_id string
--- @param dir string
--- @param on_done fun(path: string)
function Org.download_log(log_id, dir, on_done)
  helpers.download_log(log_id, dir, on_done)
end

-- helpers;

---@param log_id string
---@param dir string
---@param on_done fun(path: string)
helpers.download_log = function(log_id, dir, on_done)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "-p")
  end
  util.show("Downloading log...")
  local get_cmd = cmd_builder:new()
      :cmd("apex")
      :act("get")
      :subact("log")
      :addParams("-i", log_id)
      :addParams("-d", dir)
      :buildAsTable()
  util.silent_system_call(get_cmd, nil, "Failed to get logs from org", function()
    on_done(dir .. log_id .. ".log")
  end)
end

---@param dir string
---@param on_done fun(path: string)
helpers.pick_org_log = function(dir, on_done)
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end
  if not util.is_installed("fzf-lua") then
    return util.show_err("fzf-lua is not installed. Need it to show the list.")
  end

  local log_id

  local on_list = function(obj)
    local ok, log_table = pcall(vim.json.decode, obj.stdout, {})
    if not ok then
      return util.show_err("Failed to parse log JSON!")
    end

    local logs = {}
    local log_names = {}

    if #log_table["result"] == 0 then
      return util.show_warn("No logs found in org")
    end

    for _, v in ipairs(log_table["result"]) do
      local name = string.format(
        "%s | %s | %s | %s",
        v["LogUser"]["Name"],
        string.gsub(v["StartTime"], "T", " "),
        util.format_bytes(v["LogLength"]),
        v["Status"]
      )
      table.insert(log_names, name)
      v["User"] = v["LogUser"]["Name"]
      v["attributes"] = nil
      v["LogUser"] = nil
      logs[name] = v
    end

    require("fzf-lua").fzf_exec(log_names, {
      winopts = {
        preview = {
          layout = "vertical",
          hidden = false,
          vertical = "down:50%",
        },
      },
      preview = function(items)
        local contents = {}
        local prepend_char = ""
        vim.tbl_map(function(x)
          table.insert(contents, prepend_char .. util.table_to_string_lines(logs[x]))
          prepend_char = "\n"
        end, items)
        return contents
      end,
      actions = {
        ["default"] = function(selected)
          log_id = logs[selected[1]]["Id"]
          helpers.download_log(log_id, dir, on_done)
        end,
      },
    })
  end

  local cmd_tbl = cmd_builder:new():cmd("apex"):act("list"):subact("log"):addParams("--json"):buildAsTable()
  util.system_call(cmd_tbl, nil, "Failed to get logs from org", on_list, "Querying logs...")
end

helpers.orgs = {} -- array of { alias, username, is_scratch, is_sandbox, is_prod, is_default, expiration_date }

--- Open a specific org (not necessarily the target_org) in the browser.
---@param alias string
helpers.open_org = function(alias)
  local cmd = cmd_builder:new():cmd("org"):act("open"):set_org(alias):build()
  local err_msg = "Command failed: " .. cmd
  util.job_call(cmd, nil, err_msg)
end

helpers.clean_org_cache = function()
  helpers.orgs = {}
end

--- Flip the `is_default` flag onto `alias` and off every other cached org,
--- so the picker's `●` marker stays in sync right after a target-org
--- change instead of only after the next `:SF org list`.
---@param alias string
helpers.mark_default = function(alias)
  for _, r in ipairs(helpers.orgs) do
    r.is_default = r.alias == alias
  end
end

--- Write "target-org" into the project-local `.sf/config.json` (or the
--- global `~/.sf/config.json` when `global` is true), merging into whatever
--- is already there. Synchronous file I/O -- same config file `sf config
--- set target-org` itself writes, without paying for a CLI/Node spinup.
---@param alias string
---@param global boolean
---@return boolean ok, string|nil err
helpers.write_target_org_to_config = function(alias, global)
  local path
  if global then
    local home = vim.uv.os_homedir()
    if not home then
      return false, "could not resolve home directory"
    end
    path = home .. "/.sf/config.json"
  else
    local ok_root, root = pcall(util.get_sf_root)
    if not ok_root or not root then
      return false, "not in a sfdx project folder"
    end
    path = root .. ".sf/config.json"
  end

  local dir = vim.fs.dirname(path)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  local config = {}
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if ok_read then
    local ok_json, parsed = pcall(vim.json.decode, table.concat(lines, "\n"))
    if ok_json and type(parsed) == "table" then
      config = parsed
    end
  end

  config["target-org"] = alias

  local ok_write = pcall(vim.fn.writefile, { vim.json.encode(config) }, path)
  if not ok_write then
    return false, "could not write " .. path
  end
  return true
end

helpers.set_target_org = function()
  if vim.tbl_isempty(helpers.orgs) then
    return util.show_err("No orgs available. Run :SF org list first.")
  end

  require("sf.ui.org_explorer").pick(helpers.orgs, {
    prompt = "Local target_org",
    on_open = function(record)
      helpers.open_org(record.alias)
    end,
    on_choice = function(record)
      local org = record.alias
      local ok, err = helpers.write_target_org_to_config(org, false)
      if not ok then
        return util.show_err(org .. " - set target_org failed! " .. err)
      end
      helpers.mark_default(org)
      util.set_target_org(org, record)
    end,
  })
end

helpers.set_global_target_org = function()
  if vim.tbl_isempty(helpers.orgs) then
    return util.show_err("No orgs available. Run :SF org list first.")
  end

  require("sf.ui.org_explorer").pick(helpers.orgs, {
    prompt = "Global target_org",
    on_open = function(record)
      helpers.open_org(record.alias)
    end,
    on_choice = function(record)
      local org = record.alias
      local ok, err = helpers.write_target_org_to_config(org, true)
      if not ok then
        return util.show_err(string.format("Global set target_org [%s] failed! %s", org, err))
      end
      helpers.mark_default(org)
      util.set_target_org(org, record)
      vim.notify("Global target_org set: " .. org, vim.log.levels.INFO)
    end,
  })
end

---@param data string
helpers.store_orgs = function(data)
  local s = ""
  for _, v in ipairs(data) do
    s = s .. v
  end

  local org_data = vim.json.decode(s, {}).result.nonScratchOrgs
  local scratch_org_data = vim.json.decode(s, {}).result.scratchOrgs

  for i = 1, #scratch_org_data do
    org_data[#org_data + 1] = scratch_org_data[i]
  end

  for _, v in pairs(org_data) do
    local alias = v.alias or v.username
    local is_scratch = v.isScratch == true
    local is_sandbox = v.isSandbox == true
    local record = {
      alias = alias,
      username = v.username,
      is_scratch = is_scratch,
      is_sandbox = is_sandbox,
      is_prod = not is_scratch and not is_sandbox,
      is_default = v.isDefaultUsername == true,
      is_default_devhub = v.isDefaultDevHubUsername == true,
      expiration_date = v.expirationDate,
    }

    table.insert(helpers.orgs, record)
  end

  -- `isDefaultUsername` above only reflects the *global* default on recent
  -- `sf` CLI versions, not a project-local `target-org` -- resolve the
  -- statusline's org from disk instead, now that `helpers.orgs` has metadata to
  -- match the alias against.
  Org.refresh_target_org_from_disk()
end

helpers.fetch_and_store_orgs = function()
  vim.fn.jobstart("sf org list --json --skip-connection-status", {
    stdout_buffered = true,
    on_stdout = function(_, data)
      helpers.store_orgs(data)
    end,
  })
end

helpers.fetch_org_list = function()
  util.is_sf_cmd_installed()

  helpers.clean_org_cache()
  helpers.fetch_and_store_orgs()
end

--- Read "target-org" from the project's `.sf/config.json`, falling back to
--- the global `~/.sf/config.json`. File reads only, no `sf` CLI call, so
--- this is cheap enough to run on `FocusGained`/`DirChanged`.
---@return string|nil
helpers.read_target_org_from_config_files = function()
  local candidates = {}

  local ok_root, root = pcall(util.get_sf_root)
  if ok_root and root then
    table.insert(candidates, root .. ".sf/config.json")
  end

  local home = vim.uv.os_homedir()
  if home then
    table.insert(candidates, home .. "/.sf/config.json")
  end

  for _, path in ipairs(candidates) do
    local ok_read, lines = pcall(vim.fn.readfile, path)
    if ok_read then
      local ok_json, tbl = pcall(vim.json.decode, table.concat(lines, "\n"))
      if ok_json and tbl and tbl["target-org"] then
        return tbl["target-org"]
      end
    end
  end

  return nil
end

--- Pick up a target-org change made outside Nvim (e.g. `sf config set
--- target-org` in another terminal), by reading the sf CLI's own config
--- files rather than shelling out. Safe to call frequently (e.g. on
--- `FocusGained`); never errors.
Org.refresh_target_org_from_disk = function()
  local ok, alias = pcall(helpers.read_target_org_from_config_files)
  if ok and alias and alias ~= util.target_org then
    local record
    for _, r in ipairs(helpers.orgs) do
      if r.alias == alias then
        record = r
        break
      end
    end
    helpers.mark_default(alias)
    util.set_target_org(alias, record)
  end
end

helpers.diff_in_target_org = function()
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  helpers.diff_in(util.target_org)
end

helpers.diff_in_org = function()
  if vim.tbl_isempty(helpers.orgs) then
    return util.show_err("No orgs available. Run :SF org list first.")
  end

  require("sf.ui.org_explorer").pick(helpers.orgs, {
    prompt = "Diff in org",
    on_open = function(record)
      helpers.open_org(record.alias)
    end,
    on_choice = function(record)
      helpers.diff_in(record.alias)
    end,
  })
end

---@param org string
helpers.diff_in = function(org)
  local file_name = vim.fn.expand("%:t")
  local metadataType = helpers.get_metadata_type(vim.fn.expand("%:p"))
  local file_name_no_ext = helpers.get_file_name_without_extension(file_name)
  local temp_path = util.get_plugin_folder_path() .. "diffs/"

  -- Create diffs folder if it doesn't exist
  if vim.fn.isdirectory(temp_path) == 0 then
    vim.fn.mkdir(temp_path, "p")
  end

  local cmd = cmd_builder:new()
      :cmd("project")
      :act("retrieve start")
      :addParams({
        ["-m"] = metadataType .. ":" .. file_name_no_ext,
        ["-r"] = temp_path,
        ["--json"] = "",
      })
      :set_org(org)
      :build()

  local stdout_data = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      vim.list_extend(stdout_data, data)
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        return util.show_err("Retrieve failed: " .. org)
      end

      local json_str = table.concat(stdout_data, "\n")
      local ok, parsed = pcall(vim.fn.json_decode, json_str)
      if not ok or not parsed then
        return util.show_err("Retrieve failed: could not parse sf CLI output")
      end

      local files = (parsed.result or {}).files or {}
      local retrieved_file = nil
      for _, f in ipairs(files) do
        if f.state == "Failed" then
          return util.show_err("Retrieve failed: " .. (f.error or "unknown error"))
        end
        if f.filePath and vim.fn.fnamemodify(f.filePath, ":t") == file_name then
          retrieved_file = f.filePath
        end
      end

      -- fallback for edge cases where filePath doesn't match directly
      if not retrieved_file then
        retrieved_file = helpers.find_file(temp_path, file_name)
      end

      if not retrieved_file then
        return util.show_err("Retrieve succeeded but file not found locally")
      end

      vim.notify("Retrieve success: " .. org, vim.log.levels.INFO)
      vim.cmd("vert diffsplit " .. vim.fn.fnameescape(retrieved_file))
      vim.bo[0].buflisted = false
    end,
  })
end

---@param fileName string
---@return any
helpers.get_file_name_without_extension = function(fileName)
  -- (.-) makes the match non-greedy
  -- see https://www.lua.org/manual/5.3/manual.html#6.4.1
  return fileName:match("(.-)%.%w+%-meta%.xml$") or fileName:match("(.-)%.[^%.]+$")
end

helpers.metadata_types = {
  ["lwc"] = "LightningComponentBundle",
  ["aura"] = "AuraDefinitionBundle",
  ["classes"] = "ApexClass",
  ["triggers"] = "ApexTrigger",
  ["pages"] = "ApexPage",
  ["components"] = "ApexComponent",
  ["flows"] = "Flow",
  ["objects"] = "CustomObject",
  ["layouts"] = "Layout",
  ["permissionsets"] = "PermissionSet",
  ["profiles"] = "Profile",
  ["labels"] = "CustomLabels",
  ["staticresources"] = "StaticResource",
  ["sites"] = "CustomSite",
  ["applications"] = "CustomApplication",
  ["roles"] = "UserRole",
  ["groups"] = "Group",
  ["queues"] = "Queue",
}

---@param filePath string
---@return string | nil
helpers.get_metadata_type = function(filePath)
  for key, metadataType in pairs(helpers.metadata_types) do
    if filePath:find(key) then
      return metadataType
    end
  end
  return nil
end

---@param path string
---@param target string
---@return string|nil
helpers.find_file = function(path, target)
  local scanner = vim.loop.fs_scandir(path)
  -- if scanner is nil, then path is not a valid dir
  if scanner then
    local file, type = vim.loop.fs_scandir_next(scanner)
    if path:sub(-1) ~= "/" then
      path = path .. "/"
    end
    while file do
      if type == "directory" then
        local found = helpers.find_file(path .. file, target)
        if found then
          return found
        end
      elseif file == target then
        return path .. file
      end
      -- get the next file and type
      file, type = vim.loop.fs_scandir_next(scanner)
    end
  end
end

Org.__test = helpers

return Org
