local util = {}

util.last_tests = ""
util.target_org = ""

--- Set the target org: updates `util.target_org` (so existing readers keep
--- working) and the cached statusline state in `sf.state`.
---@param alias string
---@param meta table|nil { is_scratch, is_prod, is_sandbox, username }
util.set_target_org = function(alias, meta)
  util.target_org = alias
  require("sf.state").set_target_org(alias, meta)
end

---@param msg string
util.show = function(msg)
  vim.notify(msg, vim.log.levels.INFO, { title = "sf.nvim" })
end

---@param msg string
util.show_err = function(msg)
  vim.notify(msg, vim.log.levels.ERROR, { title = "sf.nvim" })
end

---@param msg string
util.show_warn = function(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "sf.nvim" })
end

---@param msg string
util.notify_then_error = function(msg)
  local sf_msg = "Sf: " .. msg
  util.show_warn(sf_msg)
  error(sf_msg)
end

util.get = function()
  if util.is_empty_str(util.target_org) then
    error("Sf: Target_org empty!")
  end

  return util.target_org
end

util.str_ends_with = function(str, ending)
  return ending == "" or str:sub(- #ending) == ending
end

--- Human-readable size, e.g. `512 B` / `48.2 KB` / `3.1 MB`.
---@param bytes number
---@return string
util.format_bytes = function(bytes)
  if bytes < 1024 then
    return string.format("%d B", bytes)
  elseif bytes < 1024 * 1024 then
    return string.format("%.1f KB", bytes / 1024)
  end
  return string.format("%.1f MB", bytes / (1024 * 1024))
end

util.combine_path = function(path1, path2)
  return path1 .. "/" .. path2
end

--- Returns a normalized path, optionally with a trailing separator
-- @param path string The path to normalize
-- @param trailing_slash boolean Whether to ensure trailing slash (default: false)
-- @return string Normalized path
util.normalize_path = function(path, trailing_slash)
  local normalized = vim.fs.normalize(path)

  -- Add trailing slash if requested and not already present
  if trailing_slash and normalized:sub(-1) ~= "/" then
    normalized = normalized .. "/"
  end

  return normalized
end

--- Returns the normalized default directory path
-- @return string Normalized path with trailing separator
util.get_default_dir_path = function()
  local dir_path = util.combine_path(util.get_sf_root(), vim.g.sf.default_dir)
  return util.normalize_path(dir_path, true)
end

util.get_plugin_folder_path = function()
  local folder_path = util.combine_path(util.get_sf_root(), vim.g.sf.plugin_folder_name)
  return util.normalize_path(folder_path, true)
end

util.create_plugin_folder_if_not_exist = function()
  local cache_folder = util.get_plugin_folder_path()
  if vim.fn.isdirectory(cache_folder) == 0 then
    local ok, result = pcall(vim.fn.mkdir, cache_folder, "-p")
    if not ok then
      util.show_err("cache folder creation failed!")
      util.show_err("error: " .. result)
    end
  end
end

util.get_sf_root = function()
  local root_patterns = { ".forceignore", "sfdx-project.json" }

  local start_path = vim.fs.dirname(vim.api.nvim_buf_get_name(0))

  -- If start_path is '.', use the current working directory instead
  if start_path == "." then
    start_path = vim.fn.getcwd()
  end

  local root = vim.fs.dirname(vim.fs.find(root_patterns, {
    upward = true,
    stop = vim.uv.os_homedir(),
    path = start_path,
  })[1])

  if root == nil then
    error("File not in a sf project folder")
  end

  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end

  return root
end

util.is_sf_cmd_installed = function()
  if vim.fn.executable("sf") ~= 1 then
    util.notify_then_error("sf cli not found")
  end
end

util.is_ctags_installed = function()
  if vim.fn.executable("ctags") ~= 1 then
    util.notify_then_error("ctags cli not found")
  end
end

---@param tbl table
util.is_table_empty = function(tbl)
  if vim.tbl_isempty(tbl) then
    util.notify_then_error("Empty table")
  end
end

---@param s string|nil
---@return boolean
util.is_empty_str = function(s)
  return s == nil or s == ""
end

---@param tbl table
---@param value string
---@return number|nil
util.list_find = function(tbl, value)
  for i, v in pairs(tbl) do
    if v == value then
      return i
    end
  end
end

---@param cmd string
---@param msg string|nil
---@param err_msg string|nil
---@param cb function|nil
util.silent_job_call = function(cmd, msg, err_msg, cb)
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_exit = function(_, code)
      if code == 0 and msg ~= nil then
        vim.notify(msg, vim.log.levels.INFO)
      elseif code ~= 0 and err_msg ~= nil then
        vim.notify(err_msg, vim.log.levels.ERROR)
      end

      if code == 0 and cb ~= nil then
        cb()
      end
    end,
  })
end

---@param cmd string
---@param msg string|nil
---@param err_msg string|nil
---@param cb function|nil
util.job_call = function(cmd, msg, err_msg, cb)
  vim.notify("| Async job starts...", vim.log.levels.INFO)
  util.silent_job_call(cmd, msg, err_msg, cb)
end

---@param cmd table
---@param msg string|nil
---@param err_msg string|nil
---@param cb function|nil
---@param on_settle function|nil optional (ok, obj) callback fired right after the msg/err_msg notification, for internal use (progress handle)
util.silent_system_call = function(cmd, msg, err_msg, cb, on_settle)
  local system_callback = function(obj)
    if obj.code ~= 0 then
      if err_msg ~= nil then
        util.show_err(err_msg)
      end
      if on_settle then
        on_settle(false, obj)
      end
      return
    end

    if msg ~= nil then
      util.show(msg)
    end

    if on_settle then
      on_settle(true, obj)
    end

    if cb ~= nil then
      cb(obj)
    end
  end

  vim.system(cmd, {}, vim.schedule_wrap(system_callback))
end

---@param cmd table
---@param msg string|nil
---@param err_msg string|nil
---@param cb function|nil
util.system_call = function(cmd, msg, err_msg, cb, pre_msg)
  local label = pre_msg or "Async job"
  local Progress = require("sf.ui.progress")
  local handle = Progress.start({ msg = label })

  local on_settle = function(ok)
    if ok then
      handle:finish(true, msg or (label .. " done"))
    else
      handle:finish(false, err_msg or (label .. " failed"))
    end
  end

  util.silent_system_call(cmd, msg, err_msg, cb, on_settle)
end

util.get_apex_name = function()
  return vim.split(vim.fn.expand("%:t"), ".", { trimempty = true, plain = true })[1]
end

-- Copy current file name without dot-after, e.g. copy "Hello" from "Hello.cls"
util.copy_apex_name = function()
  local file_name = util.get_apex_name()
  vim.fn.setreg("*", file_name)
  vim.notify(string.format('"%s" copied.', file_name), vim.log.levels.INFO)
end

---@param arg string|nil
---@param prompt string
---@param cb function
util.run_cb_with_input = function(arg, prompt, cb)
  if arg ~= nil then
    cb(arg)
  else
    vim.ui.input({ prompt = prompt }, function(input)
      if input ~= nil then
        cb(input)
      else
        return
      end
    end)
  end
end

---@param tbl table
---@return string
util.table_to_string_lines = function(tbl)
  local inspect_opts = {
    newline = "",
    indent = "",
  }

  local result = vim.inspect(tbl, inspect_opts)
  result = string.gsub(result, "^{(.*)}$", "%1") -- Remove surrounding braces
  result = string.gsub(result, "%s*=%s*", ": ")  -- Change " = " between key and value to ": "
  result = string.gsub(result, ",%s*", "\n")     -- Add newlines after each key=val pair, and remove commas
  result = string.gsub(result, '"', "")          -- Remove quotation marks around string values
  return result
end

---@param plugin_name string
---@return boolean
util.is_installed = function(plugin_name)
  return pcall(require, plugin_name)
end

---@param name string
---@return table|nil
util.read_file_in_plugin_folder = function(name)
  util.create_plugin_folder_if_not_exist()

  local path = util.get_plugin_folder_path()
  return util.read_file_json_to_tbl(name, path)
end

---@param name string
---@param path string
---@return table|nil
util.read_file_json_to_tbl = function(name, path)
  local absolute_path = path .. name
  local err_fn = function()
    vim.notify_once("File not found: " .. absolute_path, vim.log.levels.WARN)
  end
  local content = util.read_local_file(absolute_path, err_fn)
  if content == nil then
    return nil
  end

  return util.parse_from_json_to_tbl(content)
end

--- Reads the content of a local file.
--- @param absolute_path string The path to the file.
--- @param err_fn function|nil Optional function to call in case of an error.
--- @return string|nil The file content or nil if an error occurred.
util.read_local_file = function(absolute_path, err_fn)
  local ok, content = pcall(vim.fn.readfile, absolute_path)

  if not ok then
    if type(err_fn) == "function" then
      return err_fn()
    else
      util.notify_then_error("File not found: " .. absolute_path)
    end
  end

  return content
end

---@param content string
---@return table|nil
util.parse_from_json_to_tbl = function(content)
  local json = table.concat(content)
  local ok, tbl = pcall(vim.json.decode, json, {})
  if not ok then
    util.notify_then_error("Parse file from json to tbl failed: " .. absolute_path)
  end

  return tbl
end

---@param name string
---@return boolean
util.is_apex_loaded_in_buf = function(name)
  local buf_num = util.get_apex_buf_num(name)
  return buf_num ~= -1 and vim.fn.bufloaded(buf_num) == 1
end

---@param name string
---@return integer
util.get_apex_buf_num = function(name)
  local path = vim.g.sf.default_dir .. "classes/" .. name
  return util.get_buf_num(path)
end

---@param path string
---@return integer
util.get_buf_num = function(path)
  return vim.fn.bufnr(path)
end

---@param path string
util.try_open_file = function(path)
  if util.file_readable(path) then
    local open_new_file = string.format(":e! %s", path)
    vim.cmd(open_new_file)
  end
end

---@param path string
---@return boolean
util.file_readable = function(path)
  if vim.fn.filereadable(path) == 0 then
    return false
  end
  return true
end

---@param param any
---@return boolean
util.is_function = function(param)
  return type(param) == "function"
end

-- this func is supposed to be only manually called by the plugin developer to generate plugin help.txt
util.gen_doc = function()
  if not util.is_installed("mini.doc") then
    util.notify_then_error("mini.doc not installed.")
  end

  -- explicit output: mini.doc otherwise derives the filename from cwd's
  -- directory name, which breaks in a git worktree checkout (folder name
  -- doesn't match "sf").
  require("mini.doc").generate({
    "lua/sf/init.lua",
  }, "doc/sf.txt")
end

util.is_windows_os = function()
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return true
  end
  return false
end

util.close_buf_if_file_gone = function(file_path)
  if util.file_readable(file_path) then
    util.show_err(string.format("File still exists: %s", file_path))
    return false
  end

  local buf_num = vim.fn.bufnr(file_path)
  if buf_num ~= -1 and vim.api.nvim_buf_is_valid(buf_num) then
    vim.api.nvim_buf_delete(buf_num, { force = true })
    return true
  end

  return false
end

---Check if local apex class files (.cls and .cls-meta.xml) were deleted
---@param cls_file string The path to the .cls file
---@return boolean, boolean cls_deleted, meta_deleted - true if file is gone
util.check_apex_files_deleted = function(cls_file)
  local meta_file = cls_file .. "-meta.xml"

  local cls_deleted = not util.file_readable(cls_file)
  local meta_deleted = not util.file_readable(meta_file)

  return cls_deleted, meta_deleted
end

--- Validate that current buffer is an Apex file and target org is set
--- Also sets up sf root
--- @return string|nil file_path of current buffer, or nil if validation fails
--- @return string|nil class_name of current file, or nil if validation fails
util.validate_apex_and_org = function()
  local current_file = vim.api.nvim_buf_get_name(0)
  local filetype = vim.bo.filetype

  -- Check if file is apex (includes .cls and .trigger)
  if filetype ~= "apex" and not current_file:match("%.cls$") and not current_file:match("%.trigger$") then
    util.show_warn("Current buffer is not an Apex file (.cls or .trigger)")
    return nil, nil
  end

  -- Check if target org is set
  if util.is_empty_str(util.target_org) then
    util.show_err("Target_org empty!")
    return nil, nil
  end

  -- Set up sf root
  util.get_sf_root()

  -- Get class/trigger name
  local class_name = util.get_apex_name()

  return current_file, class_name
end

return util
