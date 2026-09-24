# Org dashboard — tabs, dedupe bug, merged Details view (ordered plan)

Follow-up to `docs/org-dashboard-implementation-plan.md`. Same shape:
phases with numbered steps, each naming the exact files/functions it
touches and the test that proves it.

## Findings before Step 1 (read this; do not re-derive)

### Bug 1 — "orgs listed twice" — ROOT CAUSE CONFIRMED

Cause **(a)**: `helpers.fetch_org_list` (`lua/sf/org.lua`) calls
`helpers.clean_org_cache()` **synchronously at dispatch**, then starts an
async `jobstart`. `helpers.store_orgs` only ever **appends**. So two
`fetch_org_list` calls that overlap in time clear-clear-then-append-append
and every org ends up in `helpers.orgs` twice.

Reproduced headlessly (`nvim --headless --noplugin -u
./scripts/minimal_init.lua -c "luafile ..."`) with a `vim.fn.jobstart`
mock that resolves after 50 ms instead of synchronously — the earlier
failed repros in this session all used a *synchronous* mock, which is
exactly why they looked clean:

```
Org.fetch_org_list(); Org.fetch_org_list()  -->  #orgs = 4  (org1, org2, org1, org2)
```

Real-world trigger: `sf org list --json --skip-connection-status` takes
several seconds on a real machine (measured here). The `VimEnter`
autocmd in `lua/sf/sub/config_auto_cmd.lua` (`fetch_org_list_at_nvim_start`,
default `true`) is still in flight while the user presses `<leader>sff`
(`config_user_key.lua`) or runs `:SF org fetchList`
(`config_user_command.lua`), then opens the dashboard — which renders
`helpers.orgs` as-is. Dashboard `r` pressed twice hits the same window
(already noted as a `ponytail:` comment at `org_dashboard.lua:324`, which
described the race but treated it as theoretical — it is not).

Ruled out, with evidence:

- **(b) sf-CLI-level duplicates**: ran the real
  `sf org list --json --skip-connection-status` in this environment.
  `nonScratchOrgs` (6) + `scratchOrgs` (8) = 14 merged entries, **zero**
  duplicate usernames, **zero** duplicate aliases. `sandboxes` (2) and
  `devHubs` (4) are redundant filtered views already contained in
  `nonScratchOrgs` and are not read by `store_orgs` anyway (matches the
  correction already recorded in `docs/ui-notes.md`). **Do not add
  defensive dedupe** — it is unrequested complexity for an unobserved
  input. If a user ever reports it, dedupe by `username` in `store_orgs`,
  preferring the entry that has an `alias`.
- **(c) stacked dashboard instances**: a second `dashboard.open` does
  create a second pair of floats, but at *identical* geometry, so it
  cannot look like a doubled list. It is still a real latent bug (the
  fixed `SfOrgDashboardCursor` augroup is created with `clear = true`, so
  instance 2 silently kills instance 1's `CursorMoved` handler, and `q`
  only closes the top instance). Fixed as a cheap Phase 1 add-on, not as
  the cause.
- **(d) full call graph**: `config_auto_cmd.lua`'s
  `BufWinEnter`/`FileType`/`DirChanged` handler only re-registers keys and
  user commands; the `VimEnter`/`FocusGained`/`DirChanged`
  `refresh_target_org_from_disk` path never fetches; `statusline.lua`'s
  lualine `on_click` only opens the dashboard. The augroup is created with
  `clear = true`, so `config.setup()` running twice cannot double-register
  the `VimEnter` fetch. No other fetch source exists.

The fix per the AGENTS.md ladder is one moved line in the shared function
every caller routes through, not a guard in each caller.

### Tabs — chosen affordance

`lua/sf/ui/layout.lua`, `lua/sf/ui/icons.lua` and `lua/sf/ui/highlights.lua`
were read: there is no existing tabline/statuscolumn helper to reuse, and
no highlight group needs to be added (`SfTitle` for the active tab,
`SfFooter` for inactive ones already exist and already mean exactly that).

Chosen: a **tab strip rendered as the first line(s) of the view buffer**,
built in `paint_view` *around* the existing loading/error/data branch, so
it shows in every state without touching a single `view_desc.render`
function. Rejected alternative: putting the strip in the float title via
`nvim_win_set_config` — marginally less code, but it truncates silently on
narrow terminals, whereas a buffer line can wrap inside a window we
control. The one cost of the buffer approach is that the logs `<CR>`
handler maps cursor row to `session.filtered_logs` index, so it needs a
header offset; that is one dynamic value, not a magic constant.

No tab framework. `dashboard_views.lua` stays a plain array.

---

## Phases

### Phase 1 — Bug fix: duplicated org list (independent of everything else)

1. `lua/sf/org.lua`: move `helpers.clean_org_cache()` out of
   `helpers.fetch_org_list` and into `helpers.store_orgs`, as its first
   statement (before the JSON decode, or immediately after it and before
   the insert loop — either is fine as long as it is on the arrival path,
   not the dispatch path). Overlapping fetches then become last-writer-
   wins instead of additive. `clean_org_cache` already clears in place, so
   the dashboard's captured `records` reference (it is `helpers.orgs`
   itself) stays valid. Delete the now-dead call site in
   `fetch_org_list`; leave `util.is_sf_cmd_installed()` where it is.
   Verified against the same headless harness: three overlapping fetches
   then yield `#orgs = 1` for a one-org payload.
   Test: new case in `tests/test_org.lua`, matching the existing
   `fetch_org_list` mock-`jobstart` pattern but with the mock deferring
   via `vim.defer_fn(..., 30)` instead of firing synchronously; call
   `fetch_org_list()` twice back to back, `vim.wait`, assert
   `#Org.__test.orgs == 2` for a two-org payload. This test fails on
   `main` (returns 4) and passes after the move.
2. `lua/sf/ui/org_dashboard.lua`: update the stale `ponytail:` comment
   above the `r` keymap — the race it describes is now fixed by Step 1,
   so the comment should either go away or shrink to "last-writer-wins,
   no in-flight guard needed". Do not add an in-flight flag; the
   arrival-side clear makes one unnecessary.
3. `lua/sf/ui/org_dashboard.lua`: singleton guard. Hold the live session
   in a module-local (e.g. `local active_session`); at the top of
   `dashboard.open`, if the previous session's windows are still valid,
   `nvim_set_current_win` on its list window and return instead of
   opening a second pair of floats; clear the module-local in `close`.
   This also removes the `SfOrgDashboardCursor` cross-instance collision.
   Test: extend `tests/test_org_dashboard.lua` — call `dashboard.open`
   twice, assert the window count after the second call equals the count
   after the first.

Phase 1 is self-contained and touches no function that Phases 2-4 touch,
except the two small edits in Step 2/3 (a comment and the top of
`dashboard.open`) — neither of which overlaps `paint_view`/`show_view`/
`footer_for`/`get_view_title`.

### Phase 2 — Consolidate Details + Org Status into one view

4. `lua/sf/ui/dashboard_views.lua`: extract the existing `status` entry's
   `render` body into a file-local
   `render_status_section(status_data, status_err)` returning
   `lines, line_hls` (reusing the existing `status_highlight` helper
   unchanged). On `status_err` it returns a single `SfError` line
   (`"Org status unavailable: " .. status_err`), never an empty section.
5. `lua/sf/ui/dashboard_views.lua`: replace the two entries `details`
   (`key = "d"`) and `status` (`key = "s"`) with one merged entry —
   **`id = "details"`, `key = "d"`, `label = "Details"`** (keeping the id
   and key means every existing default/cache/keymap path and the
   `session.active_view_id = "details"` initial value keep working
   untouched; `s` is freed).
   - `fetch`: fires both lookups **in parallel** — `org_view.fetch_org_display(record, ...)`
     and `rest_api.get_session(record.alias, ...)` → `org_status.fetch(session, ...)`
     — with a small pending counter, and calls back exactly once with
     `{ detail = ..., detail_err = ..., status = ..., status_err = ... }`
     and **always `err = nil`**. Passing `err = nil` is deliberate:
     `paint_view`'s error branch blanks the whole pane, and partial
     failure must not do that.
   - `render`: `org_view.render_detail_lines(record, nil, data.detail, data.detail_err)`
     for the top section, then a blank line, then
     `render_status_section(data.status, data.status_err)`, concatenated
     with `vim.list_extend` on both the `lines` and the `line_hls`
     parallel arrays. **Guard**: `render_detail_lines` indexes
     `SPINNER_FRAMES[frame % ...]` when both `detail` and `err` are nil,
     so `fetch` must always supply a non-nil `detail_err` string whenever
     `detail` is nil (e.g. `"no data returned"`).
   Test: new cases in `tests/test_dashboard_views.lua` against the merged
   entry's `render` with four stubbed `data` shapes — both ok, details ok
   + status err, details err + status ok, both err — asserting the output
   is never empty and always contains the surviving section's content.
   A second case drives `fetch` with stubbed
   `org_view.fetch_org_display` / `rest_api.get_session` / `org_status.fetch`
   and asserts the callback fires exactly once with both halves populated.
6. `tests/test_org_status.lua` is untouched (`org_status.parse_instance_status`
   and `org_status.fetch` keep their contracts). Grep for any other
   reference to the `status` view id / `s` key and remove it — there is
   none in `lua/` today beyond `dashboard_views.lua`.

### Phase 3 — Tab strip for the view pane

7. `lua/sf/ui/dashboard_views.lua`: add two tiny selectors so the "is this
   a tab or an action" rule has exactly one definition —
   `views.tab_views()` (entries with a non-nil `render`) and
   `views.action_views()` (entries with a non-nil `action` and no
   `fetch`/`render`). Replace the inline `view_desc.action and not
   view_desc.fetch and not view_desc.render` test in
   `org_dashboard.lua`'s keymap loop with `views.action_views()`
   membership so the predicate is not written twice.
8. `lua/sf/ui/dashboard_views.lua`: add pure
   `views.render_tab_strip(active_view_id, width)` → `lines, line_hls`.
   Each tab renders as `key .. " " .. label` joined by `" │ "`, greedily
   wrapped onto additional lines when the joined text exceeds `width`.
   Active tab gets `SfTitle`, inactive `SfFooter`. Every character of
   every tab comes from `view_desc.key` / `view_desc.label` — no literal
   view names anywhere in this function.
   Test: new cases in `tests/test_dashboard_views.lua` — strip contains
   every `views.tab_views()` label and no action-only label; the active
   id's segment carries `SfTitle` and no other segment does; a narrow
   `width` produces more than one line and no line exceeds `width`; an
   unknown `active_view_id` produces a strip with no `SfTitle` segment
   rather than erroring.
9. `lua/sf/ui/org_dashboard.lua` — `paint_view` only: build the strip via
   `views.render_tab_strip(session.active_view_id, view_window_width)`
   plus one blank separator line, prepend it to whatever the existing
   loading/error/data branch produced (`vim.list_extend` on both arrays),
   and record `session.view_header_lines = #strip_lines + 1`. The async
   fetch/spinner/cache/generation machinery in `paint_view`/`show_view` is
   otherwise **not touched**.
10. `lua/sf/ui/org_dashboard.lua` — logs `<CR>` handler: subtract
    `session.view_header_lines` from the cursor row before indexing
    `session.filtered_logs`, and bail when the result is `< 1` (cursor
    parked on the tab strip).
    Test: extend `tests/test_org_dashboard.lua` — with a stubbed logs
    fetch, place the view-window cursor on the first *log* line and assert
    the correct log id is downloaded; place it on the tab strip and assert
    nothing is downloaded.
11. `lua/sf/ui/org_dashboard.lua` — `footer_for()`: drop the tab views,
    list only `views.action_views()` keys/labels plus `q close` (and the
    logs-specific `f filter` / `r refresh` keys, which are dashboard-level
    keymaps, not registry entries — keep those literal, they have no
    descriptor to read from). `get_view_title()` drops the active view's
    label (the strip now shows it) and becomes the org alias — or delete
    `get_view_title` and inline the alias, whichever reads cleaner once
    `update_view_title` is adjusted. Keep `update_view_title`'s
    `nvim_win_set_config` call; it still refreshes the footer.
    Test: update the existing
    `tests/test_org_dashboard.lua` "footer contains registered view keys"
    case — it currently asserts the footer contains `d`; after this phase
    the footer must contain every `views.action_views()` key and `q`, and
    must **not** contain the tab labels. Add a companion assertion that
    the view buffer's first line contains every tab label.

### Phase 4 — Self-describing names audit (checklist, likely mostly already true)

12. Grep `lua/sf/ui/org_dashboard.lua` for any literal view name or key
    and confirm each of the three name-producing sites derives its text
    solely from a descriptor: `get_view_title` (Phase 3 removes its
    dependence entirely), `footer_for` (now reads `views.action_views()`),
    and `render_tab_strip` (reads `views.tab_views()`). The only
    remaining literals allowed are the dashboard-level keys that have no
    descriptor: `q`, `<Esc>`, `r`, `f`, `<CR>`. The `"details"` string in
    `session.active_view_id = "details"` is an *id*, not a display name —
    leave it, but replace it with `views.tab_views()[1].id` if that reads
    better, so the default tab is also registry-driven.
13. AGENTS.md pass on the two files fully touched by this work
    (`lua/sf/ui/org_dashboard.lua`, `lua/sf/ui/dashboard_views.lua`):
    both are already free of `U`/`M`/`H`-style identifiers — confirm, do
    not go looking in unrelated files. `tests/test_org.lua` still uses
    `M`/`H`/`T`; adding one test case does not count as fully touching it,
    so leave those alone and use descriptive locals in the new case only.
14. `make test` green; run `stylua` per `.stylua.toml`.

---

## Batching for workers

**Three workers, two of them sequential on the same files.**

| Wave | Worker | Phases | Files it writes |
|---|---|---|---|
| 1 (parallel) | Worker A | Phase 1 | `lua/sf/org.lua`, `tests/test_org.lua`, plus two small edits in `lua/sf/ui/org_dashboard.lua` (stale comment, singleton guard at the top of `dashboard.open` + `close`) |
| 1 (parallel) | Worker B | Phase 2 | `lua/sf/ui/dashboard_views.lua`, `tests/test_dashboard_views.lua` |
| 2 (after both) | Worker C | Phases 3 + 4 | `lua/sf/ui/dashboard_views.lua`, `lua/sf/ui/org_dashboard.lua`, `tests/test_org_dashboard.lua`, `tests/test_dashboard_views.lua` |

Rationale:

- **Phase 1 and Phase 2 are genuinely independent**: Phase 1's org-list
  dedupe lives in `lua/sf/org.lua` and Phase 2's merge lives in the
  `views` array in `dashboard_views.lua`. Their only shared file is
  `org_dashboard.lua`, and Phase 1 touches only the `r`-keymap comment
  and the top of `dashboard.open`/`close`, while Phase 2 touches
  `org_dashboard.lua` not at all. Safe to run in parallel **only if** they
  are in separate worktrees or the orchestrator serialises the commit; if
  in doubt, run A then B — the whole of Phase 1 + Phase 2 is small.
- **Phase 3 must run after Phase 2.** Both rewrite `dashboard_views.lua`,
  and Phase 3's `views.tab_views()` and `render_tab_strip` output depend
  on the merged Details entry existing (otherwise the strip ships a
  `Details` and an `Org Status` tab and then Phase 2 has to redo the
  tests). Phase 3 also rewrites `paint_view`, `footer_for`,
  `get_view_title` and the `<CR>` handler in `org_dashboard.lua`, which
  collides with Phase 1's singleton guard in the same file.
- **Phase 4 must stay with Phase 3** (same worker, same commit) — it is
  the audit of the very sites Phase 3 rewrites; splitting it into its own
  worker would just mean a second pass over the same two files.

Do not fan Phase 3 out across two workers by file; `render_tab_strip` and
`paint_view` are one change, and splitting them guarantees a merge
conflict in `dashboard_views.lua`.

---

# Round 2 — clickable tabs, keyboard navigation, tabulated views, richer logs

Follow-up round on the same dashboard, driven by user feedback after
Phases 1-4 shipped. Continues the numbering above (Phase 5 starts at
Step 15).

## Findings before Step 15 (read this; do not re-derive)

### Already fixed outside this plan — do not re-propose

`lua/sf/sub/org_status.lua`'s `parse_instance_status` crashed
`render_status_section` with *"attempt to concatenate a table value"*
(`dashboard_views.lua:196`) because it copied `incident.id` /
`incident.message` through unchecked and a real org returned them as
nested tables. Fixed by coercing each to `nil` unless it is a `string`,
with a regression case in `tests/test_org_status.lua`. Nothing further
is needed here.

### Tabs affordance — REVISED: use `'winbar'`, not buffer lines

Phase 3's *"Tabs — chosen affordance"* finding is **superseded**. It
concluded "no existing tabline/statuscolumn helper to reuse" — it went
looking for a *helper module* and never evaluated `'winbar'`, the native
per-window option. Probed in this repo's own headless harness on
nvim 0.11.2:

- **winbar works on floating windows**, including `style = "minimal"`.
  `getwininfo(win)[1].winbar` flips `0 -> 1` and the text height drops
  `10 -> 9`. It was never actually ruled out.
- **winbar has native clickable regions**:
  `%1@v:lua.Handler@ d Details %X`. Neovim routes the click to the
  handler itself — no `getmousepos`, no click-region table, and no
  second copy of the layout math to keep in sync with the painter.
- **It is headlessly assertable**:
  `nvim_eval_statusline(bar, { winid = ..., use_winbar = true, highlights = true })`
  returns rendered text plus resolved highlight groups (verified:
  `SfTitle` at col 0, `SfFooter` at col 11).
- Both handler spellings render: `v:lua.GlobalFunction` and
  `v:lua.require'sf.ui.org_dashboard'.handle_tab_click`. Use the
  `require` form — no new global.

Why this beats the buffer-line strip, beyond elegance:

- The buffer-strip design has a **concrete focus bug**. A buffer-local
  `<LeftMouse>` map on `session.view_buffer` does **not** fire for the
  first click arriving from the list pane: mappings resolve against the
  *current* buffer at keypress time, and focus is still on
  `list_buffer` — the click only moves focus as a side effect of the
  default binding. That design needs `<LeftMouse>` on *both* buffers,
  plus a `getmousepos` dispatch, plus re-emulating default click
  behaviour (focus window + move cursor) in the non-tab case. winbar
  sidesteps all of it.
- **winbar deletes code rather than adding it**: the strip stops being
  buffer content, so `session.view_header_lines` and the logs `<CR>`
  offset subtraction (Steps 9-10) both go away.
- **Sticky by construction**: `<C-d>`/`<C-u>` can never scroll the tabs
  out of view, so Phase 6 needs no sticky-header handling at all.

Accepted cost: winbar is one line and truncates instead of wrapping.
Default truncation keeps the *right* side (`<ls  l Logs `), which is
wrong for tabs; a trailing `%<` makes it left-anchored
(` d Details  t Trace Fla>`) — verified. Combined with shortening two
labels (below), truncation only bites on genuinely narrow terminals.

### Logs `Operation` — evidence from a real org

Ran the real `sf apex list log --json -o tn-dev` (126 records). Field
set on each `ApexLog`: `Application`, `DurationMilliseconds`, `Id`,
`Location`, `LogLength`, `LogUser`, `Operation`, `Request`, `StartTime`,
`Status`, `attributes`.

- `Operation` is the "where did this come from" field the user means —
  observed values `/webruntime/api/apex/execute`, `UniversalPerfLogger`
  (their examples: `/aura`, `AsyncQueued execution of...`, `System`).
  **Add it.**
- `Application` is **not** worth a column: only two distinct values
  across all 126 rows, `Browser` and `Unknown`. It stays available on
  `record.raw` for anyone who wants it later.
- `DurationMilliseconds` is the genuinely informative extra (one row
  showed 18697 ms) but was not requested — **out of scope**; once
  Step 26's column helper is in, it is a one-line column entry if ever
  asked for.

### Verified mechanics for Phase 6

`nvim_win_call(view_window, function() vim.cmd("normal! \4") end)`
scrolls the view window a half page, leaves `nvim_get_current_win()` on
the list window and the list cursor untouched, and clamps correctly at
the bottom (`topline` stops at 191 for a 200-line buffer in a 10-line
window). `\4` = `<C-d>`, `\21` = `<C-u>`.

### Test-harness limitation (read before writing Phase 5 tests)

The mini.test child Neovim reports `#vim.api.nvim_list_uis() == 0`, so
`nvim_input_mouse` events are dropped and a **real winbar click cannot
be simulated in this suite** — verified, do not burn time trying. Test
the seam we own instead: call the click handler directly with the same
arguments Neovim would pass. Neovim's own click routing is not ours to
test.

---

## Phases

### Phase 5 — Winbar tab strip, clickable (replaces Phase 3's buffer strip)

15. `lua/sf/ui/dashboard_views.lua`: shorten two labels in the registry
    so the one-line winbar fits — `"Org Limits"` -> `"Limits"`,
    `"Installed Packages"` -> `"Packages"`. This matches the user's own
    naming (`Details | Logs | Packages`), it is not merely a truncation
    workaround. `id` and `key` are unchanged, so no cache key, keymap or
    test that keys off those is affected.
16. `lua/sf/ui/dashboard_views.lua`: replace
    `views.render_tab_strip(active_view_id, width)` with pure
    `views.render_winbar(active_view_id)` -> `string`. Delete
    `render_tab_strip` and its tests; nothing else calls it.
    - One segment per `views.tab_views()` entry, in that order, built
      only from `view_desc.key` / `view_desc.label` — no literal view
      name anywhere in this function (the Step 12 rule still holds).
    - Segment form:
      `"%" .. tab_index .. "@v:lua.require'sf.ui.org_dashboard'.handle_tab_click@" .. highlight .. " " .. key .. " " .. label .. " %X"`,
      where `highlight` is `"%#SfTitle#"` for the active id and
      `"%#SfFooter#"` otherwise. `tab_index` is the 1-based index into
      `views.tab_views()` and arrives back as the handler's `minwid`.
    - Separator `"│"` between segments, and a trailing `"%<"` so
      overflow truncates from the right (left-anchored), not the left.
    - An unknown `active_view_id` yields a bar with no `%#SfTitle#`
      segment rather than erroring.
    Test (`tests/test_dashboard_views.lua`): the string contains every
    `views.tab_views()` label and no action-only label; the `%N@`
    indices are `1..#tab_views()` in registry order; the active id's
    segment is preceded by `%#SfTitle#` and no other segment is; the
    string ends with `%<`; an unknown active id produces no `%#SfTitle#`.
17. `lua/sf/ui/org_dashboard.lua`: add module-level
    `function dashboard.handle_tab_click(minwid, clicks, button, modifiers)`
    (signature fixed by Neovim; unused parameters named, not `_`, per
    AGENTS.md — or `_` only where genuinely ignored). It reads the
    module-local `active_session` that the Step 3 singleton guard
    already maintains, so it needs no closure:
    - bail when `active_session` is nil or its windows are invalid;
    - `local tabs = dashboard_views.tab_views()`; bail when `minwid` is
      outside `1..#tabs`;
    - set `active_session.active_view_id = tabs[minwid].id`, reset
      `filter_query`, refresh the bar, `show_view(current_record(), id)`;
    - finally `nvim_set_current_win(active_session.list_window)` (guarded)
      so focus snaps back to the list pane — the single control surface,
      consistent with Phase 6. Doing this explicitly also makes the
      outcome deterministic regardless of whether Neovim moves focus on
      a winbar click.
    This requires `show_view` / `current_record` to be reachable from the
    module scope; the smallest change is to hang them off the `session`
    table (e.g. `session.show_view = show_view`) at the end of
    `dashboard.open`, rather than lifting the whole controller out of the
    closure. Do not restructure `dashboard.open`.
18. `lua/sf/ui/org_dashboard.lua`: introduce
    `local update_tab_strip = function() ... end` that sets
    `vim.wo[session.view_window].winbar = dashboard_views.render_winbar(session.active_view_id)`
    behind the usual `nvim_win_is_valid` guard. Call it once after the
    view window is created and from every site that mutates
    `active_view_id` (the registry keymap loop, `handle_tab_click`, and
    Phase 6's cycling). Add `WinBar:SfNormal,WinBarNC:SfNormal` to the
    view window's existing `winhl` string so the bar's background matches
    the float instead of inheriting the default `WinBar` group. Note the
    bar costs one row of view text height — acceptable, no geometry
    change.
19. `lua/sf/ui/org_dashboard.lua`: **revert Phase 3's Steps 9-10.**
    `paint_view` goes back to painting only the view's own content (no
    strip prepend, no `vim.list_extend` header), `session.view_header_lines`
    is deleted from the session table, and the logs `<CR>` handler goes
    back to indexing `session.filtered_logs[view_row]` directly. Update
    the Step 10 test accordingly: the first log now sits on view line 1,
    and the "cursor parked on the tab strip downloads nothing" case is
    deleted — that state no longer exists.
    Test (`tests/test_org_dashboard.lua`): after `dashboard.open`, assert
    `vim.wo[view_window].winbar` is non-empty and that
    `nvim_eval_statusline(winbar, { winid = view_window, use_winbar = true, highlights = true })`
    renders text containing every tab label, with an `SfTitle` highlight
    at the active tab's start column. Then call
    `dashboard.handle_tab_click(2, 1, "l", "")` directly and assert
    `active_view_id` is now `tab_views()[2].id`, the winbar's `SfTitle`
    segment moved, and `nvim_get_current_win()` is the list window. Add
    one assertion that the view buffer's first line is view content, not
    a tab label (the anti-regression for Step 19's revert).

### Phase 6 — Keyboard navigation from the list pane

20. `lua/sf/ui/org_dashboard.lua`: buffer-local maps on
    `session.list_buffer` for `<Right>` / `l` (next tab) and `<Left>` /
    `h` (previous tab), both wrapping. One shared local
    `local cycle_tab = function(step) ... end` reading
    `dashboard_views.tab_views()` and locating the current index by `id`
    — no second tab order, no hardcoded list. On an `active_view_id` that
    is not a tab (cannot happen today, but cheap), fall back to index 1.
    Each cycle sets `active_view_id`, resets `filter_query`, calls
    `update_tab_strip()`, then `show_view(record, id)` — i.e. exactly the
    same body as the registry keymap's view-switch branch; factor that
    body into one local so the two paths cannot drift.
    Overriding `h`/`l` costs horizontal cursor motion in the list buffer,
    which is meaningless there (one selectable item per line) — this is
    the explicitly requested trade.
21. `lua/sf/ui/org_dashboard.lua`: buffer-local `<C-d>` / `<C-u>` on
    `session.list_buffer` that scroll the *view* window a half page via
    `vim.api.nvim_win_call(session.view_window, function() vim.cmd("normal! \4") end)`
    (`\21` for `<C-u>`), wrapped in the same
    `nvim_win_is_valid(session.view_window)` guard used elsewhere in the
    file. Verified above: focus and the list cursor stay put and the
    scroll clamps at the buffer ends. Do **not** map these on
    `session.view_buffer` — when focus is in the view pane the default
    `<C-d>`/`<C-u>` already do the right thing.
22. **No change needed — checklist item, do not re-implement.** `j`/`k`
    and `<Up>`/`<Down>` already switch the highlighted org: they are
    plain cursor motion in `session.list_buffer`, and the existing
    `SfOrgDashboardCursor` `CursorMoved` autocmd already re-renders the
    view pane for the new record. Confirm by reading the autocmd
    registration; add no keymaps for them.
23. **No sticky-header work.** Obsolete by construction — Phase 5 moved
    the tabs into `'winbar'`, which is not buffer content and cannot
    scroll. Recorded here only so nobody re-opens the question.
    Test (`tests/test_org_dashboard.lua`), one case per claim: `<Right>`
    from the first tab selects `tab_views()[2].id`; `<Left>` from the
    first wraps to the last; `l` and `h` behave identically to `<Right>`
    and `<Left>`; with a stubbed view whose render returns more lines
    than the pane is tall, `<C-d>` increases
    `getwininfo(view_window)[1].topline` while
    `nvim_get_current_win()` stays the list window and the list cursor is
    unchanged, and `<C-u>` returns `topline` to 1; `j` moves the list
    cursor and changes the rendered record (guards Step 22's claim).

### Phase 7 — Column-aligned limits and packages

24. `lua/sf/ui/org_view.lua`: add one small shared helper next to the
    existing `org_view.pad` (which it uses) —
    `org_view.render_columns(rows)` -> `lines, line_hls`, where `rows` is
    an array of `{ cells = { "text", ... }, highlight = "SfWarn"|nil }`.
    It computes each column's width as the max `#cell` in that column,
    joins with a two-space gap (matching `render_list_lines`), and emits
    a whole-line highlight segment when `row.highlight` is set. Three
    call sites (limits, packages, logs) justify this per the ladder;
    keep it at that. **Explicitly not in scope**: cell wrapping, sorting,
    per-column alignment options, header styling — callers sort, format
    and truncate their own cell text and pass a header as just another
    row. Carry a `ponytail:` note that width is byte length (`#cell`),
    the same ASCII assumption `org_view.pad` already makes; upgrade path
    is `vim.fn.strdisplaywidth` if a non-ASCII alias ever misaligns.
    Test (`tests/test_org_view.lua`): ragged input aligns to the widest
    cell per column; a one-row input is unchanged apart from trailing
    padding; `highlight` produces one whole-line segment and `nil`
    produces none; empty input returns two empty tables.
25. `lua/sf/ui/dashboard_views.lua`: rewrite the `limits` view's `render`
    to build rows from the existing `format_limits(data)` output and emit
    them through `org_view.render_columns` — columns
    `Limit | Used | Max | %`, preceded by a header row highlighted
    `SfTitle`. Keep the existing `>= 80%` rule, now expressed as the
    row's `highlight = "SfWarn"`. `format_limits` itself is **not**
    touched (it is already pure and tested).
26. `lua/sf/ui/dashboard_views.lua`: same treatment for `packages` —
    rows from `flatten_package_row`, columns `Package | Namespace |
    Version`, header row, no per-row highlight. `flatten_package_row` is
    untouched.
    Test (`tests/test_dashboard_views.lua`): for both views, assert the
    value column starts at the same byte offset on every data line (the
    actual alignment claim, not just "contains the text"); assert the
    header line is present and carries `SfTitle`; assert a `>= 80%`
    limits row still carries `SfWarn` and a low-usage row does not;
    assert the existing empty-data messages ("No limits data found.",
    "No packages installed.") are unchanged.

### Phase 8 — Logs view: show where the log came from

27. `lua/sf/org.lua`: in `helpers.parse_log_list`, add
    `operation = log_entry["Operation"] or ""` to the flat record it
    returns. `raw` already carries every original field (its comment says
    so) and `pick_org_log`'s fzf preview reads `raw`, so that path is
    unaffected. Do **not** add `application` — see the findings above.
    Test (`tests/test_org.lua`): extend the existing `parse_log_list`
    fixture with `"Operation": "/aura"` on one record and
    `"Operation": "AsyncQueued execution of MyJob"` on another, assert
    both land on `logs[n].operation`, and assert a record with no
    `Operation` key yields `""` rather than `nil`. Use descriptive locals
    in the new case only — `tests/test_org.lua` still uses `M`/`H`/`T`
    and adding a case does not count as fully touching it (Step 13).
28. `lua/sf/ui/dashboard_views.lua`: widen `format_log_line(log)` to
    include `log.operation`, and add a file-local
    `truncate(text, max_width)` used only for the operation cell (long
    Visualforce/`AsyncQueued` operations otherwise blow past the pane).
    Use an ASCII `"..."` ellipsis, not `"…"`, so the truncated width
    stays consistent with `render_columns`' byte-width math.
29. `lua/sf/ui/dashboard_views.lua`: rewrite the `logs` view's `render`
    to emit through `org_view.render_columns` — columns
    `User | Started | Operation | Size | Status`, with a header row. The
    row order must stay exactly the order of the (possibly filtered)
    `data` array, because `org_dashboard.lua`'s `<CR>` handler maps the
    view cursor row to `session.filtered_logs[row]` — with the Step 19
    revert there is no header offset, but a header *row* reintroduces a
    one-line offset, so either skip the header for this view or account
    for it in the `<CR>` handler. **Prefer skipping the header here**:
    one fewer moving part, and the log columns are self-evident. Record
    the choice in a comment so the next reader does not "helpfully" add
    it back.
30. **Confirm, do not re-plumb**: `filter_logs` substring-matches against
    `format_log_line(log)`'s output, so widening that line is sufficient
    for `f`-filtering to search `Operation` for free. No change to
    `filter_logs` itself.
    Test (`tests/test_dashboard_views.lua`): `format_log_line` output
    contains the operation; a long operation is truncated to the cap and
    ends with `"..."`; `filter_logs(logs, "aura")` returns only the
    record whose `operation` is `/aura` (this is the proof for Step 30);
    the logs render's first line is a data row, not a header (guards the
    `<CR>` index contract).

### Phase 9 — Green

31. `make test` green, `stylua` per `.stylua.toml`. Re-check the Step 12
    audit still holds: after Phase 5 the name-producing sites are
    `render_winbar` (reads `tab_views()`) and `footer_for` (reads
    `action_views()`); the only literal keys left are the
    descriptor-less dashboard keys `q`, `<Esc>`, `r`, `f`, `<CR>`, and
    now `<Left>`/`<Right>`/`h`/`l`/`<C-d>`/`<C-u>`.

---

## Batching for workers (round 2)

**Two workers, strictly sequential.** Both write
`lua/sf/ui/dashboard_views.lua`, so they cannot run in parallel in one
worktree.

| Wave | Worker | Phases | Files it writes |
|---|---|---|---|
| 1 | Worker D | Phases 5 + 6 | `lua/sf/ui/dashboard_views.lua`, `lua/sf/ui/org_dashboard.lua`, `tests/test_dashboard_views.lua`, `tests/test_org_dashboard.lua` |
| 2 (after D) | Worker E | Phases 7 + 8 + 9 | `lua/sf/ui/org_view.lua`, `lua/sf/ui/dashboard_views.lua`, `lua/sf/org.lua`, `tests/test_org_view.lua`, `tests/test_dashboard_views.lua`, `tests/test_org.lua` |

Rationale:

- **Phases 5 and 6 are one change, not two.** Phase 6's tab cycling
  calls Phase 5's `update_tab_strip` and reuses the same view-switch
  body; splitting them means Worker E rewrites the keymap block Worker D
  just wrote. Both are confined to the same two source files.
- **Phase 7 must follow Phase 5**, not because of the helper but because
  Phase 5 renames two registry labels and deletes `render_tab_strip`
  from `dashboard_views.lua`, while Phase 7 rewrites three `render`
  bodies in the same array — a guaranteed conflict if concurrent.
- **Phase 8 stays with Phase 7** (same worker, same commit): its logs
  render is the third consumer of Step 24's `render_columns`, and
  shipping it separately means touching `dashboard_views.lua` a third
  time. Its `lua/sf/org.lua` step is the only genuinely independent piece
  in this round, and at three lines it does not justify its own worker.
- **Do not split Phase 5 by file.** `render_winbar`, `handle_tab_click`
  and the Step 19 revert are one behavioural change spanning both files;
  splitting them ships a dashboard whose tabs are painted twice or not
  at all.

---

# Round 3 — perf (prefetch), arrow-key nav, theme/dimming, richer incidents

Follow-up round driven by user feedback after Rounds 1-2 shipped.
Continues the numbering above (Phase 10 starts at Step 32).

## Findings before Step 32 (read this; do not re-derive)

### Already fixed outside this plan — do not re-propose

`vim.json.decode` turns JSON `null` into `vim.NIL`, a **truthy** userdata
sentinel, not Lua `nil` — so every `field or default` fallback silently
kept `vim.NIL` (an unmanaged package's null `NamespacePrefix` crashed
`org_view.render_columns` with *"attempt to get length of a userdata
value"*). Fixed at every decode boundary feeding the dashboard
(`rest_api.lua`'s `cli_json_call` + `curl_json`, `org_view.lua`'s
`fetch_org_display`, `org.lua`'s `parse_log_list` + `store_orgs`) with
`{ luanil = { object = true } }`, plus defence-in-depth in
`render_columns` (`safe_cell_text`) and `flatten_package_row`
(type-checked accessors). Verified against the live `tn-dev` org (50 real
packages, most with null `NamespacePrefix`). Tests added in
`tests/test_rest_api.lua`, `tests/test_org_view.lua`,
`tests/test_dashboard_views.lua`. **208/208 green.** Nothing further here.

### ROOT CAUSE of the 5-10s open: five identical `sf org display` spawns

Measured in this environment: `sf org display --json -o tn-dev` takes
**6.8s** wall clock. That single number explains the user's complaint —
but the bigger finding is *how many times we pay it*.

`rest_api.get_session` (line 62) and `org_view.fetch_org_display`
(line 313) build the **byte-identical** command
`sf org display --json -o <alias>`, and **neither caches anything**
(`grep -c cache lua/sf/sub/rest_api.lua` → 0). Grepping the fetch call
sites in `dashboard_views.lua`:

| Tab view | Calls | `sf org display` spawns |
|---|---|---|
| `details` | `fetch_org_display` **and** `get_session` | **2** |
| `trace_flags` | `get_session` | 1 |
| `limits` | `get_session` | 1 |
| `packages` | `get_session` | 1 |
| `logs` | `Org.list_org_logs` (`sf apex list log`) | 0 (different cmd) |

So **the `details` tab alone spawns two concurrent identical 6.8s CLI
calls**, and prefetching all five tab views for one org would spawn
**five identical `sf org display` calls plus one `sf apex list log`** —
six Node processes for one org. Eagerly prefetching the default org *and*
the devhub *and* the cursor-landed record would put 12-18 concurrent Node
processes on the machine.

**Therefore: deduplicating `sf org display` is a hard prerequisite for
prefetching, not an optional nicety.** Prefetch built on today's code
would make the dashboard slower and hammer the machine. Phase 10 must
land before Phase 11. This is also exactly what AGENTS.md's "prefer the
API, `sf` CLI spawns a Node process per invocation" rationale is about.

In-flight **coalescing matters more than a TTL cache** here: the prefetch
case is N simultaneous callers for the same alias, all of which miss an
empty cache and all of which would spawn. One spawn with N queued
callbacks is the actual fix.

### Nav keys have ZERO test coverage today

Phase 6 Step 23 planned tests for `<Right>`/`<Left>`/`<C-d>`/`<C-u>`/`j`
— **they were never written** (the Round-2 worker timed out mid-run).
`grep -c 'Left\|Right\|Up>\|Down>\|C-d\|C-u' tests/test_org_dashboard.lua`
→ **0**. The only `nvim_input("j")` uses are incidental cursor moves
inside action tests. Item 1 therefore changes *untested* behaviour;
Phase 12 must add coverage for the whole final key contract, not just the
two keys whose meaning changes.

### Prefetch must NOT reuse `show_view` — spinner/paint bugs

Read `show_view` and `paint_view` carefully before writing Phase 11:

- `session.spinner_timer` is a **single shared slot**. `show_view` calls
  `stop_spinner()` then installs a new timer. If a prefetch reused
  `show_view`, **the first prefetched view to complete would call
  `stop_spinner()` and freeze the visible spinner of the tab the user is
  actually looking at.**
- `paint_view(record, frame)` derives its cache key from
  `session.active_view_id`, **not** from the view that just finished. A
  prefetch completion calling `paint_view` would repaint the *active*
  tab — harmless-looking but it re-renders on every prefetch completion,
  and paints spinner frame 0 over a live animation.
- `paint_view` also does not check that `record` is still the record
  under the cursor, so a late completion for org A can paint into org B's
  pane.

Resolution (Phase 11): prefetched views get **no spinner at all** — the
user is not looking at them, so there is nothing to animate. Only the
active view animates. A prefetch completion paints **only if** its
`view_id == session.active_view_id`, its `record.alias` still matches
`current_record().alias`, and its captured generation still matches.

### `SfTitle` is doing two incompatible jobs

`SfTitle` is `{ fg = "#101418", bg = accent, bold = true }` — a solid
filled block, correct for a float title and for the winbar's active tab.
But `append_table_section` and the limits/packages renders **also** use
`SfTitle` for table header rows, and `render_columns` applies a row
highlight across the **whole line** (`col_start = 0, col_end = #line`).
Result: the Status view paints **four full-width solid blue bars**
(Products, Maintenances, Messages, Incidents headers), plus one each in
Limits and Packages. That is the single worst styling inconsistency in
the dashboard and is item 3's most visible win.

### Every incident renders as a warning, even long-resolved ones

`render_status_section`'s incident loop applies `SfWarn` to **every**
incident unconditionally. Real `tn-dev` data: **all 6 incidents are
`status = "Resolved"`**, the newest impact ended weeks ago, and the
instance `status` is `OK`. So a perfectly healthy org shows six yellow
warning lines. Items 3 and 4 fix this together.

### Incident payload — real field evidence (live `tn-dev`)

Per incident: `id` (**number**), `status`, `type`, `createdAt`,
`updatedAt`, `additionalInformation`, `message` (object of
`rootCause`/`actionPlan`/`pathToResolution`, usually all null), and
`IncidentImpacts[]` whose entries carry `startTime`, `endTime`,
`severity`, `type`.

`parse_instance_status` currently keeps only
`{id, status, type, severity, message}` — **`createdAt`/`updatedAt` and
all impact times are parsed nowhere.**

Observed on all 6 records:

- incident-level `type` is `"Degradation"` for **every** record — low
  information.
- impact-level `type` is more specific: `featurePerfDegradation` vs
  `featureServiceDisruption`.
- **impact `startTime`/`endTime` is the useful pair** (when customers
  were actually affected, e.g. `2026-08-19T07:38` → `2026-08-23T11:20`).
  `createdAt`/`updatedAt` describe the incident *record's* lifecycle and
  are consistently *later* than impact start — less useful to show.

Decision for Phase 14: show **impact start/end**, keep `createdAt` parsed
but unrendered (one extra field costs nothing and answers "when was this
reported"), and prefer impact-level `type` over incident-level `type`
since the latter is a constant.

### Semantic colours must stay semantic

`SfSuccess`/`SfWarn`/`SfError` link to
`DiagnosticOk`/`DiagnosticWarn`/`DiagnosticError` so they follow the
user's colorscheme. "Shift the whole theme to a more subtle blue" applies
to **chrome** (borders, titles, headers, dim text, spinner, icon), **not**
to status semantics — a red incident must not become blue. Phase 13 keeps
the diagnostic links untouched and only re-derives chrome.

---

## Phases

### Phase 10 — Deduplicate `sf org display` (prerequisite for Phase 11)

32. `lua/sf/sub/rest_api.lua`: add a module-local cache + in-flight
    coalescer for the raw `sf org display --json [-o alias]` result, and
    one public accessor `rest_api.get_org_display(alias, callback)`
    returning the decoded `result` table.
    - Cache key: the alias, or a fixed sentinel (e.g. `"<target>"`) when
      no alias is passed, so the existing `get_session(cb)` form shares
      correctly with `get_session(alias, cb)` for the same org.
    - **Coalesce in flight**: an entry is
      `{ result = ..., err = ..., fetched_at = ..., waiters = { cb, ... } }`.
      A call that finds a live in-flight entry appends its callback to
      `waiters` and returns *without spawning*; completion drains
      `waiters`. This is the part that actually fixes the prefetch
      thundering herd.
    - **TTL**: access tokens expire, so cache entries must not live
      forever. Use a short module-local TTL constant (e.g. 300s) checked
      against `vim.uv.now()`. Do **not** cache failures — an errored
      lookup must be retried on the next call.
    - `rest_api.invalidate_org_display(alias)` (alias optional → clear
      all) so the dashboard's `r` refresh can drop it.
33. `lua/sf/sub/rest_api.lua`: rewrite `get_session` as a thin projection
    over Step 32 — `get_org_display(alias, ...)` then map to
    `{ token, url, api_version, username }` with the existing
    `accessToken`-missing guard and error text unchanged. **Public
    behaviour and signature (both the `get_session(cb)` and
    `get_session(alias, cb)` forms) must not change**; the three existing
    cases in `tests/test_rest_api.lua` must pass untouched.
    Test: extend `tests/test_rest_api.lua` — (a) two `get_session` calls
    for the same alias issued back-to-back spawn `silent_system_call`
    **once** and both callbacks receive the session (coalescing); (b) a
    third call after `invalidate_org_display` spawns again; (c) an errored
    first call is not cached — the next call re-spawns.
34. `lua/sf/ui/org_view.lua`: `fetch_org_display` stops building its own
    `cmd_builder` command and calls `rest_api.get_org_display(record.alias, ...)`
    instead, keeping its existing `(detail, err)` callback contract and
    its "could not parse" error string. This is what collapses the
    `details` tab from two identical 6.8s spawns to one shared spawn.
    Keep the doc-comment's performance note but update it to say the call
    is now shared and cached.
    Test: `tests/test_org_view.lua` — stub `rest_api.get_org_display` and
    assert `fetch_org_display` forwards the alias and surfaces both the
    success and error paths; assert it no longer calls `vim.system`
    directly (the anti-regression for the dedupe).
35. `lua/sf/ui/org_dashboard.lua`: the `r` refresh keymap additionally
    calls `rest_api.invalidate_org_display()` before
    `Org.fetch_org_list`, so `r` is a true "refetch everything" and not
    "refetch the org list but keep stale sessions".
    Test: extend the existing `refresh key 'r'` case in
    `tests/test_org_dashboard.lua` with a spy asserting the invalidate
    call fires.

### Phase 11 — Prefetch every tab view per record

36. `lua/sf/ui/org_dashboard.lua`: extract the cache-write half of
    `show_view` into one local
    `local fetch_view_into_cache = function(record, view_id, on_painted)`
    that: returns immediately when the cache entry already has `data` or
    `fetching`; looks up the descriptor; captures
    `local current_gen = session.generation`; sets
    `session.cache[cache_key] = { fetching = true }`; calls
    `view_desc.fetch`; on completion bails on generation mismatch, writes
    `{ fetching = false, data = ..., err = ... }`, and invokes
    `on_painted` (if given). **No spinner logic in here.** `show_view`
    keeps its existing spinner behaviour and is rewritten to call this
    helper for the fetch, so there is exactly one cache-write path — do
    not create a second caching mechanism.
37. `lua/sf/ui/org_dashboard.lua`: add
    `local prefetch_record_views = function(record)` that iterates
    `dashboard_views.tab_views()` and calls `fetch_view_into_cache` for
    each, passing an `on_painted` that repaints **only when all three
    guards hold**: the completed `view_id == session.active_view_id`,
    `record.alias == (current_record() or {}).alias`, and the window is
    valid. Action-only entries are skipped by construction
    (`tab_views()` already excludes them). No spinner is installed for
    prefetched views — see the findings note.
38. `lua/sf/ui/org_dashboard.lua`: eager warm-up, called once right after
    the two windows exist and `update_tab_strip()` has run. Collect the
    records with `record.is_default` and `record.is_default_devhub`,
    de-duplicated by alias (one org is frequently both), and call
    `prefetch_record_views` on each. Skip entirely when `#records == 1`
    (the cursor-landed prefetch already covers it). The existing cache
    check makes a double-fire with Step 39 free of extra spawns, so no
    extra bookkeeping is needed.
39. `lua/sf/ui/org_dashboard.lua`: `on_cursor_move` becomes
    `show_view(record, session.active_view_id)` (unchanged — the active
    tab still gets its spinner) **followed by** `prefetch_record_views(record)`
    for the remaining tabs. Order matters: the active view must claim the
    spinner slot first.
    Test (`tests/test_org_dashboard.lua`), with fake tab views registered
    the way the existing `cache_probe` case does, each counting its own
    fetches: (a) after `dashboard.open`, every fake tab view's fetch has
    fired exactly once for the default org without any tab being
    selected; (b) switching to a prefetched tab paints immediately and
    does **not** fetch again (cache hit — extends the existing
    `cache hit prevents re-fetch` case to the prefetch path); (c) moving
    the cursor to a second org fires each fake view's fetch exactly once
    more for that alias; (d) a prefetch completing while a *different*
    tab is active does not repaint the active tab — assert via a render
    spy on the active view that its render count is unchanged (this is
    the guard from Step 37 and the anti-regression for the spinner bug);
    (e) `#records == 1` performs no eager prefetch beyond the
    cursor-landed one (fetch counts stay at one per view).
40. **Deliberate non-goal**, recorded so it is not re-litigated: no
    config flag to disable prefetching, no job queue, no worker pool.
    With Phase 10 in place a full-org prefetch is **one** `sf org
    display` plus one `sf apex list log` plus three cheap `curl` calls.
    Carry a `ponytail:` comment on `prefetch_record_views` naming the
    ceiling (fixed 5 tab views, all fired at once) and the upgrade path
    (a concurrency cap or an opt-out flag) if the registry ever grows
    large or a user on a metered link complains.

### Phase 12 — Arrow keys navigate the view pane

41. `lua/sf/ui/org_dashboard.lua`: factor the existing `<C-d>`/`<C-u>`
    bodies into one local
    `local scroll_view_pane = function(normal_keys)` that guards
    `nvim_win_is_valid(session.view_window)` and runs
    `vim.api.nvim_win_call(session.view_window, function() vim.cmd("normal! " .. normal_keys) end)`.
    Rebind `<C-d>` → `"\4"` and `<C-u>` → `"\21"` through it (behaviour
    unchanged, one implementation instead of two copies).
42. `lua/sf/ui/org_dashboard.lua`: bind `<Down>` → `scroll_view_pane("j")`
    and `<Up>` → `scroll_view_pane("k")` on `session.list_buffer` (plain
    `j`/`k` inside `nvim_win_call` — readable, and identical in effect to
    `"\14"`/`"\16"`; the helper takes whatever `normal!` keys it is
    given, which is why `<C-d>`/`<C-u>` pass `"\4"`/`"\21"`). Single-line
    cursor motion inside the view window is the smaller-step sibling of
    the existing half-page scroll, and because it moves that window's own
    cursor it composes correctly with the logs view's `<CR>` download
    (which reads `nvim_win_get_cursor(session.view_window)`).
    **Accepted tradeoff, explicitly:** `<Up>`/`<Down>` no longer change
    the selected org, so **org switching is `j`/`k` only**. This is what
    the user asked for; do **not** invent a third binding to preserve
    arrow-key org switching.
43. `lua/sf/ui/org_dashboard.lua`: leave `h`/`l` (cycle tabs), `j`/`k`
    (plain cursor motion in the list buffer → org switch via the existing
    `CursorMoved` autocmd), and `<Left>`/`<Right>` (cycle tabs) exactly
    as they are. `j`/`k` are deliberately **not** bound — they must stay
    native motion so the autocmd keeps firing.
    Test (`tests/test_org_dashboard.lua`), a fake tab view whose render
    returns more lines than the pane is tall, then one case per claim:
    (a) `<Down>` moves `nvim_win_get_cursor(view_window)[1]` down by one
    while `nvim_get_current_win()` stays the list window **and** the list
    cursor row is unchanged; (b) `<Up>` moves it back; (c) `<C-d>`
    increases `getwininfo(view_window)[1].topline` and `<C-u>` returns it
    toward 1; (d) `j` still changes the selected org (rendered content
    changes) — this is the regression guard for Step 43's "do not bind
    j/k" rule; (e) `<Right>`/`<Left>` still cycle tabs and wrap. This
    closes the Phase 6 Step 23 coverage gap in the same pass.

### Phase 13 — Derived blue theme, dimming, and consistent emphasis

44. `lua/sf/ui/highlights.lua`: add two small file-local pure helpers,
    `local function shade(hex, factor)` (factor `< 1` darkens toward
    black, `> 1` lightens toward white, per-channel, clamped 0-255,
    returns `#RRGGBB`) and `local function mix(hex_a, hex_b, weight)`.
    Derive every chrome group from the single existing `ui.accent`
    instead of hardcoding literals — including `SfTitle`'s current
    hardcoded `fg = "#101418"`, which becomes `shade(accent, 0.08)` so a
    user changing `accent` to a subtler blue keeps readable contrast
    automatically. Keep every group `default = true`.
    Test (`tests/test_highlights.lua`, new file following the existing
    `tests/test_*.lua` child-Neovim pattern): `shade`/`mix` are exported
    for test (e.g. `highlights._shade`) and asserted on known inputs
    (identity at factor 1, clamping at extremes, `#RRGGBB` shape); then
    `setup()` with a custom `vim.g.sf.ui.accent` and assert via
    `nvim_get_hl` that `SfBorder`/`SfTitle`/`SfTableHeader`/`SfDim` all
    moved with it (the actual "single variable" claim).
45. `lua/sf/ui/highlights.lua`: add `SfDim` (`fg = mix(accent, bg-ish, ...)`
    or simply a desaturated/darkened accent — visibly recessive but still
    legible, **not** `link = "Comment"`, so it stays inside the derived
    palette) and `SfTableHeader` (`{ fg = shade(accent, 1.25), bold = true,
    underline = true }` — bold + tinted + underlined, **no background
    fill**). `SfTitle` keeps its filled-pill look and is reserved for the
    float title and the winbar's active tab only.
46. `lua/sf/ui/highlights.lua`: resolve the prod/sandbox/scratch colour
    tradeoff **explicitly**. Today `SfStatusProd` is `accent`,
    `SfStatusSandbox` is hardcoded `"white"`, `SfStatusScratch` is
    hardcoded `"cyan"` — three unrelated named colours that do not belong
    to a "subtle blue" theme, but whose at-a-glance distinguishability in
    the org list is genuinely valuable and must not be lost.
    **Resolution: keep three clearly distinct steps, but derive all three
    from `accent` so they share one hue family** — e.g.
    `SfStatusProd = { fg = accent, bold = true }` (the most saturated —
    production is the one you must not misread),
    `SfStatusSandbox = { fg = shade(accent, 1.45) }` (a light tint),
    `SfStatusScratch = { fg = shade(accent, 0.72) }` (a darker shade).
    Distinguishable by lightness rather than by unrelated hue, and a
    single `accent` change still re-themes all three coherently. Do
    **not** collapse them to one colour.
    Test: in `tests/test_highlights.lua`, assert the three resolve to
    three *different* `fg` values (the at-a-glance guarantee, expressed as
    a test so a future "simplification" cannot silently flatten them).
47. `lua/sf/ui/org_view.lua`: extend `render_columns` rows with an
    **optional** `cell_highlights` field — a sparse
    `{ [column_index] = "SfDim", ... }` map applied per cell at that
    cell's computed byte range, alongside (not instead of) the existing
    whole-line `highlight`. Every existing caller is untouched by
    omitting the field. Justified by two real consumers in Step 48
    (the Status instance-info label column, and the logs view's
    lower-value columns) — this is the only mechanism that satisfies
    "bold the important, dim the unimportant" *within* a row, which a
    whole-line highlight cannot express. Reuse the existing
    `safe_cell_text` width math so the ranges line up with the padding.
    Test (`tests/test_org_view.lua`): a row with
    `cell_highlights = { [2] = "SfDim" }` produces a segment whose
    `col_start`/`col_end` exactly bracket column 2's padded range and
    leaves columns 1 and 3 unhighlighted; a row with both `highlight` and
    `cell_highlights` emits both; omitting the field changes nothing
    (byte-identical to today's output for the existing fixtures).
48. `lua/sf/ui/dashboard_views.lua`: apply the emphasis rules, case by
    case — this is item 3's "bold important / dim unimportant" made
    concrete, and every one of these call sites carries **no** highlight
    on data rows today:
    - `append_table_section`: header row group changes `SfTitle` →
      `SfTableHeader` (kills the four solid blue bars).
    - Limits/Packages renders: same header group change. Limits keeps its
      existing `>= 80%` → `SfWarn` row rule.
    - Status instance-info rows: `cell_highlights = { [1] = "SfDim" }` so
      the label column recedes and the value reads first.
    - Products: an inactive product row gets `highlight = "SfWarn"`;
      active rows get no row highlight, with the redundant `"Available"`
      cell dimmed via `cell_highlights`.
    - Maintenances: a row whose `planned_end` is already in the past gets
      `highlight = "SfDim"` (needs a small `is_past(iso_datetime)` local
      next to `format_status_date`, comparing against `os.time()` —
      parse with the same pattern `format_status_date` already uses).
    - Messages: `status == "Resolved"` → `highlight = "SfDim"`;
      `"Active"` → left at normal weight.
    Test (`tests/test_dashboard_views.lua`): header lines carry
    `SfTableHeader` and **not** `SfTitle`; an inactive product row carries
    `SfWarn`; a `Resolved` message row carries `SfDim` and an `Active` one
    does not; a maintenance with a past `planned_end` carries `SfDim` and
    a future one does not; the instance-info label column carries `SfDim`
    at column 1's range only.

### Phase 14 — Incidents: real dates, tabulated, correctly emphasised

49. `lua/sf/sub/org_status.lua`: extend the incident mapping in
    `parse_instance_status`. Add a file-local
    `local function first_impact(incident)` returning
    `IncidentImpacts[1]` when it is a table, and widen each incident to
    `{ id, status, type, severity, message, impact_start, impact_end, created_at }`:
    - `impact_start` / `impact_end` from the first impact's
      `startTime` / `endTime` via the existing `as_string`.
    - `type` prefers the **impact-level** `type`
      (`featurePerfDegradation`) over the incident-level one, because the
      latter is `"Degradation"` on every real record (see findings);
      fall back to incident `type`.
    - `created_at` from `incident.createdAt` — parsed and carried but not
      rendered in Step 50, so "when was this reported" is one field away
      without another API round trip.
    - Reuse the existing `incident_severity` helper (already reads the
      first impact) by having it call `first_impact` so there is one
      definition of "the first impact".
    Update the `@return` doc block to the widened incident shape.
    Test (`tests/test_org_status.lua`), driven by the real shape already
    captured in that file's fixtures: `impact_start`/`impact_end`/
    `created_at` land from a realistic record; `type` resolves to the
    impact-level value when present and falls back to the incident-level
    one when `IncidentImpacts` is empty; an incident with **no** impacts
    yields `nil` for both times and does not error (the existing
    "unrecognized id shape" and "no impacts" cases must keep passing).
50. `lua/sf/ui/dashboard_views.lua`: replace the bullet-list incident
    loop in `render_status_section` with an `append_table_section` call
    matching Maintenances/Messages — columns
    `Incident | Status | Type | Severity | Start | End`, where `Incident`
    is `truncate(incident.message or incident.type or incident.id or "(no details)", 40)`
    (keeping today's fallback chain), and `Start`/`End` go through the
    existing `format_status_date`. The `"No incidents reported."` empty
    message is preserved as the section's `empty_message`.
    **Row emphasis, consistent with Step 48 and fixing the "everything is
    a warning" bug from the findings:** `status == "Resolved"` →
    `highlight = "SfDim"`; an unresolved incident → `SfWarn`, or
    `SfError` when `severity` is not `"minor"`. A healthy org whose six
    incidents are all resolved must render six *dim* rows, not six yellow
    ones.
    Test (`tests/test_dashboard_views.lua`): the incidents section is a
    table with the six expected headers, not a `"  - "` bullet list;
    impact dates appear in compacted `YYYY-MM-DD HH:MM` form; a
    `Resolved` incident row carries `SfDim`; an unresolved `minor` one
    carries `SfWarn`; an unresolved non-minor one carries `SfError`; the
    empty case still prints `"No incidents reported."`.

### Phase 15 — Green

51. `make test` green, `stylua` per `.stylua.toml`. Re-run the Step 12
    name-derivation audit: after Phase 12 the descriptor-less literal
    dashboard keys are `q`, `<Esc>`, `r`, `f`, `<CR>`, `h`, `l`,
    `<Left>`, `<Right>`, `<Up>`, `<Down>`, `<C-d>`, `<C-u>`. Confirm no
    new short identifiers were introduced (AGENTS.md), that
    `dashboard_views.lua` is still a plain array with no new abstraction,
    and that `SfTitle` is no longer referenced by any table-header call
    site.

---

## Batching for workers (round 3)

**Three workers, strictly sequential.** Phase 10 gates Phase 11 on
behaviour, and Phases 10/13/14 all write `lua/sf/ui/org_view.lua` or
`lua/sf/ui/dashboard_views.lua`, so no two waves can run concurrently in
one worktree.

| Wave | Worker | Phases | Files it writes |
|---|---|---|---|
| 1 | Worker F | Phase 10 | `lua/sf/sub/rest_api.lua`, `lua/sf/ui/org_view.lua`, `lua/sf/ui/org_dashboard.lua` (one line in the `r` keymap), `tests/test_rest_api.lua`, `tests/test_org_view.lua`, `tests/test_org_dashboard.lua` |
| 2 (after F) | Worker G | Phases 11 + 12 | `lua/sf/ui/org_dashboard.lua`, `tests/test_org_dashboard.lua` |
| 3 (after G) | Worker H | Phases 13 + 14 + 15 | `lua/sf/ui/highlights.lua`, `lua/sf/ui/org_view.lua`, `lua/sf/ui/dashboard_views.lua`, `lua/sf/sub/org_status.lua`, `tests/test_highlights.lua` (new), `tests/test_org_view.lua`, `tests/test_dashboard_views.lua`, `tests/test_org_status.lua` |

Rationale:

- **Phase 10 must be its own first wave.** It is the prerequisite that
  makes prefetching safe (5 identical `sf org display` spawns → 1). If
  Worker G shipped prefetching first, the dashboard would spawn 12-18
  concurrent Node processes and the user's complaint would get *worse*.
  It is also the only wave that touches `rest_api.lua`, so it is cleanly
  separable.
- **Phases 11 and 12 are one change to one file.** Both rewrite the
  keymap/fetch block of `org_dashboard.lua`; Step 41 refactors the very
  `<C-d>`/`<C-u>` bodies that Step 42 extends, and Step 39 rewrites the
  `on_cursor_move` that Step 43's test asserts against. Splitting them
  guarantees a conflict in one file and a second pass over the same
  tests.
- **Phases 13 and 14 stay together.** Step 50's incident row emphasis is
  defined in terms of Step 48's `SfDim`/`SfWarn`/`SfError` rules and uses
  Step 45's new groups; Step 50 also calls `append_table_section`, whose
  header group Step 48 changes. Shipping 14 without 13 means incidents
  reference a highlight group that does not exist yet.
- **Worker F and Worker H both touch `org_view.lua`** (F rewrites
  `fetch_org_display`, H extends `render_columns`) — different functions,
  but the same file, so they must not run concurrently.
- **Do not split Phase 13 by file.** `highlights.lua` defines the groups,
  `render_columns` gains the per-cell mechanism, and
  `dashboard_views.lua` consumes both; a worker that lands only one of
  the three ships a dashboard referencing undefined highlight groups.
