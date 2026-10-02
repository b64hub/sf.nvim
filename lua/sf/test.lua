local term = require("sf.term")
local cmd_builder = require("sf.sub.cmd_builder")
local ts = require("sf.ts")
local util = require("sf.util")
local test_sign = require("sf.sub.test_sign")

local helpers = {}
local picker = {}
local Test = {}

Test.is_sign_enabled = test_sign.is_enabled
Test.refresh_and_place_sign = test_sign.refresh_and_place
Test.setup_sign = test_sign.setup
Test.toggle_sign = test_sign.toggle
Test.uncovered_jump_forward = test_sign.uncovered_jump_forward
Test.uncovered_jump_backward = test_sign.uncovered_jump_backward
Test.refresh_current_file_covered_percent = test_sign.refresh_current_file_covered_percent
Test.covered_percent = function()
  return test_sign.covered_percent
end

Test.open = function()
  picker.open()
end

Test.run_current_test_with_coverage = function()
  local ok_class, test_class_name = pcall(helpers.validateInTestClass)
  if not ok_class then
    return
  end

  local ok_method, test_name = pcall(helpers.validateInTestMethod)
  if not ok_method then
    return
  end

  local cmd = cmd_builder:new()
    :cmd("apex")
    :act("run test")
    :addParams({
      ["-t"] = test_class_name .. "." .. test_name,
      ["-r"] = "human",
      ["-w"] = vim.g.sf.sf_wait_time,
      ["-c"] = "",
    })
    :build()

  util.last_tests = cmd
  term.run(cmd, helpers.save_test_coverage_locally, { label = test_class_name .. "." .. test_name, category = "test" })
end

---@param cb function|nil
---@return nil
Test.run_current_test = function(cb)
  local ok_class, test_class_name = pcall(helpers.validateInTestClass)
  if not ok_class then
    return
  end

  local ok_method, test_name = pcall(helpers.validateInTestMethod)
  if not ok_method then
    return
  end

  -- local cmd = string.format("sf apex run test --tests %s.%s -r human -w 5 %s-o %s", test_class_name, test_name, extraParams, util.get())
  local cmd = cmd_builder:new()
    :cmd("apex")
    :act("run test")
    :addParams({
      ["-t"] = test_class_name .. "." .. test_name,
      ["-r"] = "human",
      ["-w"] = vim.g.sf.sf_wait_time,
      ["--concise"] = "",
    })
    :build()

  util.last_tests = cmd
  term.run(cmd, cb, { label = test_class_name .. "." .. test_name, category = "test" })
end

Test.run_all_tests_in_this_file_with_coverage = function()
  local ok_class, test_class_name = pcall(helpers.validateInTestClass)
  if not ok_class then
    return
  end

  local cmd = cmd_builder:new()
    :cmd("apex")
    :act("run test")
    :addParams({
      ["-n"] = test_class_name,
      ["-r"] = "human",
      ["-w"] = vim.g.sf.sf_wait_time,
      ["-c"] = "",
    })
    :build()

  util.last_tests = cmd
  term.run(cmd, helpers.save_test_coverage_locally, { label = test_class_name, category = "test" })
end

---@param cb function
---@return nil
Test.run_all_tests_in_this_file = function(cb)
  local ok_class, test_class_name = pcall(helpers.validateInTestClass)
  if not ok_class then
    return
  end

  -- local cmd = string.format("sf apex run test --class-names %s -r human -w 5 %s-o %s", test_class_name, extraParams, util.get())
  local cmd = cmd_builder:new()
    :cmd("apex")
    :act("run test")
    :addParams({
      ["-n"] = test_class_name,
      ["-r"] = "human",
      ["-w"] = vim.g.sf.sf_wait_time,
      ["--concise"] = "",
    })
    :build()

  util.last_tests = cmd
  term.run(cmd, cb, { label = test_class_name, category = "test" })
end

Test.repeat_last_tests = function()
  if util.is_empty_str(util.last_tests) then
    return util.show_warn("Last test command is empty.")
  end

  term.run(util.last_tests, nil, { label = "Repeat last test", category = "test" })
end

Test.run_local_tests = function()
  -- local cmd = string.format("sf apex run test --test-level RunLocalTests --code-coverage -r human --wait 180 -o %s", util.get())
  local cmd = cmd_builder:new()
    :cmd("apex")
    :act("run test")
    :addParams({
      ["-l"] = "RunLocalTests",
      ["-c"] = "",
      ["-r"] = "human",
      ["-w"] = 180,
    })
    :build()

  util.last_tests = cmd
  term.run(cmd, nil, { label = "All local tests", category = "test" })
end

Test.run_all_jests = function()
  term.run("npm run test:unit:coverage", nil, { label = "Jest tests", category = "test" })
end

Test.run_jest_file = function()
  if vim.fn.expand("%"):match("(.*)%.test%.js$") == nil then
    vim.notify("Not in a jest test file", vim.log.levels.ERROR)
    return
  end
  term.run(string.format("npm run test:unit -- -- %s", vim.fn.expand("%")), nil, { label = "Jest " .. vim.fn.expand("%:t"), category = "test" })
end

-- helper;

helpers.validateInTestClass = function()
  local test_class_name = ts.get_test_class_name()
  if util.is_empty_str(test_class_name) then
    util.notify_then_error("Not in a test class.")
  end

  return test_class_name
end

helpers.validateInTestMethod = function()
  local test_name = ts.get_current_test_method_name()
  if util.is_empty_str(test_name) then
    util.notify_then_error("Cursor not in a test method.")
  end

  return test_name
end

---@param lines table
---@return any
helpers.extract_test_run_id = function(lines)
  for _, line in ipairs(lines) do
    if string.find(line, "Test Run Id") then
      return string.match(line, "Test Run Id%s*(%w+)")
    end
  end
  return nil
end

---@param self table
---@param cmd string
---@param exit_code number
helpers.save_test_coverage_locally = function(self, cmd, exit_code)
  util.create_cache_dir_if_not_exist()

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local id = helpers.extract_test_run_id(lines)
  if id == nil then
    return
  end

  local file_name = "test_result.json"
  -- local cmd = 'sf apex get test -i ' .. id .. ' -c --json > ' .. util.get_cache_dir() .. file_name
  local cmd = cmd_builder:new():cmd("apex"):act("get test"):addParams("-i", id):addParams("-c"):addParams("--json"):build()
  cmd = cmd .. " > " .. util.get_cache_dir() .. file_name

  util.silent_job_call(cmd, "Code coverage saved.", "Code coverage save failed! " .. cmd, test_sign.invalidate_cache_and_try_place)
end

-- prompt below

local api = vim.api
local buftype = "nowrite"
local filetype = "sf_test_prompt"

picker.buf = nil
picker.win = nil
picker.class = nil
picker.tests = nil
picker.test_num = nil
picker.selected_tests = {}

picker.open = function()
  local class = ts.get_test_class_name()
  if util.is_empty_str(class) then
    util.notify_then_error("Not an Apex test class.")
  end

  local test_names = ts.get_test_method_names_in_curr_file()
  if vim.tbl_isempty(test_names) then
    util.show("no Apex test found.")
  end

  local tests = {}
  local test_num = 0
  for _, name in ipairs(test_names) do
    table.insert(tests, name)
    test_num = test_num + 1
  end

  picker.class = class
  picker.tests = tests
  picker.test_num = test_num

  local buf = picker.use_existing_or_create_buf()
  local win = picker.use_existing_or_create_win()
  picker.buf = buf
  picker.win = win

  api.nvim_win_set_buf(win, buf)

  picker.set_keys()

  vim.bo[buf].modifiable = true
  picker.display()
  vim.bo[buf].modifiable = false
end

picker.set_keys = function()
  vim.keymap.set("n", "x", function()
    picker.toggle()
  end, { buffer = true, noremap = true })

  local create_cmd = function(tbl)
    local cmd_builder = cmd_builder:new():cmd("apex"):act("run test"):addParams(tbl)

    local test_params = ""
    for _, test in ipairs(picker.selected_tests) do
      test_params = test_params .. " -t " .. test
    end

    local cmd = cmd_builder:addParamStr(test_params):build()

    return cmd
  end

  vim.keymap.set("n", "cc", function()
    if vim.tbl_isempty(picker.selected_tests) then
      return util.show_err("No test is selected.")
    end

    local cmd = create_cmd({ ["-w"] = vim.g.sf.sf_wait_time, ["-r"] = "human" })

    picker.close()
    term.run(cmd, nil, { label = picker.class .. " (" .. #picker.selected_tests .. " tests)", category = "test" })
    util.last_tests = cmd
    picker.selected_tests = {}
  end, { buffer = true, noremap = true })

  vim.keymap.set("n", "CC", function()
    if vim.tbl_isempty(picker.selected_tests) then
      return util.show_err("No test is selected.")
    end

    local cmd = create_cmd({ ["-w"] = vim.g.sf.sf_wait_time, ["-r"] = "human", ["-c"] = "" })

    picker.close()
    term.run(cmd, helpers.save_test_coverage_locally, { label = picker.class .. " (" .. #picker.selected_tests .. " tests)", category = "test" })
    util.last_tests = cmd
    picker.selected_tests = {}
  end, { buffer = true, noremap = true })
end

picker.display = function()
  api.nvim_set_current_win(picker.win)
  local names = {}
  table.insert(names, '** "x": toggle tests; "cc": run tests; "CC": run tests with code coverage.')

  for _, test in ipairs(picker.tests) do
    local class_test = string.format("%s.%s", picker.class, test)
    if vim.tbl_contains(picker.selected_tests, class_test) then
      table.insert(names, "[x] " .. test)
    else
      table.insert(names, "[ ] " .. test)
    end
  end
  api.nvim_buf_set_lines(picker.buf, 0, 100, false, names)
end

picker.use_existing_or_create_buf = function()
  if picker.buf and api.nvim_buf_is_loaded(picker.buf) then
    return picker.buf
  end

  local buf = api.nvim_create_buf(false, false)
  vim.bo[buf].buftype = buftype
  vim.bo[buf].filetype = filetype

  return buf
end

picker.use_existing_or_create_win = function()
  local win_hight = picker.test_num + 2

  if picker.win and api.nvim_win_is_valid(picker.win) then
    api.nvim_set_current_win(picker.win)
    api.nvim_win_set_height(picker.win, win_hight)
    return picker.win
  end

  api.nvim_command(win_hight .. "split")

  return api.nvim_get_current_win()
end

picker.toggle = function()
  if vim.bo[0].filetype ~= filetype then
    return util.show_err("file-type must be: " .. filetype)
  end

  vim.bo[0].modifiable = true

  local r, _ = unpack(vim.api.nvim_win_get_cursor(0))
  if r == 1 then -- 1st row is title
    return
  end

  local row_index = r - 1

  local curr_value = api.nvim_buf_get_text(0, row_index, 1, row_index, 2, {})

  local name = picker.tests[row_index]
  local class_test = string.format("%s.%s", picker.class, name)
  local index = util.list_find(picker.selected_tests, class_test)

  if curr_value[1] == "x" then
    if index ~= nil then
      table.remove(picker.selected_tests, index)
    end
    api.nvim_buf_set_text(0, row_index, 1, row_index, 2, { " " })
  elseif curr_value[1] == " " then
    if index == nil then
      table.insert(picker.selected_tests, class_test)
    end
    api.nvim_buf_set_text(0, row_index, 1, row_index, 2, { "x" })
  end

  util.show("Selected: " .. vim.tbl_count(picker.selected_tests))

  vim.bo[0].modifiable = false
end

---@param param_str string
---@return nil
picker.build_tests_cmd = function(param_str)
  return t
  --   local cmd = string.format('sf apex run test%s %s', t, param_str)
  --   return cmd
end

picker.close = function()
  if picker.win and api.nvim_win_is_valid(picker.win) then
    api.nvim_win_close(picker.win, false)
  end
end

return Test
