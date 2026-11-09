local term = require("sf.term")
local util = require("sf.util")
local project = require("sf.project")
local cmd_builder = require("sf.sub.cmd_builder")
local helpers = {}

local metadata = {}

function metadata.pull_md_json()
  helpers.pull_md_json()
end

function metadata.list_md_to_retrieve()
  helpers.list_md_to_retrieve()
end

function metadata.pull_md_type_json()
  helpers.pull_md_type_json()
end

function metadata.list_md_type_to_retrieve()
  helpers.list_md_type_to_retrieve()
end

function metadata.retrieve_apex_under_cursor()
  helpers.retrieve_apex_under_cursor()
end

function metadata.create_apex_class()
  helpers.create_apex_class()
end

function metadata.create_aura_bundle()
  helpers.create_aura_bundle()
end

function metadata.create_lwc_bundle()
  helpers.create_lwc_bundle()
end

function metadata.create_trigger()
  helpers.create_trigger()
end

function metadata.delete_current_apex_remote_and_local()
  helpers.delete_current_apex_remote_and_local()
end

function metadata.rename_apex_class_remote_and_local()
  helpers.rename_apex_class_remote_and_local()
end

-- helper;

---@param name string
helpers.open_apex = function(name)
  util.try_open_file(project.get_apex_folder_path() .. name .. ".cls")
end

helpers.retrieve_apex_under_cursor = function()
  local current_word = vim.fn.expand("<cword>")
  helpers.retrieve_md("ApexClass", current_word, function()
    helpers.open_apex(current_word)
  end)
end

---@param type string
---@param name string
---@param cb function
---@return nil
helpers.retrieve_md = function(type, name, cb)
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end
  util.get_sf_root()

  local type_name = string.format("%s:%s", type, name)
  local cmd = cmd_builder:new():cmd("project"):act("retrieve start"):addParamsNoExpand("-m", type_name):build()
  term.run(cmd, cb, { label = "Retrieve " .. type_name .. " ← " .. util.target_org, category = "retrieve" })
end

helpers.list_md_to_retrieve = function()
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  if not util.is_installed("fzf-lua") then
    return util.show_err("fzf-lua is not installed. Need it to show the list.")
  end

  local md_types = vim.g.sf.types_to_retrieve
  local md = {}
  local md_names = {}

  for _, type in pairs(md_types) do
    local file = string.format("%s_%s.json", type, util.target_org)
    local md_tbl = util.read_file_json_to_tbl(file, util.get_cache_dir())

    if md_tbl ~= nil then
      for _, v in ipairs(md_tbl) do
        if v["manageableState"] ~= "installed" then
          local md_key = v["type"] .. ": " .. v["fullName"]
          md[md_key] = v
          table.insert(md_names, md_key)
        end
      end
    end
  end

  require("fzf-lua").fzf_exec(md_names, {
    actions = {
      ["default"] = function(selected)
        helpers.retrieve_md(md[selected[1]]["type"], md[selected[1]]["fullName"], function()
          helpers.open_apex(md[selected[1]]["fullName"])
        end)
      end,
    },
    winopts = {
      preview = {
        layout = "vertical",
        hidden = false,
        vertical = "down:50%",
      },
    },
    preview = function(items)
      local contents = {}
      vim.tbl_map(function(x)
        table.insert(contents, "\n" .. util.table_to_string_lines(md[x]))
      end, items)
      return contents
    end,
  })
end

helpers.pull_md_json = function()
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end
  local md_types = vim.g.sf.types_to_retrieve
  for _, type in pairs(md_types) do
    helpers.pull_metadata(type)
  end
end

---@param type string
---@return nil
helpers.pull_metadata = function(type)
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  util.create_cache_dir_if_not_exist()

  local md_file = string.format("%s%s_%s.json", util.get_cache_dir(), type, util.target_org)

  -- local cmd = string.format('sf org list metadata -m %s -o %s -f %s', type, util.target_org, md_file)
  local cmd = cmd_builder:new():cmd("org"):act("list metadata"):addParams({ ["-m"] = type, ["-f"] = md_file }):build()
  local msg = string.format("%s retrieved", type)
  local err_msg = string.format("%s retrieve failed: %s", type, md_file)

  util.silent_job_call(cmd, msg, err_msg)
end

helpers.pull_md_type_json = function()
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  util.create_cache_dir_if_not_exist()

  local metadata_types_file = string.format("%s%s.json", util.get_cache_dir(), "metadata-types")
  -- local cmd = string.format('sf org list metadata-types -o %s -f %s', util.target_org, metadata_types_file)
  local cmd = cmd_builder:new():cmd("org"):act("list metadata-types"):addParams("-f", metadata_types_file):build()
  local msg = "Metadata-type file retrieved"
  local err_msg = string.format("Metadata-type retrieve failed: %s", metadata_types_file)

  util.silent_job_call(cmd, msg, err_msg)
end

helpers.list_md_type_to_retrieve = function()
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  if not util.is_installed("fzf-lua") then
    return util.show_err("fzf-lua is not installed. Need it to show the list.")
  end

  local tbl = util.read_file_json_to_tbl("metadata-types.json", util.get_cache_dir())
  local md_types = {}

  for _, obj in pairs(tbl["metadataObjects"]) do
    table.insert(md_types, obj["xmlName"])
  end

  require("fzf-lua").fzf_exec(md_types, {
    actions = {
      ["default"] = function(selected)
        helpers.retrieve_md_type(selected[1])
      end,
    },
  })
end

---@param type string
---@return nil
helpers.retrieve_md_type = function(type)
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  util.get_sf_root()

  -- local cmd = string.format('sf project retrieve start -m \'%s:*\' -o %s', type, util.target_org)
  local cmd = cmd_builder:new():cmd("project"):act("retrieve start"):addParams("-m", type):build()
  term.run(cmd, nil, { label = "Retrieve " .. type .. " ← " .. util.target_org, category = "retrieve" })
end

---@param name string
helpers.generate_class = function(name)
  local path = project.get_apex_folder_path()
  -- local cmd = string.format("sf apex generate class --output-dir %s --name %s", path, name)
  local cmd = cmd_builder:new():cmd("apex"):act("generate class"):addParams({ ["-d"] = path, ["-n"] = name }):localOnly():build()

  util.job_call(cmd, nil, "Something went wrong creating the class", function()
    local absolute_path = path .. name .. ".cls"
    util.try_open_file(absolute_path)
  end)
end

---@param name string
helpers.create_apex_class = function(name)
  util.run_cb_with_input(name, "Enter Class name: ", helpers.generate_class)
end

---@param name string
helpers.generate_aura = function(name)
  -- local cmd = string.format("sf lightning generate component --output-dir %s --name %s --type aura", util.get_default_dir_path() .. "/aura", name)
  local cmd = cmd_builder:new()
      :cmd("lightning")
      :act("generate component")
      :addParams({ ["-d"] = project.get_current_package_dir() .. "aura", ["-n"] = name, ["--type"] = "aura" })
      :localOnly()
      :build()
  util.silent_job_call(cmd, nil, "Something went wrong creating the Aura bundle", function()
    util.try_open_file(project.get_current_package_dir() .. "aura/" .. name .. "/" .. name .. ".cmp")
  end)
end

---@param name string
helpers.create_aura_bundle = function(name)
  util.run_cb_with_input(name, "Enter Aura bundle name: ", helpers.generate_aura)
end

---@param name string
helpers.generate_lwc = function(name)
  -- local cmd = string.format("sf lightning generate component --output-dir %s --name %s --type lwc", util.get_sf_root() .. vim.g.sf.default_dir .. "/lwc", name)
  local cmd = cmd_builder:new()
      :cmd("lightning")
      :act("generate component")
      :addParams({ ["-d"] = project.get_current_package_dir() .. "lwc", ["-n"] = name, ["--type"] = "lwc" })
      :localOnly()
      :build()
  util.silent_job_call(cmd, nil, "Something went wrong creating the LWC bundle", function()
    util.try_open_file(project.get_current_package_dir() .. "lwc/" .. name .. "/" .. name .. ".js")
  end)
end

---@param name string
helpers.create_lwc_bundle = function(name)
  util.run_cb_with_input(name, "Enter LWC bundle name: ", helpers.generate_lwc)
end

---@param name string
helpers.generate_trigger = function(name)
  local cmd = cmd_builder:new()
      :cmd("apex")
      :act("generate")
      :subact("trigger")
      :addParams({ ["-d"] = project.get_current_package_dir() .. "triggers", ["-n"] = name })
      :localOnly()
      :buildAsTable()

  util.silent_system_call(cmd, nil, "Something went wrong creating the trigger", function()
    util.try_open_file(project.get_current_package_dir() .. "triggers/" .. name .. ".trigger")
  end)
end

---@param name string
helpers.create_trigger = function(name)
  util.run_cb_with_input(name, "Enter Trigger name: ", helpers.generate_trigger)
end

helpers.delete_current_apex_remote_and_local = function()
  local current_file, class_name = util.validate_apex_and_org()
  if not current_file then
    return
  end

  local confirm_msg = string.format(
    "Delete '%s' from both org '%s' and local? (y/N): ",
    class_name,
    util.target_org
  )

  vim.ui.input({ prompt = confirm_msg }, function(input)
    if input ~= "y" and input ~= "Y" then
      util.show("Deletion cancelled")
      return
    end

    util.show("Deleting '" .. class_name .. "'...")
    local type_name = string.format("ApexClass:%s", class_name)
    local cmd = cmd_builder:new()
        :cmd("project")
        :act("delete source")
        :addParamsNoExpand("-m", type_name)
        :addParams("-r")
        :build()

    term.run(cmd, function(_, _, exit_code)
      if exit_code ~= 0 then
        util.show_err("Failed to delete class '" .. class_name .. "'")
        return
      end

      util.close_buf_if_file_gone(current_file)
      util.show("Apex '" .. class_name .. "' deleted from org and local")
    end, { label = "Delete " .. class_name, category = "deploy" })
  end)
end

helpers.rename_apex_class_remote_and_local = function()
  local current_file, current_name = util.validate_apex_and_org()
  if not current_file then
    return
  end

  vim.ui.input({ prompt = "Enter new class name: " }, function(new_name)
    if util.is_empty_str(new_name) then
      util.show("Rename cancelled")
      return
    end

    helpers.rename_apex_impl(current_file, current_name, new_name)
  end)
end

helpers.rename_apex_impl = function(old_file_path, old_name, new_name)
  -- Step 1: Read old file content
  local old_content = util.read_local_file(old_file_path, function()
    util.show_err("Failed to read old class file: " .. old_file_path)
  end)

  if old_content == nil then
    return
  end

  -- Step 2: Parse and replace class name and constructor using regex
  local content_str = table.concat(old_content, "\n")

  -- Replace class declaration: public class OldName
  content_str = content_str:gsub("class%s+" .. old_name .. "%s", "class " .. new_name .. " ")

  -- Replace constructor: public OldName()
  content_str = content_str:gsub("([%s(])" .. old_name .. "%s*%(", "%1" .. new_name .. "(")

  -- Step 3: Create new apex class (background)
  local path = project.get_apex_folder_path()
  local cmd = cmd_builder:new()
      :cmd("apex")
      :act("generate class")
      :addParams({ ["-d"] = path, ["-n"] = new_name })
      :localOnly()
      :build()

  util.silent_job_call(cmd, nil, "Failed to create new apex class '" .. new_name .. "'", function()
    local new_file_path = path .. new_name .. ".cls"

    -- Step 4: Update the created file with old content
    local ok, err = pcall(vim.fn.writefile, vim.split(content_str, "\n"), new_file_path)
    if not ok then
      util.show_err("Failed to write content to new class file: " .. err)
      return
    end

    util.try_open_file(new_file_path)

    -- Step 5: Deploy new class to org via terminal
    local type_name = string.format("ApexClass:%s", new_name)
    local deploy_cmd = cmd_builder:new()
        :cmd("project")
        :act("deploy start")
        :addParamsNoExpand("-m", type_name)
        :build()

    term.run(deploy_cmd, function(_, _, exit_code)
      if exit_code ~= 0 then
        util.show_err("Deployment failed with exit code: " .. exit_code)
        return
      end

      util.show("Deleting old class '" .. old_name .. "'...")
      helpers.delete_old_class_after_rename(old_name)
    end, { label = "Deploy " .. new_name .. " → " .. util.target_org, category = "deploy" })
  end)
end


helpers.delete_old_class_after_rename = function(old_name)
  local type_name = string.format("ApexClass:%s", old_name)
  local cmd = cmd_builder:new()
      :cmd("project")
      :act("delete source")
      :addParamsNoExpand("-m", type_name)
      :addParams("-r")
      :build()

  util.silent_job_call(cmd, "Old class '" .. old_name .. "' deleted from org and local!",
    "Failed to delete old class: " .. old_name)
end

return metadata
