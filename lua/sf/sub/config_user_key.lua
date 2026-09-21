local M = {}

M.set_default_hotkeys = function()
  local nmap = function(keys, func, desc)
    if desc then
      desc = desc .. " [Sf]"
    end
    vim.keymap.set("n", keys, func, { buffer = true, desc = desc })
  end

  local Sf = require("sf")

  -- All default hotkeys live under the <leader>sf prefix, so they don't
  -- collide with a bare <leader>s mapping (e.g. a search plugin).
  -- <leader><leader>, <C-c>, \s, [v, ]v are deliberately left outside the
  -- prefix: they're single global idioms, not part of the sf.nvim namespace.

  -- Common hotkeys for all files;
  nmap("<leader>sfs", Sf.set_target_org, "set target_org current workspace")
  nmap("<leader>sfS", Sf.set_global_target_org, "set global target_org")
  nmap("<leader>sff", Sf.fetch_org_list, "fetch orgs info")
  nmap("<leader>sfml", Sf.list_md_to_retrieve, "metadata listing")
  nmap("<leader>sfmtl", Sf.list_md_type_to_retrieve, "metadata-type listing")
  nmap("<leader>sfv", Sf.toggle_term, "terminal toggle (view/expand last task output)")
  nmap("<C-c>", Sf.cancel, "cancel running command")
  nmap("<leader>sf-", Sf.go_to_sf_root, "cd into root")
  nmap("<leader>sfct", Sf.create_ctags, "create ctag file in project root")
  nmap("<leader>sfft", Sf.create_and_list_ctags, "fzf list updated ctags")
  nmap("<leader>sfo", Sf.org_open, "open target_org")

  -- Apex Replay Debugger (nvim-dap); see docs/replay-debugger-notes.md
  nmap("<leader>sflc", Sf.replay_debug_current_log, "replay debug: current log")
  nmap("<leader>sfll", Sf.replay_debug_local_log, "replay debug: pick local log")
  nmap("<leader>sflo", Sf.replay_debug_org_log, "replay debug: pick org log")
  nmap("<leader>sflr", Sf.replay_debug_last_log, "replay debug: last log")
  nmap("<leader>sflb", Sf.refresh_debug_breakpoint_info, "replay debug: refresh breakpoint info")

  vim.keymap.set("v", "<leader>sfa", function()
    Sf.run_anonymous_stdin(true)
  end, { buffer = true, desc = "run selected content anonymously" })
  nmap("<leader>sfa", function() Sf.run_anonymous_stdin(false) end, "run this buffer anonymously")
  nmap("<leader>sfA", Sf.run_anonymous, "run this file anonymously")

  -- Hotkeys for metadata files only;
  if vim.tbl_contains(vim.g.sf.hotkeys_in_filetypes, vim.bo.filetype) then
    nmap("<leader>sfO", Sf.org_open_current_file, "open file in target_org")
    nmap("<leader>sfd", Sf.diff_in_target_org, "diff in target_org")
    nmap("<leader>sfD", Sf.diff_in_org, "diff in org...")
    nmap("<leader>sfma", Sf.retrieve_apex_under_cursor, "apex under cursor retrieve")
    nmap("<leader>sfp", Sf.save_and_push, "push current file")
    nmap("<leader>sfr", Sf.retrieve, "retrieve current file")
    nmap("<leader>sfR", Sf.rename_apex_class_remote_and_local, "rename current apex from org and local")
    nmap("<leader>sfX", Sf.delete_current_apex_remote_and_local, "delete current apex from org and local")

    vim.keymap.set("x", "<leader>sfq", Sf.run_highlighted_soql, { buffer = true, desc = "SOQL run highlighted text" })

    nmap("<leader>sfta", Sf.run_all_tests_in_this_file, "test all in this file")
    nmap("<leader>sftA", Sf.run_all_tests_in_this_file_with_coverage, "test all with coverage info")
    nmap("<leader>sftt", Sf.run_current_test, "test this under cursor")
    nmap("<leader>sftT", Sf.run_current_test_with_coverage, "test this under cursor with coverage info")
    nmap("<leader>sfto", Sf.open_test_select, "open test select buf")
    nmap("\\s", Sf.toggle_sign, "toggle signs for code coverage")
    nmap("<leader>sftr", Sf.repeat_last_tests, "repeat last test")
    nmap("<leader>sfcc", Sf.copy_apex_name, "copy apex name")
    nmap("[v", Sf.uncovered_jump_backward, "jump to previous uncovered sign icon line")
    nmap("]v", Sf.uncovered_jump_forward, "jump to next uncovered sign icon line")
  end
end

return M
