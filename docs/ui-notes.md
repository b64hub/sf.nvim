# Phase 0 — Discovery notes

## Callers of `t:run` / `Term.run` / `T:run`

Every call site under `lua/sf/`, what it runs, whether it passes a callback,
and whether that callback reads `self.buf`.

| File:line | Call | Callback? | Reads `self.buf`? | Suggested category (Phase 2) |
|---|---|---|---|---|
| `term.lua:40` `Term.save_and_push` | `t:run(cmd)` | no | – | `deploy` |
| `term.lua:53` `Term.push_delta` | `t:run(cmd)` | no | – | `deploy` |
| `term.lua:71` `Term.retrieve` | `t:run(cmd, cb)` | yes, `cb` opens the retrieved file (`U.try_open_file`) | no | `retrieve` |
| `term.lua:84` `Term.retrieve_delta` | `t:run(cmd)` | no | – | `retrieve` |
| `term.lua:93` `Term.retrieve_package` | `t:run(cmd)` | no | – | `retrieve` |
| `term.lua:120` `Term.run_anonymous_stdin` | `t:run(cmd)` | no | – | `anonymous` |
| `term.lua:129` `Term.run_anonymous` | `t:run(cmd)` | no | – | `anonymous` |
| `term.lua:138` `Term.run_query` | `t:run(cmd)` | no | – | `query` |
| `term.lua:148` `Term.run_tooling_query` | `t:run(cmd)` | no | – | `query` |
| `term.lua:168` `Term.run_highlighted_soql` | `t:run(raw_cmd)` | no | – | `query` |
| `term.lua:177` `Term.go_to_sf_root` | `t:run("cd " .. root)` | no | – | nil (default) |
| `term.lua:180-182` `Term.run` (public passthrough) | `t:run(cmd, cb)` | forwards whatever caller passes | n/a | forwards `opts` |
| `md.lua:79` `H.retrieve_md` (used by `retrieve_apex_under_cursor` etc.) | `T.run(cmd, cb)` | yes, opens the apex file after retrieve | no | `retrieve` |
| `md.lua:216` `H.retrieve_md_type` | `T.run(cmd)` | no | – | `retrieve` |
| `md.lua:321` delete-class flow | `T.run(cmd, function(_,_,exit_code) ... end)` | yes, only uses `exit_code` | no | `deploy` (delete via project delete source) |
| `md.lua:397` rename-class flow (deploy step) | `T.run(deploy_cmd, function(_,_,exit_code) ... end)` | yes, only uses `exit_code` | no | `deploy` |
| `test.lua:49` `run_current_test_with_coverage` | `T.run(cmd, H.save_test_coverage_locally)` | yes | **yes** — reads `self.buf` to find "Test Run Id" | `test` |
| `test.lua:78` `run_current_test` | `T.run(cmd)` | no | – | `test` |
| `test.lua:99` `run_all_tests_in_this_file_with_coverage` | `T.run(cmd, H.save_test_coverage_locally)` | yes | **yes** | `test` |
| `test.lua:123` `run_all_tests_in_this_file` | `T.run(cmd, cb)` | forwards caller's `cb` | depends on caller | `test` |
| `test.lua:131` `repeat_last_tests` | `T.run(U.last_tests)` | no | – | `test` (best-effort; command text doesn't encode category) |
| `test.lua:148` `run_local_tests` | `T.run(cmd)` | no | – | `test` |
| `test.lua:152` `run_all_jests` | `T.run("npm run test:unit:coverage")` | no | – | `test` |
| `test.lua:160` `run_jest_file` | `T.run(cmd)` | no | – | `test` |
| `test.lua:289` prompt `cc` keymap (run selected tests) | `T.run(cmd)` | no | – | `test` |
| `test.lua:302` prompt `CC` keymap (run selected tests w/ coverage) | `T.run(cmd, H.save_test_coverage_locally)` | yes | **yes** | `test` |
| `raw_term.lua:138` `T:cancel` | `self:run("\3")` | no | – | internal, not a task |

**Only one callback reads `self.buf`:** `test.lua`'s `H.save_test_coverage_locally`
(used 3 places). Any hidden-terminal implementation in Phase 2 must still
write output into `self.buf` so this keeps working — confirmed as a hard
constraint, not just a plan assumption.

`overseer_term.lua:21` `T:run(cmd, cb)` has no third argument today. Phase 2
requires it to accept and ignore an `opts` table.

## `U.target_org` assignment sites

Grepped `target_org\s*=` under `lua/sf/`:

1. `lua/sf/org.lua:143` — inside `H.set_target_org`'s `silent_job_call` callback (user picked an org via `:SF org setTarget`).
2. `lua/sf/org.lua:165` — inside `H.set_global_target_org`'s callback (`--global` variant).
3. `lua/sf/org.lua:189` — inside `H.store_orgs`, when parsing `sf org list --json` and finding `isDefaultUsername`.

`lua/sf/util.lua:4` only *declares* `M.target_org = ""` (not an assignment to
replace). No other assignment sites found elsewhere in the repo.

## Plugin availability — confirmed by human

Installed: **snacks.nvim**, **noice.nvim**, **lualine.nvim**. Not mentioned:
nvim-notify, fidget.nvim — treat as absent. Phase 2 `notify` backend should
target `Snacks.notifier` first (per plan), `vim.notify` will be routed
through noice regardless. `lualine.nvim` present → Phase 3/4 components apply
directly, no plain-statusline-only fallback needed (but keep `M.render()`
for completeness per plan).

## `T:cancel()` — reads as broken today

`T:cancel()` does:
```lua
function T:cancel()
  self.is_running = false
  self:run("\3")
end
```
`T:run` unconditionally creates a **new** scratch buffer and window (or reuses
the float) and calls `run_after_setup`, which does `vim.fn.termopen("\3", ...)`.
That starts a brand-new shell trying to execute the two-byte string `\3` as a
command — it does not send an interrupt to the previously running job's
channel. The old terminal job is simply orphaned (its buffer is swapped out
of the window, but the job keeps running in the background since termopen
jobs are tied to the buffer, not the window).

So: **confirmed by reading the code, `<C-c>` does not stop the running `sf`
process.** Human could not manually verify this turn (worktree pointed at a
stale checkout) — fine, the code-level read stands on its own and Phase 2
will replace this with `vim.fn.jobstop(job_id)` (or `chansend(job_id, "\3")`
for a graceful interrupt first). Re-check manually once convenient:
start a long `retrieve`, press `<C-c>` in the `SFTerm` buffer, and check
`ps aux | grep sf` afterwards.

## `sf org list --json --skip-connection-status` sample — confirmed

Human provided real output. Confirmed fields on `nonScratchOrgs` /
`scratchOrgs` / `sandboxes` entries relevant to Phase 3:
- `isScratch` (bool) — already used by `H.store_orgs`.
- `isSandbox` (bool) — present on sandbox entries (`isSandbox: true` under
  `result.sandboxes`, and also appears — always `false` — on
  `nonScratchOrgs`/`devHubs` entries, since those are prod/devhub). Not
  present on `scratchOrgs` entries at all (scratch orgs are never sandboxes).
  So "is this org production" = `not isScratch and not isSandbox`.
- `isDevHub` (bool) — present everywhere; true for devhub-capable orgs, not a
  prod/sandbox signal by itself (a devhub can be a plain prod org too).
- `instanceUrl` contains `.sandbox.my.salesforce.com` for sandboxes,
  `.scratch.my.salesforce.com` for scratch orgs — a fallback pattern if
  `isSandbox` is ever absent, but prefer the explicit boolean fields.
- **Correction to an earlier note in this file**: I originally flagged
  `result.sandboxes` not being merged into `H.store_orgs` as a bug. Re-checked
  the actual sample JSON carefully: `tn-dev` and `tn-uat` (the two sandboxes)
  **do already appear in `result.nonScratchOrgs` too**, each carrying
  `isSandbox: true`. `result.sandboxes` is just a redundant filtered view of
  the same entries, not an exclusive source. So `H.store_orgs`'s existing
  merge of `nonScratchOrgs` + `scratchOrgs` already sees every org, sandboxes
  included — **no bug, no fix needed**. Phase 3 only needs to read the
  `isScratch`/`isSandbox` fields already present on each entry it iterates.

## `lua/sf/debug.lua` — resolved

Initially flagged as missing: this branch (`feat-style`) had been cut from a
local `main` (`420c259`) that predated the replay-debugger merge. Human
confirmed it was already merged upstream (`origin/main`, PR #1,
`c41b916`) but not yet pulled locally.

Fixed by fast-forwarding `feat-style` onto `origin/main` (`git fetch && git
merge --ff-only origin/main`) — a clean fast-forward, no conflicts, no
unrelated edits needed. `lua/sf/debug.lua`, `lua/sf/sub/rest_api.lua`, and
`docs/replay-debugger-notes.md` are now present.

Confirmed Phase 4 reuse points in `debug.lua`:
- `Debug.enable_replay_logging(opts)` / `Debug.disable_replay_logging(user)`
  — call these from state.lua's org-change/refresh flow rather than
  duplicating TraceFlag upsert logic.
- `H.resolve_target_user`, `H.find_or_create_debug_level`,
  `H.upsert_trace_flag`, `H.parse_sf_datetime` (UTC-safe datetime parsing —
  reuse instead of writing a new SF datetime parser for `ExpirationDate`
  filtering) are private (`H.*`) — Phase 4 will need `debug.lua` to expose a
  small querying helper (e.g. `Debug.get_active_trace_flags(cb)`) or
  `state.lua` reimplements just the tooling query + `H.parse_sf_datetime`-style
  parsing using `Api` from `lua/sf/sub/rest_api.lua` directly (already public
  module). Decide exact seam when Phase 4 starts.
- `Api.get_session(cb)` in `rest_api.lua` is the existing "get session for
  target org" helper — reuse for any new tooling query in Phase 4.

## overseer_term.lua

Confirmed unrelated to this work — its own `overseer.open/close/toggle`
UI, no float geometry or highlight code to touch. Only change needed later:
accept a 3rd `opts` arg in `T:run` and ignore it, for signature parity with
`raw_term.lua`.

## Config surfaces confirmed

- `lua/sf/config.lua`: `default_cfg` currently has `term_config` (`ft`,
  `blend`, `dimensions{height,width,x,y}`, `border`, `hl`, `clear_env`) and
  `terminal` (`"integrated" | "overseer"`). No `ui` section yet — Phase 1
  adds it fresh, no collision.
- `lua/sf/sub/config_auto_cmd.lua`: `SFTerm` filetype autocmd sets
  `<leader><leader>` → `toggle_term`, `<C-c>` → `cancel`. `q` close key is not
  yet mapped (Phase 1 adds it).
- `ColorScheme` autocmd does not exist yet (Phase 1 must add one, calling
  `highlights.setup()`).
</content>
