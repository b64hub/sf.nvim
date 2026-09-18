# Apex Replay Debugger for sf.nvim — handover report

**RESOLVED as of this update.** Breakpoints stop correctly, and the earlier
"resolves into the `dist` build copy" bug is fixed too. See "Resolution"
below — the rest of this doc is kept as-is for the investigation trail.

Status: **Phases 0-2 fully implemented and verified working end-to-end in
the human's live environment.**

Repo: this worktree (`feat-debugging`). Uncommitted changes only (no commits
made yet) — see "Files changed" below.

## Resolution

Root cause of "breakpoints don't stop": the human's diagnostic attempts hit
two unrelated Neovim/nvim-dap footguns before we got real evidence (see
"Current blocking issue" below, kept for the record). Once a clean trace
capture was taken, breakpoints verified and stepping worked correctly.

That surfaced a second, real bug: stepping resolved into
`src/service/ads/dist/force-app/classes/controllers/AdsTestController.cls`
(a generated build-output duplicate) instead of the real source file under
`src/service/ads/classes/controllers/`. Cause: `apex_ls` returns
`lineBreakpointInfo` entries for **both** copies (jorje indexes the whole
project regardless of `.forceignore`, which is a deploy/retrieve filter, not
an indexer filter), and the adapter's `typerefMapping` is last-one-wins per
typeref — whichever copy apex_ls lists last for a given class becomes the
file used for stepping/stack frames.

**Fix** (`lua/sf/debug.lua`, `H.filter_ignored`): after fetching
`lineBreakpointInfo` from `apex_ls`, filter out any entry whose file matches
a pattern in the project's own `.forceignore` (already lists `**/dist` /
`**/dist/**` in this project) before caching/injecting it. This reuses the
project's existing ignore mechanism rather than adding new config, and fixes
both the verification and the stepping-resolves-to-wrong-file problem in one
place, since the ignored copy's `uri` never enters the adapter's mapping at
all. Verified against the human's real `.forceignore` and real (cached)
`lineBreakpointInfo.json`: 2737 → 1394 entries, all 1343 `dist/` entries
dropped, `AdsTestController` now resolves to exactly one (correct) `uri`.
Ponytail-simplified glob matching (`**`, `*`, leading `/`; no negation, no
character classes) — flagged with a `ponytail:` comment for its known edge
cases; good enough for real-world `.forceignore` files.

## What was built (original investigation notes follow)

### Phase 0 — Discovery (docs/replay-debugger-notes.md)
Downloaded the real adapter (`salesforce.salesforcedx-vscode-apex-replay-debugger`
v67.17.16) and the core Apex extension (`salesforcedx-vscode-apex` v67.17.16)
from Open VSX, unzipped, and read the actual bundled JS (not just the plan's
assumptions) to confirm every protocol detail. One real deviation from the
handoff plan was found and documented: **this adapter version does not read
`logFile` at all** — it expects `logFileContents` (raw text), `logFilePath`,
`logFileName`, which the VS Code extension host normally prepares before
spawning the adapter. Since nvim-dap talks to the adapter directly, `sf.nvim`
now does that preprocessing itself. Everything else in the plan (§0) was
confirmed exactly: `lineBreakpointInfo` shape, the `debugger/lineBreakpoints`
LSP call (no params), `stopOnEntry`, `trace` categories.

### Phase 1 — `lua/sf/debug.lua` (new) + `lua/sf/config.lua`
- `replay_debugger` config block (`adapter_path`, `node_path`, `stop_on_entry`,
  `trace`, `lsp_timeout`, `log_globs`).
- `Debug.setup_dap()`: registers nvim-dap's `"apex-replay"` adapter as a
  function (lazy path resolution), with `pcall(require, "dap")` so nvim-dap
  stays optional. Adapter's `enrich_config` fetches/caches
  `lineBreakpointInfo` from `apex_ls` and injects it before every launch.
- `Debug.launch(log_path)`: reads the log file into a string, builds
  `logFileContents`/`logFilePath`/`logFileName`, calls `dap.run(...)`.
- Verified headlessly: adapter registers, `enrich_config` reaches
  `apex_ls`/errors correctly, full `dap.run` → adapter → `enrich_config` →
  `debugger/lineBreakpoints` chain runs end to end with the real nvim-dap
  package.

### Phase 2 — user-facing commands
- `lua/sf/org.lua`: extracted `Org.pick_log(dir, on_done)` (public) from the
  existing `pull_log`'s fzf/download logic, so it can target either the
  plugin's `logs/` folder (existing behaviour, unchanged) or
  `.sfdx/tools/debug/logs/` (new).
- `lua/sf/debug.lua` additions: `replay_current_log`, `replay_local_log`
  (globs `.sfdx/tools/debug/**/*.log` + plugin logs folder, fzf-lua or
  `vim.ui.select`, newest first, deduplicated), `replay_org_log` (via
  `Org.pick_log`), `replay_last_log` (persisted to
  `sf_cache/debug/last_log.txt`), `refresh_breakpoint_info`. Also fixed a real
  gap from Phase 1: `enrich_config` wasn't actually using the cache it wrote;
  now it does, and a `BufWritePost` on `*.cls`/`*.trigger` invalidates it.
- `lua/sf/init.lua`: exported all five as `Sf.replay_debug_*` /
  `Sf.refresh_debug_breakpoint_info` with doc comments.
- `lua/sf/sub/config_user_command.lua`: `:SF debug current|local|org|last|refresh`.
- `lua/sf/sub/config_user_key.lua`: opt-in keymaps `<leader>slc/sll/slo/slr/slb`.
- Full existing test suite (80 cases) still passes; new surface smoke-tested
  headlessly (local log discovery/sort/dedupe, fzf pick → launch, `:SF debug
  last` persistence, `:SF debug refresh` error path).

### Human's Neovim config changes (outside this repo)
- `~/.config/nvim/lua/salesforce/plugins/sf.lua`: points lazy.nvim at this
  worktree (`dir = ".../feat-debugging"`), source renamed to
  `"b64hub/sf.nvim"` (their fork), `adapter_path` wired to the Phase-0
  downloaded adapter at
  `~/.local/share/sf-nvim/apex-replay-debugger/extension/dist/apexReplayDebug.js`.
- `~/.config/nvim/lua/salesforce/plugins/lsp/dap.lua`: removed the old
  hand-rolled `dap.adapters["apex-replay"]` (server/port 4712) and
  `dap.configurations["apex-replay"]` (now owned by sf.nvim); added keymaps
  (`<leader>db/dc/do/di/dO/dt/dr`); fixed `nvim-dap-ui`'s lazy-load spec
  (`lazy = false` — it was `cmd`-gated on `:Dap*` commands that our keymaps,
  calling the Lua API directly, never actually invoke, so `dapui`'s listeners
  were silently never registered).
- Their sfdx project's `.vscode/launch.json` had a stale "Launch Apex Replay
  Debugger" entry (VS Code snippet, unresolved `${command:AskForLogFileName}`)
  that nvim-dap's `dap.launch.json` provider offers **unconditionally**
  whenever `:DapContinue`/`dap.continue()` finds no active session — picking
  it fed garbage args straight to the adapter (crashed on
  `getFileSizeFromContents(undefined)`, since it bypasses `sf.nvim`'s
  `Debug.launch()` entirely). Removed that one entry.

## Current blocking issue

**Breakpoints set in the human's live session are not being hit** — the
replay session starts, stops on entry fine, but `<leader>dc`/`:DapContinue`
runs to completion (or appears to just exit) instead of stopping at
breakpoints set on lines confirmed to be both (a) in the executed method
(`AdsTestController.getAdsTests`, lines 5/7/10/12) and (b) present in the
cached `lineBreakpointInfo` for that exact file.

**This is not reproducible in isolation.** A headless repro was built using
the *exact* real adapter binary, the *exact* log file
(`.sfdx/tools/debug/logs/07LbY00000V9FffUAF.log`), the *exact* cached
`lineBreakpointInfo` entry for `AdsTestController.cls`, and a real nvim-dap —
faking only the `apex_ls` LSP client (since a fresh headless session has no
running language server). That repro **works**: breakpoint on line 5 is
reported `verified lines=5` by the adapter and a real `EVENT stopped: reason
= "breakpoint"` fires. Script + evidence are in this chat transcript, not
committed to the repo (ad hoc `/tmp/repro.lua`).

So the `sf.nvim` ↔ nvim-dap ↔ adapter wiring is proven correct for this exact
data. Something differs in the human's live session, and we do not yet have
direct evidence of what, because:

1. First diagnostic attempt used `vim.g.sf.replay_debugger.trace = "..."` to
   turn on adapter tracing — **silently a no-op**. This is a genuine Neovim
   `vim.g` semantics gotcha: `vim.g.foo` returns a fresh copy on every read,
   so mutating a nested field of that copy never persists. Confirmed via the
   REPL dump showing no `setBreakPointsRequest`/trace output at all, only the
   untraced "session started" line.
2. Second attempt used `require("sf").setup({replay_debugger={trace=...}})`
   to fix that — but this **wiped `adapter_path`** back to `nil`, because
   `setup()` merges the given opts against `default_cfg`, not against
   whatever the human's own `sf.lua` originally passed in. That is arguably a
   design wart worth revisiting (`setup()` being called twice loses prior
   config unless the caller repeats every field) but is at minimum a footgun
   for interactive `:lua require("sf").setup({...})` debugging one-liners.
   Corrected one-liner given to the human (deep-copies the *live*
   `vim.g.sf`, not defaults):
   ```lua
   local c = vim.deepcopy(vim.g.sf); c.replay_debugger.trace = "launch,breakpoints"; vim.g.sf = c
   ```
3. As of this report, **we still do not have a real trace dump from the
   human's live session** confirming or ruling out breakpoint verification.
   That is the single most important missing piece of evidence.

### Leading hypotheses, unconfirmed
- **Breakpoint set in the wrong copy of the file.** This specific sfdx
  project has `AdsTestController.cls` in two places
  (`src/service/ads/classes/controllers/...` and
  `src/service/ads/dist/force-app/classes/controllers/...`), both present as
  separate entries in the cached `lineBreakpointInfo` (same typeref, same
  valid lines, different `uri`). If the human's buffer/breakpoint ended up
  against the "dist" copy while assumptions were made about the "src" copy
  (or vice versa), and the content differs even slightly, this would explain
  silent non-verification. **Not yet confirmed** — we asked for
  `:lua print(vim.inspect(require('dap').breakpoints.get()))` output but
  never received it.
- **Stale in-memory cache mismatched to a freshly-edited file.** `H.cache`
  (module-level) is invalidated on `BufWritePost` for `*.cls`/`*.trigger`,
  but the on-disk `sf_cache/debug/lineBreakpointInfo.json` is never read back
  in — each Neovim session starts with `H.cache == nil` and refetches from
  the *live* `apex_ls` on first launch. If that live fetch differs even
  slightly from what's on disk (line-number drift since the file was last
  saved, indexing not finished, etc.), lines could mismatch. Not yet ruled
  out because we don't have the live trace output.
- **Multiple sessions / restart state.** Given the number of `:Lazy reload`
  vs. full-restart cycles during this session, it's possible a stale nvim-dap
  session or duplicate adapter registration is in play. Not investigated.

### Concrete next step for whoever picks this up
Get one clean, complete repro cycle with trace properly enabled (use the
corrected one-liner above, not `setup()` or direct `vim.g` nested mutation),
then read back `/tmp/dap_repl.txt` (or the `dap-repl` buffer) for the
`setBreakPointsRequest: ... verified lines=...` line(s). That single piece of
evidence will either:
- show `verified=false` for the lines in question → confirms a URI/line
  mismatch (compare the printed `uri=` against
  `require('dap').breakpoints.get()`'s path and against
  `sf_cache/debug/lineBreakpointInfo.json`'s matching `uri` entry, byte for
  byte), or
- show `verified=true` → the bug is elsewhere (timing, session state, a
  second stale adapter/session, etc.) and needs different instrumentation
  (e.g. `dap.listeners.after.event_stopped` / `event_terminated` to see which
  fires and why).

## Files changed (uncommitted, this worktree)
```
 M lua/sf/config.lua
 M lua/sf/init.lua
 M lua/sf/org.lua
 M lua/sf/sub/config_user_command.lua
 M lua/sf/sub/config_user_key.lua
?? docs/replay-debugger-notes.md
?? lua/sf/debug.lua
```
Plus, outside this repo, on the human's machine:
`~/.config/nvim/lua/salesforce/plugins/sf.lua`,
`~/.config/nvim/lua/salesforce/plugins/lsp/dap.lua`,
`<project>/.vscode/launch.json` (one entry removed).

## Not started
(none — all four phases complete, see below)

## Phase 3 & 4 — completed

### Phase 3 — replay-ready logging
- `Debug.enable_replay_logging(minutes)` / `disable_replay_logging()`: finds
  or creates a `SFNVIM_REPLAY` DebugLevel (ApexCode=FINEST,
  Visualforce=FINER) and creates/extends (or deletes) a `TraceFlag` for the
  current user via `sf data query|create|update|delete record
  --use-tooling-api`. Verified end-to-end against a real scratch org in this
  sandbox (create, extend-instead-of-duplicate, delete all confirmed via
  direct SOQL checks).
- `Debug.run_test_and_replay()` (`:SF debug test`): runs the test under the
  cursor (extended `Test.run_current_test` to accept an optional callback,
  rather than duplicating command-building), then downloads and launches the
  newest org log via a new `Org.download_log(log_id, dir, on_done)` primitive
  (also used to de-duplicate the existing fzf-based log picker).
- `:SF debug enable [minutes] | disable | test`.
- Note: exact `sf` CLI flags (`-t`/`--use-tooling-api` needed even for
  `data query`, `-s`/`-v`/`-i`/`-q`) were verified against the real installed
  CLI's `--help` output and a live scratch org before writing code, not
  assumed from the plan text.

### Phase 4 — polish
- `lua/sf/health.lua`: `H.check_replay_debugger()` — warns (doesn't error) on
  missing nvim-dap / node / adapter, with install hints. Verified via
  `:checkhealth sf`.
- `Debug.install_adapter()` (`:SF debug installAdapter`): downloads the
  latest adapter VSIX from Open VSX and unzips it into the same
  `stdpath("data")/sf-nvim/apex-replay-debugger/` location the auto-detect
  logic already checks. Requires `curl`+`unzip`. Verified end-to-end in this
  sandbox (real download, real unzip, then confirmed auto-detect finds it).
- README: new "🐛 Feature: Apex Replay Debugger" section (setup, workflow,
  known limitations), `replay_debugger` added to the Configuration example,
  a Prerequisites bullet.
- `doc/sf.txt` regenerated via `mini.doc`/`U.gen_doc()`. Along the way, fixed
  a real pre-existing bug in `U.gen_doc()`: `mini.doc.generate()` derives its
  output filename from cwd's directory basename when not given explicitly,
  which breaks in a git-worktree checkout (this worktree's folder is
  `feat-debugging`, not `sf.nvim`) — now passes `"doc/sf.txt"` explicitly.
  **Heads up:** the regenerated `doc/sf.txt` is a much larger diff than just
  the new Debug entries — the previously-committed file was stale (it
  still documented removed helper functions like `H.open_apex()` /
  `H.retrieve_md()` that don't exist anywhere in current source, and had a
  richer, outdated format for `Sf.refresh_sobjects` that no longer matches
  its current plain-prose doc comment). The regenerated file matches current
  source exactly, which is objectively more correct, but worth a deliberate
  look before merging since it's a bigger diff than expected.

All 80 existing tests still pass throughout.

## Follow-up: REST API speed + trace flag ergonomics

Based on feedback (CLI is slow; inspiration: https://github.com/jamessimone/sf-trace-plugin):

- **Speed:** `enable_replay_logging`/`disable_replay_logging`/the newest-log
  lookup in `run_test_and_replay` now do one `sf org display` CLI call (to get
  an access token — unavoidable, this is how `sf` resolves auth; not worth
  reimplementing OAuth/JWT/web-login flows) and then talk to the Tooling REST
  API directly via `curl` for every query/create/update/delete. Verified live:
  a plain Tooling query via curl takes ~0.3s vs. ~6s for the equivalent
  `sf data query` CLI invocation (Node cold-start dominates the CLI's cost,
  not network latency). `disable_replay_logging` end-to-end measured at
  ~8.4s (previously ~18s+ for 3 sequential CLI calls); `enable` (previously
  5 sequential CLI calls, ~30s+) is now similarly dominated by the single
  unavoidable `sf org display` call. Requires `curl` (already an optional
  dependency for `installAdapter`; now required for the logging feature
  too — no fallback CLI path was kept, to avoid maintaining two
  implementations of the same logic).
- **Configurable default expiry:** new `replay_debugger.trace_flag_hours`
  (default `1`, i.e. 1 hour — was a hardcoded 30 minutes). Duration is
  clamped to Salesforce's 24h `TraceFlag` max (matches sf-trace-plugin's
  documented behavior).
- **Target a specific user:** `Debug.enable_replay_logging`/`disable_replay_logging`
  accept an optional `user` (username, email, or raw `005...` Id) instead of
  only ever targeting the current org user — `:SF debug enable 120
  someone@example.com`, `:SF debug disable someone@example.com`.
- **Easy user selection:** `:SF debug enableFor [minutes]` /
  `Debug.pick_user_and_enable_replay_logging(minutes)` queries active users
  via the Tooling REST API and lets you pick one (fzf-lua, else
  `vim.ui.select`) rather than typing a username.

All verified against the real scratch org in this sandbox: query/create/
update/delete via curl, `enable`→`disable` round trip, and the "extend
instead of duplicate" active-TraceFlag logic, all re-confirmed working after
the REST rewrite. Full test suite still green.

