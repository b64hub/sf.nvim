local util = require("sf.util")
local cmd_builder = require("sf.sub.cmd_builder")
local Term = {}
local helpers = {}
local terminal

-- this function is called in config.lua if terminal type is set to 'integrated'
-- it's meant to delay the raw term initialization so the term_cfg is ready after user's setup() call
---@param term_cfg table
function Term.integrated_setup(term_cfg)
  terminal = require("sf.sub.raw_term"):new(term_cfg)
end

-- this function is called in config.lua if terminal type is set to 'overseer'
---@param overseer_cfg table
function Term.overseer_setup(overseer_cfg)
  terminal = require("sf.sub.overseer_term"):new(overseer_cfg)
end

function Term.toggle()
  terminal:toggle()
end

function Term.open()
  terminal:open()
end

function Term.save_and_push(extra_params)
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  vim.api.nvim_command("write!")

  local builder = cmd_builder:new():cmd("project"):act("deploy start"):addParams("-d", "%:p")
  if extra_params then
    builder:addParamStr(extra_params)
  end
  local cmd = builder:build()
  terminal:run(cmd, nil, { label = "Deploy " .. vim.fn.expand("%:t"), category = "deploy" })
end

function Term.push_delta(extra_params)
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  local builder = cmd_builder:new():cmd("project"):act("deploy start")
  if extra_params then
    builder:addParamStr(extra_params)
  end
  local cmd = builder:build()
  terminal:run(cmd, nil, { label = "Deploy project", category = "deploy" })
end

function Term.retrieve(extra_params)
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  local filename = vim.fn.expandcmd("%:p")
  local cb = function()
    util.try_open_file(filename)
  end

  local builder = cmd_builder:new():cmd("project"):act("retrieve start"):addParams("-d", filename)
  if extra_params then
    builder:addParamStr(extra_params)
  end
  local cmd = builder:build()
  terminal:run(cmd, cb, { label = "Retrieve " .. vim.fn.fnamemodify(filename, ":t"), category = "retrieve" })
end

function Term.retrieve_delta(extra_params)
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  local builder = cmd_builder:new():cmd("project"):act("retrieve start")
  if extra_params then
    builder:addParamStr(extra_params)
  end
  local cmd = builder:build()
  terminal:run(cmd, nil, { label = "Retrieve project", category = "retrieve" })
end

function Term.retrieve_package()
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end
  local cmd = cmd_builder:new():cmd("project"):act("retrieve start"):addParams("-x", "%:p"):build()
  terminal:run(cmd, nil, { label = "Retrieve package", category = "retrieve" })
end

function Term.run_anonymous_stdin(use_selection)
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  local text
  if use_selection then
    text = helpers.get_visual_selection()
    if util.is_empty_str(text) then
      vim.notify("Empty selection. Abort action.", vim.log.levels.WARN)
      return
    end
  else
    -- Use entire buffer content
    text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  end

  if util.is_empty_str(text) then
    vim.notify("Empty buffer.", vim.log.levels.WARN)
    return
  end

  local base_cmd = cmd_builder:new():cmd("apex"):act("run"):build()
  local cmd = string.format("echo %s | %s", vim.fn.shellescape(text), base_cmd)
  terminal:run(cmd, nil, { label = "Anonymous Apex", category = "anonymous" })
end

function Term.run_anonymous()
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end
  local cmd = cmd_builder:new():cmd("apex"):act("run"):addParams("-f", "%:p"):build()
  terminal:run(cmd, nil, { label = "Anonymous Apex", category = "anonymous" })
end

--- Runs anonymous Apex (visual selection or whole buffer) straight through
--- the Tooling API's `executeAnonymous` endpoint instead of the `sf` CLI:
--- no Node startup cost, no terminal float, and it doesn't block the editor
--- - result/failure shows up as a snacks/vim.notify toast via the same
--- progress widget used for deploy/retrieve.
---
--- Trade-off vs `run_anonymous`/`run_anonymous_stdin`: this reports only
--- compile/runtime success and exception details, not `System.debug` log
--- output (capturing that needs a trace flag set on the running user first,
--- which is a heavier setup this quick path deliberately skips). Reach for
--- the CLI-based variants when you need to see debug log lines.
---@param use_selection boolean
function Term.run_anonymous_api(use_selection)
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end

  local apex_body
  if use_selection then
    apex_body = helpers.get_visual_selection()
  else
    apex_body = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  end

  if util.is_empty_str(apex_body) then
    return util.show_warn("Nothing to run.")
  end

  local rest_api = require("sf.sub.rest_api")
  local progress = require("sf.ui.progress")
  local handle = progress.start({ msg = "Executing anonymous Apex..." })

  rest_api.get_session(util.target_org, function(session, err)
    if not session then
      return handle:finish(false, err or "Failed to resolve org session")
    end

    rest_api.execute_anonymous(session, apex_body, function(result, exec_err)
      if not result then
        return handle:finish(false, exec_err or "Anonymous Apex request failed")
      end

      if not result.compiled then
        return handle:finish(false, string.format("Compile error (line %s): %s", result.line, result.compileProblem))
      end

      if not result.success then
        return handle:finish(false, string.format("Exception (line %s): %s", result.line, result.exceptionMessage))
      end

      handle:finish(true, "Anonymous Apex executed successfully")
    end)
  end)
end

function Term.run_query()
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end
  local cmd = cmd_builder:new():cmd("data"):act("query"):addParams("-f", "%:p"):build()
  terminal:run(cmd, nil, { label = "SOQL", category = "query" })
end

function Term.run_tooling_query()
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end
  local cmd = cmd_builder:new():cmd("data"):act("query"):addParams({ ["-f"] = "%:p", ["-t"] = "" }):build()
  terminal:run(cmd, nil, { label = "SOQL (tooling)", category = "query" })
end

function Term.run_highlighted_soql()
  if util.is_empty_str(util.target_org) then
    return util.show_err("Target_org empty!")
  end
  if vim.fn.mode() ~= "v" then
    vim.notify("Not in normal visual mode per character.", vim.log.levels.WARN)
    return
  end

  local selected_text = helpers.get_visual_selection()
  if util.is_empty_str(selected_text) then
    vim.notify("Empty selection.", vim.log.levels.WARN)
    return
  end

  local raw_cmd = cmd_builder:new():cmd("data"):act("query"):addParamsNoExpand("-q", selected_text):build()
  terminal:run(raw_cmd, nil, { label = "SOQL", category = "query" })
end

function Term.cancel()
  terminal:cancel()
end

function Term.go_to_sf_root()
  local root = util.get_sf_root()
  terminal:run("cd " .. root)
end

function Term.run(cmd, cb, opts)
  terminal:run(cmd, cb, opts)
end

--- Show the last task's output in the SFTerm float (the "expand" action for
--- a quiet "progress"-mode task).
function Term.show_last_task_output()
  terminal:open()
end

function Term.get_config()
  return terminal:get_config()
end

-- helper;

helpers.get_visual_selection = function()
  -- Save the current register content and type
  local old_reg = vim.fn.getreg('"')
  local old_regtype = vim.fn.getregtype('"')

  -- Execute normal mode commands to yank the visual selection
  vim.cmd('noautocmd normal! "vy"')

  -- Get the content of the unnamed register (which now contains our selection)
  local selection = vim.fn.getreg("v")

  -- Restore the register to its previous state
  vim.fn.setreg('"', old_reg, old_regtype)

  -- Return the selected text
  return selection
end

return Term
