local key_bindings = {}

key_bindings.set_default_hotkeys = function()
  local nmap = function(keys, func, desc)
    if desc then
      desc = desc .. " [Sf]"
    end
    vim.keymap.set("n", keys, func, { buffer = true, desc = desc })
  end

  local sf = require("sf")

  -- All default hotkeys live under the <leader>sf prefix, so they don't
  -- collide with a bare <leader>s mapping (e.g. a search plugin).
  -- <leader><leader>, <C-c>, \s, [v, ]v are deliberately left outside the
  -- prefix: they're single global idioms, not part of the sf.nvim namespace.

  -- Common hotkeys for all files;
  nmap("<leader>sfs", sf.set_target_org, "set target_org current workspace")
  nmap("<leader>sfS", sf.set_global_target_org, "set global target_org")
  nmap("<leader>sff", sf.fetch_org_list, "fetch orgs info")
  nmap("<leader>sfml", sf.list_md_to_retrieve, "metadata listing")
  nmap("<leader>sfmtl", sf.list_md_type_to_retrieve, "metadata-type listing")
  nmap("<leader>sfv", sf.toggle_term, "terminal toggle (view/expand last task output)")
  nmap("<C-c>", sf.cancel, "cancel running command")
  nmap("<leader>sf-", sf.go_to_sf_root, "cd into root")
  nmap("<leader>sfct", sf.create_ctags, "create ctag file in project root")
  nmap("<leader>sfft", sf.create_and_list_ctags, "fzf list updated ctags")
  nmap("<leader>sfo", sf.org_open, "open target_org")

  -- Apex Replay Debugger (nvim-dap); see docs/replay-debugger-notes.md
  nmap("<leader>sflc", sf.replay_debug_current_log, "replay debug: current log")
  nmap("<leader>sfll", sf.replay_debug_local_log, "replay debug: pick local log")
  nmap("<leader>sflo", sf.replay_debug_org_log, "replay debug: pick org log")
  nmap("<leader>sflr", sf.replay_debug_last_log, "replay debug: last log")
  nmap("<leader>sflb", sf.refresh_debug_breakpoint_info, "replay debug: refresh breakpoint info")
  nmap("<leader>sflt", sf.toggle_replay_debug_logging, "replay debug: toggle trace flag")
  nmap("<leader>sflf", sf.pull_log, "replay debug: fetch a log from org and open it")

  vim.keymap.set("v", "<leader>sfa", function()
    sf.run_anonymous_stdin(true)
  end, { buffer = true, desc = "run selected content anonymously" })
  nmap("<leader>sfa", function() sf.run_anonymous_stdin(false) end, "run this buffer anonymously")
  nmap("<leader>sfA", sf.run_anonymous, "run this file anonymously")

  -- Hotkeys for metadata files only;
  if vim.tbl_contains(vim.g.sf.hotkeys_in_filetypes, vim.bo.filetype) then
    nmap("<leader>sfO", sf.org_open_current_file, "open file in target_org")
    nmap("<leader>sfd", sf.diff_in_target_org, "diff in target_org")
    nmap("<leader>sfD", sf.diff_in_org, "diff in org...")
    nmap("<leader>sfma", sf.retrieve_apex_under_cursor, "apex under cursor retrieve")
    nmap("<leader>sfp", sf.save_and_push, "push current file")
    nmap("<leader>sfr", sf.retrieve, "retrieve current file")
    nmap("<leader>sfR", sf.rename_apex_class_remote_and_local, "rename current apex from org and local")
    nmap("<leader>sfX", sf.delete_current_apex_remote_and_local, "delete current apex from org and local")

    vim.keymap.set("x", "<leader>sfq", sf.run_highlighted_soql, { buffer = true, desc = "SOQL run highlighted text" })

    nmap("<leader>sfta", sf.run_all_tests_in_this_file, "test all in this file")
    nmap("<leader>sftA", sf.run_all_tests_in_this_file_with_coverage, "test all with coverage info")
    nmap("<leader>sftt", sf.run_current_test, "test this under cursor")
    nmap("<leader>sftT", sf.run_current_test_with_coverage, "test this under cursor with coverage info")
    nmap("<leader>sfto", sf.open_test_select, "open test select buf")
    nmap("\\s", sf.toggle_sign, "toggle signs for code coverage")
    nmap("<leader>sftr", sf.repeat_last_tests, "repeat last test")
    nmap("<leader>sfcc", sf.copy_apex_name, "copy apex name")
    nmap("[v", sf.uncovered_jump_backward, "jump to previous uncovered sign icon line")
    nmap("]v", sf.uncovered_jump_forward, "jump to next uncovered sign icon line")
  end
end

return key_bindings
