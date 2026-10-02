local util = require("sf.util")
local test_sign = {}
local helpers = {}
local enabled = false
local cache = nil

local covered_group = "SfCovered"
local uncovered_group = "SfUncovered"
local covered_sign = "sf_covered"
local uncovered_sign = "sf_uncovered"

local show_covered = true
local show_uncovered = true

test_sign.covered_percent = ""

test_sign.setup = function()
  if vim.g.sf.code_sign_highlight.covered.fg == "" then
    show_covered = false
  end

  if vim.g.sf.code_sign_highlight.uncovered.fg == "" then
    show_uncovered = false
  end

  helpers.highlight(covered_group, { fg = vim.g.sf.code_sign_highlight.covered.fg })
  helpers.highlight(uncovered_group, { fg = vim.g.sf.code_sign_highlight.uncovered.fg })

  vim.fn.sign_define(covered_sign, { text = "▎", texthl = covered_group })
  vim.fn.sign_define(uncovered_sign, { text = "▎", texthl = uncovered_group })

  local in_project, _ = pcall(util.get_sf_root)
  enabled = in_project and (vim.g.sf.auto_display_code_sign or false)
end

test_sign.toggle = function()
  if enabled then
    vim.notify("Sign disabled.", vim.log.levels.INFO)
    helpers.unplace()
  else
    vim.notify("Sign enabled.", vim.log.levels.INFO)
    test_sign.refresh_and_place()
  end
end

test_sign.uncovered_jump_forward = function()
  local isForward = true
  helpers.uncovered_jump(isForward)
end

test_sign.uncovered_jump_backward = function()
  local isForward = false
  helpers.uncovered_jump(isForward)
end

test_sign.is_enabled = function()
  return enabled
end

test_sign.refresh_and_place = function()
  helpers.unplace()
  local coverage = helpers.get_coverage()
  if coverage == nil then
    return
  end

  local signs = helpers.get_signs_from(coverage)
  vim.fn.sign_placelist(signs)
  enabled = true
end

test_sign.refresh_current_file_covered_percent = function()
  local coverage = helpers.get_coverage()
  if coverage == nil then
    return
  end

  local file_name = vim.fn.expand("%:t")

  for i, v in pairs(coverage) do
    local apex_name = v["name"] .. ".cls"

    if file_name == apex_name then
      test_sign.covered_percent = v["coveredPercent"]
      return
    end
  end
  test_sign.covered_percent = ""
end

test_sign.invalidate_cache_and_try_place = function()
  cache = nil
  if test_sign.is_enabled() or vim.g.sf.auto_display_code_sign then
    test_sign.refresh_and_place()
  end
end

-- helpers

helpers.get_signs_from = function(coverage)
  local signs = {}

  for i, v in pairs(coverage) do
    local apex_name = v["name"] .. ".cls"

    if vim.fn.expand("%:t") == apex_name then
      test_sign.covered_percent = v["coveredPercent"]
    end

    if util.is_apex_loaded_in_buf(apex_name) then
      for line, value in pairs(v["lines"]) do
        local sign = {}
        sign.id = 0
        sign.buffer = util.get_buf_num(apex_name)
        sign.lnum = line
        sign.priority = 1000

        if show_covered and value == 1 then
          sign.name = covered_sign
          sign.group = covered_group
        elseif show_uncovered and value == 0 then
          sign.name = uncovered_sign
          sign.group = uncovered_group
        end

        table.insert(signs, sign)
      end
    end
  end
  return signs
end

helpers.get_coverage = function()
  local coverage

  if cache ~= nil then
    coverage = cache
    return coverage
  end

  local tbl = util.read_file_in_cache_dir("test_result.json")
  if not tbl then
    -- vim.notify_once("Local test_result.json not found.", vim.log.levels.WARN)
    return nil
  end

  coverage = vim.tbl_get(tbl, "result", "coverage", "coverage")
  if coverage == nil then
    vim.notify_once("Local test_result.json has no coverage element.", vim.log.levels.WARN)
    return nil
  end

  cache = coverage

  return coverage
end

helpers.unplace = function()
  vim.fn.sign_unplace(covered_group)
  vim.fn.sign_unplace(uncovered_group)
  enabled = false
end

helpers.uncovered_jump = function(isForward)
  if not enabled then
    return
  end

  local placed = vim.fn.sign_getplaced("", { group = uncovered_group })
  local placed_signs = placed[1].signs

  if #placed == 0 or #placed_signs == 0 then
    return
  end

  local current_lnum = vim.fn.line(".")

  local hunks = helpers.get_hunks(placed_signs)

  if not isForward then
    hunks = helpers.revert(hunks)
  end

  for _, hunk in ipairs(hunks) do
    local hunk_start_lnum = hunk[1].lnum

    if (isForward and hunk_start_lnum > current_lnum) or (not isForward and hunk_start_lnum < current_lnum) then
      vim.fn.sign_jump(hunk[1].id, uncovered_group, "")
      return
    end
  end

  vim.fn.sign_jump(hunks[1][1].id, uncovered_group, "") -- loop back
end

helpers.get_hunks = function(placed_signs)
  local hunks = {}
  local current_hunk = { placed_signs[1] }

  for i = 2, #placed_signs do
    local sign = placed_signs[i]
    if sign.lnum == current_hunk[#current_hunk].lnum + 1 then
      table.insert(current_hunk, sign)
    else
      table.insert(hunks, current_hunk)
      current_hunk = { sign }
    end
  end
  table.insert(hunks, current_hunk)

  return hunks
end

helpers.highlight = function(group, color)
  local style = color.style and "gui=" .. color.style or "gui=NONE"
  local fg = color.fg and "guifg=" .. color.fg or "guifg=NONE"
  local bg = color.bg and "guibg=" .. color.bg or "guibg=NONE"
  local sp = color.sp and "guisp=" .. color.sp or ""
  local hl = "highlight default " .. group .. " " .. style .. " " .. fg .. " " .. bg .. " " .. sp
  vim.cmd(hl)
  if color.link then
    vim.cmd("highlight default link " .. group .. " " .. color.link)
  end
end

helpers.revert = function(hunks)
  table.sort(hunks, function(a, b)
    return a[1].lnum > b[1].lnum
  end)
  return hunks
end

return test_sign
