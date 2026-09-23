![Image](https://github.com/xixiaofinland/sf.nvim/assets/13655323/454d4a3d-d455-43f6-b44b-506862106b66)

<p align="center">
<img src="https://img.shields.io/badge/Neovim-57A143?logo=neovim&logoColor=fff&style=for-the-badge" alt="Neovim" />
<img src="https://img.shields.io/badge/Made%20With%20Lua-2C2D72?logo=lua&logoColor=fff&style=for-the-badge" alt="made with lua" >
</p>
<h1 align="center">Sf.nvim</h1>
<p align="center">📸 A Neovim plugin for Salesforce development</p>

# 📖 Table of Contents

- [Features](#-features)
- [Intro video](#-intro-video-6min)
- [Prerequisites](#-prerequisites)
- [Installation](#%EF%B8%8F--installation)
- [Configuration](#%EF%B8%8F-configuration)
- [Keys](#-keys)
- [List/retrieve metadata](#-feature-listretrieve-metadata-and-metadata-types)
- [Apex test](#apex-test)
- [Display target org and code coverage](#-display-target_org-and-code-coverage)
- [Terminal](#%EF%B8%8F-terminal)
- [Apex jump](#-enhanced-jump-to-definition-apex)
- [Read More](#-read-more)
- [Contributions](#-contributions)

## ✨ Features

In a nutshell, All features are supplied via the list of `Sf.*` functionalities in
[init.lua](./lua/sf/init.lua). You can surf the code comments as the manual or `:h
sf.nvim`, which is auto-generated from those comments.

All the features are categorized as:

- 🔥 Apex/Lwc/Aura: push, retrieve, create
- 💻 Integrated term or overseer.nvim
- 😎 File diff: local v.s. org
- 🤩 Target-org icon
- 👏 Org Metadata browsing
- 🤖 Quick apex test run
- ✨ Test report and code coverage info
- 🦘 Enhanced jump-to-definition (Apex)
- 🗂️ Refresh sObject definitions for `apex_ls`

In addition to the features, user commands and default hotkeys are also supplied, see
[Keys](#-keys).

<br>

## 🎦 Intro video (6min)

[![Feature Intro (6 min)](https://img.youtube.com/vi/MdqPgHIb1pw/0.jpg)](https://www.youtube.com/watch?v=MdqPgHIb1pw)

<br>

## 📝 Prerequisites

💡 Plugin comes with a health check feature. Run `:check sf` to auto-check prerequiste statistics.

- 🌐 [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli)
- 🐢 Nvim v0.11 or newer
- 📦 Salesforce relevant parsers (i.e. "apex", "soql", "sosl", and "sflog") in Nvim-treesitter (main branch)

  <details>
  <summary>Example nvim-treesitter setup (lazy.nvim)</summary>

  ```lua
  {
    'nvim-treesitter/nvim-treesitter',
    lazy = false, -- explicitly disallowed by the new plugin
    build = ':TSUpdate',
    config = function()
      require('nvim-treesitter').setup {}

      -- Install parsers on startup; no-op if already up to date.
      require('nvim-treesitter').install({
        "apex", "soql", "sosl", "sflog",
      })
    end,
  }
  ```

  On the `main` branch highlighting is no longer auto-enabled; each filetype
  starts it via `vim.treesitter.start()` in an ftplugin file or a `FileType`
  autocmd.

  </details>
- 🔍 (Optional) fzf-lua plugin for executing `:SF md list` and `SFListMdTypeToRetrieve` (Why not
  telescope.nvim? Because its UI is slow)
- 🔍 (Optional) [universal ctags](https://github.com/universal-ctags/ctags) is used to enhance [Apex jump](#-enhanced-jump-to-definition-apex)
- 🔍 (Optional) [overseer.nvim](https://github.com/stevearc/overseer.nvim) if you'd like to use the overseer integration
- 🐛 (Optional) [nvim-dap](https://github.com/mfussenegger/nvim-dap) + a `node` executable, for the [Apex Replay Debugger](#-feature-apex-replay-debugger)

![Image 019](https://github.com/user-attachments/assets/aad0ac11-f980-423b-8332-a2b4359fb4ae)

<br>

## ⚙️ Installation

🚨 **Read this first — it explains the most common "the plugin doesn't work" report:**

Sf.nvim registers its user commands **lazily**. `:SF` exists **only** when your current
path (`:h cwd`) or the currently opened file is inside a Salesforce project folder, i.e.
one with `.forceignore` or `sfdx-project.json` at its root.

So if you install the plugin and try `:SF` while editing your `init.lua`, you will get
`E492: Not an editor command` — that is expected, not a broken install. Open a file
inside a Salesforce project and the commands appear automatically.

Verify with:

```vim
:lua print(pcall(require'sf.util'.get_sf_root))
```

`true` plus a path means you are in a project. `false` means you are not, and `:SF` will
tell you so when invoked.

Note also that **hotkeys are disabled by default** — see [Configuration](#️-configuration).

<br>

### Using lazy.nvim

```lua
return {
  'xixiaofinland/sf.nvim',

  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    'ibhagwan/fzf-lua', -- no need if you don't use listing metadata feature
  },

  config = function()
    require('sf').setup()  -- Important to call setup() to initialize the plugin!
  end
}
```

### Using vim.pack (built-in, Nvim 0.12+)

```lua
vim.pack.add({
  'https://github.com/ibhagwan/fzf-lua', -- no need if you don't use listing metadata feature
  'https://github.com/xixiaofinland/sf.nvim',
  { src = 'https://github.com/nvim-treesitter/nvim-treesitter', version = 'main' },
})

require('fzf-lua').setup()
require('nvim-treesitter').setup()
require('sf').setup() -- Important to call setup() to initialize the plugin!
```

<br>

## 🛠️ Configuration

Custom configuration can be passed into `setup()` Below are the default
settings:

```lua
require('sf').setup({
  -- Unless you want to customize, no need to copy-paste any of these
  -- They are applied automatically

  -- This plugin has many default hotkey mappings supplied
  -- This flag enable/disable these hotkeys defined
  -- It's highly recommended to set this to `false` and define your own key mappings
  -- Set to `true` if you don't mind any potential key mapping conflicts with your own
  enable_hotkeys = false,

  -- this setting takes effect only when You have "enable_hotkeys = true"(i.e. use default supplied hotkeys).
  -- In the default hotkeys, some hotkeys are on "project level" thus always enabled. Examples: "set default org", "fetch org info".
  -- Other hotkeys are enabled when only metadata filetypes are loaded in the current buffer. Example: "push/retrieve current metadata file"
  -- This list defines what metadata filetypes have the "other hotkeys" enabled.
  -- For example, if you want to push/retrieve css files, it needs to be added into this list.
  hotkeys_in_filetypes = {
    "apex", "sosl", "soql", "javascript", "html"
  },

  -- When Nvim is initiated, the sf org list is automatically fetched and target_org is set (if available) by `:SF org fetchList`
  -- You can set it to `false` and have a manual control
  fetch_org_list_at_nvim_start = true,

  -- Define what metadata to be listed in `list_md_to_retrieve()` (<leader>sfml)
  -- Salesforce has numerous metadata types. We narrow down the scope of `list_md_to_retrieve()`.
  types_to_retrieve = {
    "ApexClass",
    "ApexTrigger",
    "StaticResource",
    "LightningComponentBundle"
  },

  -- The terminal strategy to use for running tasks.
  -- "integrated" - use the integrated terminal.
  -- "overseer" - use overseer.nvim to run terminal tasks. (requires overseer.nvim as a dependency).
  terminal = "integrated",

  -- Configuration for the integrated terminal
  term_config = {
    blend = 10,     -- background transparency: 0 is fully opaque; 100 is fully transparent
    dimensions = {
      height = 0.4, -- proportional of the editor height. 0.4 means 40%.
      width = 0.8,  -- proportional of the editor width. 0.8 means 80%.
      x = 0.5,      -- starting position of width. Details in `get_dimension()` in raw_term.lua source code.
      y = 0.9,      -- starting position of height. Details in `get_dimension()` in raw_term.lua source code.
    },
  },

  -- By default, the plugin uses the default package from sfdx-project.json.
  -- If no packages are found, falls back to the value specified in 'default_dir'. If multiple packages are available,
  -- you can override the current working package using |Sf.set_current_package|
  default_dir = '/force-app/main/default/',

  -- the folder this plugin uses to store intermediate data. It's under the sf project root directory.
  plugin_folder_name = '/sf_cache/',

  -- after the test running with code coverage completes, display uncovered line sign automatically.
  -- you can set it to `false`, then manually run toggle_sign command.
  auto_display_code_sign = true,

  -- code coverage sign icon colors
  code_sign_highlight = {
    covered = { fg = "#b7f071" }, -- set `fg = ""` to disable this sign icon
    uncovered = { fg = "#f07178" }, -- set `fg = ""` to disable this sign icon
  },

  -- Apex Replay Debugger (via nvim-dap). See "Feature: Apex Replay Debugger" below.
  replay_debugger = {
    -- absolute path to the salesforce apex-replay-debugger adapter's
    -- "apexReplayDebug.js"; nil = auto-detect (stdpath data dir, then
    -- ~/.vscode/extensions/salesforce.salesforcedx-vscode-apex-replay-debugger-*)
    adapter_path = nil,
    node_path = "node",
    stop_on_entry = true,
    -- boolean, or comma list: "all,protocol,logfile,launch,breakpoints"
    trace = false,
    -- ms to wait for apex_ls to answer the `debugger/lineBreakpoints` request
    lsp_timeout = 30000,
    -- default TraceFlag duration for `:SF debug enable` when no minutes are
    -- given (Salesforce caps TraceFlag duration at 24h regardless).
    trace_flag_hours = 1,
    -- where `:SF debug local` looks for logs; "<plugin_folder>" resolves to
    -- the plugin cache dir, everything else is relative to the project root.
    log_globs = {
      ".sfdx/tools/debug/**/*.log",
      "<plugin_folder>/logs/*.log",
    },
  },

})
```

<br>

## 🔑 Keys

This plugin supplies both user commands (`:h user-commands`) and default hotkeys(`:h mapping`).

Note! Default hotkeys are **disabled** by default in the config setting.

### 🖥️ User commands

User commands are categories into two level subcommands (`:SF sub_cmd1 sub_cmd2`) to leverage the `tab`
suggestion.

For example,

1. type `:SF<space>` and hit `tab` to list available categories(i.e. `sub_cmd1`) as screenshot 1.
2. Then select `test<space>` and hit `tab` again to list the available `sub_cmd2` options in `test`
   category as screenshot 2
3. Finally choose `:SF test allTestsInThisFile` and hit `<enter>` to run all Apex tests in the current file.

![Image 020](https://github.com/user-attachments/assets/725e5d6a-843e-4434-a0c9-a9e72dcb1528)

![Image 021](https://github.com/user-attachments/assets/ab78ef40-6606-4575-b664-a1f905092dc4)

### ⌨️ Default hotkeys

This plugin comes with many default hotkeys (all defined in [this file](./lua/sf/sub/config_user_key.lua)), which may conflict and overwrite your existing hotkeys.
Thus these hotkeys are **disabled** by default in the config setting.

It is also recommended to disable them and define the ones as you wish.
The toggling is in the configuration by setting the `enable_hotkeys` option.

For example,

```
return {
    'xixiaofinland/sf.nvim',
    dependencies = {
        'nvim-treesitter/nvim-treesitter',
        "ibhagwan/fzf-lua",
    },
    config = function()
        require('sf').setup()

        -- all your key definitions put below
        local Sf = require('sf')
        vim.keymap.set('n', '<leader>ss', Sf.set_target_org, { desc = "set local" })
        vim.keymap.set('n', '<leader>sS', Sf.set_global_target_org, { desc = "set global" })
    end
}
```

### Often used default keys

In case you decide to go with the default hotkeys:

| Default key        | function name              | Explain                                                                                             |
| ------------------ | -------------------------- | --------------------------------------------------------------------------------------------------- |
| `<leader>sfs`      | set_target_org             | set target_org                                                                                      |
| `<leader>sff`      | fetch_org_list             | fetch/refresh orgs info                                                                             |
| `<leader>sfv`      | toggle_term                | terminal toggle (view/expand last task output)                                                      |
| `<leader>sfp`      | save_and_push              | push current file                                                                                   |
| `<leader>sfr`      | retrieve                   | retrieve current file                                                                               |
| `<leader>sfta`     | run_all_tests_in_this_file | run all Apex tests in current file                                                                  |
| `<leader>sftt`     | run_current_test           | test this under cursor                                                                              |
| `<leader>sftr`     | repeat_last_tests          | repeat the last test                                                                                |
| `<leader>sfto`     | open_test_select           | open a buffer to select tests                                                                       |
| `<leader>sfct`     | create_ctags               | create ctags file                                                                                   |
| `<leader>sfq`      | run_highlighted_soql       | Deault key is only enabled in visual model. Highlight selected text will be run as SOQL in the term |
| `\s`               | toggle_sign                | Show/hide line coverage sign icon                                                                   |
| `]v`               | uncovered_jump_forward     | jump to next test uncovered hunk                                                                    |
| `[v`               | uncovered_jump_backward    | jump to last test uncovered hunk                                                                    |

All keys are listed in `:h sf.nvim` or [help.txt file](https://github.com/xixiaofinland/sf.nvim/blob/main/doc/sf.txt). All default hotkeys live under the `<leader>sf` prefix (except `\s`, `[v`/`]v`, which are global idioms), so they won't collide with a bare `<leader>s` mapping from another plugin.

Example:

- If you have [which-key](https://github.com/folke/which-key.nvim) or a similar plugin installed, pressing `<leader>sf` will hint to you what keys are enabled as
  shown in the screenshot below. Remember that default hotkeys are \*\*disabled by default.
  ![Image 003](https://github.com/xixiaofinland/sf.nvim/assets/13655323/85faa8cb-b1df-40dd-a1bf-323f94bbf13c)

<br>

### 💡 Run any command in the term

The integrated term (i.e. SFTerm) is a general purpose one, you can pass any shell command into
`run()` method to execute it terminal. For instance, `require('sf').run('ls -la')`, then define it
as your key:

```lua
vim.keymap.set('n', '<leader>sk', require('sf').run('ls -la'), { noremap = true, silent = true, desc = 'run ls -la in the terminal' })
```

<br>

## 🚀 Feature: List/retrieve metadata and metadata types

Sometimes you don't know what metadata the target org contains, and you want to
list them and fetch specific ones. Steps:

1. Retrieve the metadata data by running the user command `:SF md pull`.
2. Run `:SF md list` (or `require('sf').list_md_to_retrieve()`) to show
   the list in a pop-up (requires the fzf-lua plugin) and select one to
   download to local.

Sometimes you want to fetch all files of a certain metadata type (Apex class,
LWC, Aura, etc.). You can list them and fetch all of a specific type. Steps:

1. Retrieve the metadata types by running the user command `:SF mdtype pull`.
2. Run `:SF mdtype list` (or `require('sf').list_md_type_to_retrieve()`) to show the
   list in a pop-up (requires the fzf-lua plugin) and select one to
   download all metadata of this type to local.

<br>

## 🗂️ Feature: Refresh sObject Definitions

Mirrors VSCode's "SFDX: Refresh SObject Definitions". Generates faux Apex
classes under `.sfdx/tools/sobjects/{standardObjects,customObjects}/` so the
Apex language server (`apex_ls`) can offer completion and signature help for
every sObject in the target org — including custom fields and child
relationships.

Run it as:

- `:SF sobject refresh` — refresh every sObject (default).
- `:SF sobject refresh STANDARD` — only standard objects.
- `:SF sobject refresh CUSTOM` — only custom objects.

Or programmatically:

```lua
require('sf').refresh_sobjects({ category = "ALL" })
```

Once writing completes, any attached `apex_ls` clients are restarted in
place (their buffers re-attach automatically) so the new stubs are picked up
without an explicit `:LspRestart`. Pass `restart_lsp = false` to opt out.

No default hotkey is provided for this feature. Add one yourself if needed, e.g.:

```lua
vim.keymap.set("n", "<leader>sb", "<cmd>SF sobject refresh ALL<cr>")
```

Requires `curl` on PATH. The work runs asynchronously and parallelizes
describes across up to 15 in-flight composite/batch requests, so a
~1500-object org typically finishes in well under a minute.

<br>

## ⚡Apex Test

There are two categories of test actions.

✨ Use-case 1: without code coverage info

You can,

- Run all tests in the current file by `<leader>sfta`
- Run the test under the cursor by `<leader>sftt`
- Select tests from the current file by `<leader>sfto`

These commands quickly run and verify the pass/fail result.

🌩️ Use-case 2: with code coverage info

Use the same hotkeys but capitalize the last letter:

- `<leader>sftA`
- `<leader>sftT`
- `<leader>sftO`

These test results contains code coverage information.

After running these commands successfully, the test result is saved locally, and the
covered/uncovered lines are illustrated as sign-icons next to the line number (screenshot below).

🧩 Screenshot

Test finishes in `CrudTest.cls` with `UNCOVERED LINES: 9,10,11,13,14` and the line coverage in `Crud.cls` is indicated with green/red icon
signs.

<br>

![Image 012](https://github.com/user-attachments/assets/c9539cec-7dcc-48fc-b8e8-929cc1514b07)

<br>

📏 Note.

- The line coverage icon shows automatically if the `auto_display_code_sign` setting is set to `true` (default).
- Toggle sign icon on/off with the `\s` hotkey (or `require'sf'.toggle_sign()`).

🏗️ Jump to next uncovered hunk

- Use `]v` and `[v` to jump to the next/previous uncovered hunk.

<br>

## 🐛 Feature: Apex Replay Debugger

Replays an Apex debug log as a live debugging session — breakpoints,
stepping, call stack, variables — using Salesforce's own "Apex Replay
Debugger" adapter, driven through [nvim-dap](https://github.com/mfussenegger/nvim-dap).
This is the Nvim equivalent of VS Code's "SFDX: Launch Apex Replay Debugger".

### Setup

1. Install [nvim-dap](https://github.com/mfussenegger/nvim-dap) (and optionally
   [nvim-dap-ui](https://github.com/rcarriga/nvim-dap-ui) for variable/call-stack
   panes — make sure it isn't gated behind `:Dap*` command lazy-loading if your
   own keymaps call the Lua API directly instead of those commands).
2. Install the adapter: `:SF debug installAdapter` (downloads the
   `salesforce.salesforcedx-vscode-apex-replay-debugger` VSIX from Open VSX and
   unzips it into `stdpath("data")/sf-nvim/apex-replay-debugger/`; requires
   `curl` and `unzip`), or point `replay_debugger.adapter_path` at an existing
   install (e.g. under `~/.vscode/extensions/salesforce.salesforcedx-vscode-apex-replay-debugger-*/`,
   auto-detected if present).
3. `:checkhealth sf` to confirm nvim-dap, `node`, and the adapter are all found.

### Workflow

1. `:SF debug enable` — turns on replay-ready logging (ApexCode=FINEST,
   Visualforce=FINER) for the current org user, for `replay_debugger.trace_flag_hours`
   (default 1h; Salesforce caps `TraceFlag` duration at 24h regardless).
   - `:SF debug enable 120` — override the duration (minutes).
   - `:SF debug enable 120 someone@example.com` — target a different user
     (username, email, or Id) instead of your own — handy when debugging code
     that a colleague or an integration user triggers.
   - `:SF debug enableFor [minutes]` — interactively pick the user (fzf-lua,
     else `vim.ui.select`) instead of typing their username.
   - `:SF debug disable [user]` — expires the TraceFlag early; same optional
     user targeting.
   - Runs against the Tooling REST API directly (one `sf org display` call for
     an access token, then plain `curl`) rather than five sequential `sf data`
     CLI invocations — noticeably faster, since each `sf` CLI call pays a
     multi-second Node startup cost that a raw HTTP request doesn't.
2. Reproduce the behavior you want to debug (run a test, click through the UI,
   whatever produces the log), or jump straight to step 3 with the cursor on a
   test method.
3. Debug it:
   - `:SF debug test` — runs the Apex test under the cursor, then downloads
     and launches the newest log from the org in one step.
   - `:SF debug local` — pick from logs already on disk
     (`.sfdx/tools/debug/**/*.log` and the plugin's downloaded-logs folder).
   - `:SF debug org` — pick a log from the org (fzf-lua), downloads it into
     `.sfdx/tools/debug/logs/` and launches it.
   - `:SF debug current` — debug the `.log` file open in the current buffer.
   - `:SF debug last` — relaunch the most recently launched log.
4. Set breakpoints in the **Apex source file** (not the log) with nvim-dap as
   usual (`:DapToggleBreakpoint`, or your own keymap), before or during a
   session.
5. `:SF debug disable` when done, to expire the TraceFlag early.

`:SF debug refresh` clears and refetches the cached `apex_ls`
`lineBreakpointInfo` (which maps valid breakpoint lines per Apex type) — this
happens automatically whenever a `.cls`/`.trigger` file is saved, so you
shouldn't normally need it.

### Known limitations

- **A breakpoint only stops if that line actually executed in the log you're
  replaying.** A breakpoint on unexecuted code looks identical to "broken" —
  the debugger just runs to completion. Reproduce first, then debug that
  specific log.
- **Generated/build-output copies of a class are excluded automatically** via
  your project's `.forceignore` (e.g. `**/dist/**`) — without this, stepping
  can resolve into a duplicate build copy instead of your real source, since
  `apex_ls` indexes those regardless of `.forceignore` and the adapter's
  typeref→file mapping is last-one-wins. If breakpoints still don't verify,
  double check `.forceignore` covers wherever the duplicate lives.
- **Checkpoints / heap dumps** and the **live/interactive Apex Debugger**
  (a different, paid-feature adapter) are out of scope.
- The log must come from code matching your local files — if they've
  diverged, stepping can land on the wrong line; this is inherent to replay
  debugging, not fixable on our end.

<br>

## 🎯 Display target_org and code coverage

### target_org

Upon starting Nvim, Sf.nvim executes `:SF org fetchList` to fetch and save
authenticated org names. Display the target_org in your status line to
facilitate command execution against the target org.

If you don't have a default target_org, then this value is empty. You can use `<leader>sfs` to set it.

Example configuration using lualine.nvim with target_org(`xixiao100`):

```lua
    sections = {
      lualine_c = { 'filename', {
        "require'sf'.get_target_org()",
      } },
```

![Image 012](https://github.com/xixiaofinland/sf.nvim/assets/13655323/645a6625-aec6-4593-931e-84534ad3ac4c)

#### Richer statusline component (`lua/sf/statusline.lua`)

`require('sf.statusline')` gives a ready-made component that shows a cloud
icon color-coded by org type (Salesforce blue for production, white for
sandbox, cyan for scratch), only when you're in an sf project, and updates
immediately on org changes -- no polling the CLI. A second component shows
active Apex Replay Debugger trace flags with a countdown to expiry. For
LazyVim / lualine.nvim:

```lua
{
  "nvim-lualine/lualine.nvim",
  optional = true,
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, require("sf.statusline").lualine())
    table.insert(opts.sections.lualine_x, 2, require("sf.statusline").lualine_trace())
  end,
}
```

Both respect the `statusline = { org = true, trace_flags = true,
trace_refresh_minutes = 5 }` config (see `lua/sf/config.lua`); set
`trace_flags = false` to skip the Tooling API query entirely (e.g. if you
don't use the replay debugger).

For a plain `'statusline'` (no lualine):

```lua
vim.o.statusline = "...%{%v:lua.require'sf.statusline'.render()%}"
```

### code coverage

`require('sf').covered_percent()` has the current Apex file code coverage information.
You can
display it as you want. For example, I display it (`92`) in my status line next to target_org (`devhub`), configured in lualine.nvim like below.

<details>
<summary>Example lualine.nvim setup</summary>

```lua
{
  'nvim-lualine/lualine.nvim',
  config = function()
    local function sf_status()
      local target_org = require('sf').get_target_org()
      local covered_percent = require('sf').covered_percent()
      return target_org .. "(" .. covered_percent .. ")"
    end

    require('lualine').setup {
      sections = {
        lualine_c = { 'filename', sf_status },
      },
    }
  end
}
```

</details>

![Image 015](https://github.com/user-attachments/assets/3b1ba158-dbcb-4516-a53c-61a824772933)

<br>

## 🖥️ Terminal

### Integrated terminal

![Image 022](https://github.com/user-attachments/assets/bd61e9fc-fa0d-4782-8f2d-68e90dcb0d10)

The integrated terminal is designed to

- accept input from hotkeys and user commands, such as "retrieve current metadata file"
  `<leader>sfr`
- be a read-only buffer. It's, by design, not allowed to manually type commands
- be disposable. The output text of the previous command is removed when a new command is invoked
- be auto-prompt, in case the terminal is hidden at the moment the command execution completes. This is handy when you have a long-running command.

You can pass any shell command into `run()` method to execute it in the integrated
terminal. For instance, `require('sf').run('ls -la')`.

### Overseer.nvim

As an alternative to the integrated terminal, [overseer.nvim](https://github.com/stevearc/overseer.nvim) can be used to execute terminal commands.

Once enabled

- commands executed by Sf.nvim will be created in overseer as tasks
- the overseer task list can be show or hidden via `:OverseerToggle`

To enable, ensure overseer.nvim is a dependency and set the appropriate flag in your configuration:

```
return {
    'xixiaofinland/sf.nvim',
    dependencies = {
        'nvim-treesitter/nvim-treesitter',
        'stevearc/overseer.nvim',
        "ibhagwan/fzf-lua",
    },
    config = function()
        require('sf').setup({ terminal = 'overseer' })
    end
}
```

<br>

## 🎨 UI: restyled terminal, quiet progress, org dashboard

The integrated terminal, the task progress indicator, and org management
features all share one restyled look: a small, corner-anchored, rounded, blue
float by default. The org dashboard provides an interactive view of your
orgs; other org commands (`:SF org setTarget`, `:SF org setGlobalTarget`, `:SF currentFile
diffIn`) use a quick picker prompt.

### Config reference

```lua
require('sf').setup({
  ui = {
    accent = "#1B96FF",  -- border/title/icon color
    border = "rounded",
    icons = true,        -- set false if you don't have a Nerd Font

    terminal = {
      position = "bottom_right", -- "bottom_right" | "top_right" | "bottom_left" | "top_left" | "center" | "custom"
      width = 0.45,   -- fraction of editor columns (or an absolute cell count if >= 1)
      height = 0.35,  -- fraction of editor lines (or an absolute cell count if >= 1)
      margin = { row = 1, col = 2 },
    },

    -- the quiet progress widget shown for "progress"-mode tasks below
    progress = {
      backend = "float",     -- "float" | "notify" (vim.notify/snacks/noice) | "auto"
      spinner = { "⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏" },
      interval_ms = 80,
      success_timeout_ms = 3000,
      error_timeout_ms = 10000,
    },

    -- how each kind of task is shown: "progress" (spinner only) or "terminal" (visible float)
    task_display = {
      default = "progress",
      deploy = "progress",
      retrieve = "progress",
      test = "terminal",
      query = "terminal",
      anonymous = "terminal",
    },

    expand_on_error = true, -- auto-open the terminal float if a "progress" task fails
  },

  statusline = {
    org = true,
    trace_flags = true,
    trace_refresh_minutes = 5,
  },
})
```

All of the old `term_config` keys (`dimensions`, `border`, `hl`, `blend`)
still work exactly as before -- if you've set any of them explicitly, that
wins over the `ui.*` defaults above (so existing configs are unaffected).

### Quiet progress for deploy/retrieve

Deploy and retrieve no longer pop the terminal open: they show a small
bottom-right spinner instead, with a ✓/✗ result. `<leader><leader>` (or your
own `toggle_term` keymap, or `:SF term output`) expands the full output at
any time; a failed task does this automatically if `expand_on_error` is on.
Tests, queries, and anonymous Apex still show the full terminal, since
their output is what you're there to read.

### Org dashboard

The org dashboard provides a persistent split-pane view of all your orgs and detailed information about each one. Open it with:
- Command: `:SF org dashboard`
- Lua: `require('sf').open_org_dashboard()`
- Default keymap: `<leader>sfg`

The left pane shows your org list (color-coded by type: Salesforce blue for production, white for sandbox, cyan for scratch). Move the cursor to select an org; the right pane displays details and actions for the selected org.

**Navigation and refresh:**

| Key | Action |
| --- | --- |
| `r` | refresh org list and reload the current view |
| `q` / `<Esc>` | close the dashboard |

**View selection (right pane shows different data for each):**

| Key | View |
| --- | --- |
| `d` | Details (basic org info) |
| `s` | Org Status (API version, features, limits) |
| `t` | Trace Flags (active debug logging) |
| `l` | Logs (API debug logs) |
| `u` | Org Limits (usage and allocation) |
| `p` | Installed Packages |

**Actions (perform an operation on the selected org):**

| Key | Action |
| --- | --- |
| `L` | Set as local default (`target-org` in `.sf/config.json`) |
| `G` | Set as global default (`target-org` in `~/.sf/config.json`) |
| `o` | Open in browser |
| `e` | Enable trace flag logging (Apex Replay Debugger) |

**In the Logs view:**

| Key | Action |
| --- | --- |
| `f` | Filter logs by query string |
| `<CR>` | Download the log under the cursor (requires focus in the right pane) |

### Overriding colors

Every highlight group is defined with `default = true`, so your colorscheme
or your own `vim.api.nvim_set_hl(0, "SfBorder", { fg = "#your-color" })`
(after `require('sf').setup()`, or on `ColorScheme`) always wins. Groups:
`SfBorder`, `SfTitle`, `SfFooter`, `SfNormal`, `SfSpinner`, `SfCloudIcon`,
`SfSuccess`, `SfError`, `SfWarn`, `SfStatusOrg`, `SfStatusProd`,
`SfStatusSandbox`, `SfStatusScratch`, `SfStatusTrace`. The simplest way to
rebrand everything at once is `ui.accent` in `setup()`, which most of these
derive from by default.

<br>

## 🏃 Enhanced jump-to-definition (Apex)

Salesforce's Apex LSP (apex-jorje-lsp.jar) offers a jump-to-definition feature, but it's not
perfect. You may encounter cases where it doesn't function correctly in certain codebases. To
address this, the LSP jump-to-definition is enhanced by ctags.

If you don't yet know what ctags is, it's wise to google "ctags in vim" to prepare a bit more.

Ctags is ideal in this scenario because:

- It is natively supported by Nvim/Vim, although you need to install `ctags` yourself
- The default `<C-]>` key in Nvim will first attempt to jump with LSP and fall back to ctags if LSP fails

There are several versions of ctags, this repo uses [universal
ctags](https://github.com/universal-ctags/ctags). So you need to install it to use this feature.

### How to use it?

`:SF create ctags` or `require('sf').create_ctags()` generates the ctags file in the project root.
Using the `<C-]>` key for jump-to-definition will automatically use both LSP and ctags in order.
`:SF create ctagsAndList` or `require('sf').create_and_list_ctags()` will update ctags and list the tags symbols in `fzf-lua`
plugin.

<br>

## 📚 Read More

Full documentation can be accessed via `:h sf.nvim` or [help.txt file](https://github.com/xixiaofinland/sf.nvim/blob/dev/doc/sf.txt).

<br>

## 🏆 Contributions

Please create an issue to discuss your PR before submitting it. This ensures
that the PR will be merged.

The PR should be done against `main` branch.
Commit messages should follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), or the
PR would fail in the status check.

For example,

- If it's a new feature, the commit message could be "feat: add a new user command".
- If it's a bug fix, the commit message could be "fix: eliminate the error".

The `help.txt` file is auto-generated from the comments with the `---` suffix
before each function in [init.lua](https://github.com/xixiaofinland/sf.nvim/blob/dev/lua/sf/init.lua). The plugin
uses `mini.doc` to automatically generate `help.txt` from these `---` suffixed comments. Therefore,
add your doc content in `init.lua` without touching `help.txt` is sufficient.

<br>

## 📜 License

MIT.
