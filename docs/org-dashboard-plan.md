# Org dashboard — plan (lazygit-style, split-pane org explorer)

Status: idea → structured plan, ready for oracle step-by-step breakdown.
Not implemented yet. This doc is the handoff artifact.

## Goal

Turn the existing `sf.ui.org_explorer` modal (single float, list ⇄ detail
toggle, closes on selection) into a **second, persistent surface**: a
two-pane dashboard you open and stay in — org list on the left, an
action/detail pane on the right that re-renders in place instead of opening
new floats/splits per feature. Think lazygit's panel model, scoped to one
org at a time.

The existing modal picker (`org_explorer.pick`, used by `set_target_org`,
`set_global_target_org`, `diff_in_org`) is **not replaced**. It's a
"pick-one-and-close" contract three call sites already depend on. The
dashboard is a new, richer entry point that reuses the same rendering
primitives instead of duplicating them.

## Architecture

### Surface: two floating windows, not a tabpage or real splits

Reuse `lua/sf/ui/layout.lua` (`float_geometry`) rather than adopting a
dedicated tabpage + real `:vsplit` — that would need its own
open/close/restore-layout lifecycle management (remembering the user's
window layout, handling `:tabclose`, etc.) for no gain here, since nothing
in this feature needs real-buffer semantics (no editing, no LSP, no
swapfiles). Two floats positioned side by side, opened/closed together as
one unit, is the smaller diff and matches what `org_explorer.lua` already
does.

Add one geometry helper next to `float_geometry`:

```
Layout.float_geometry_pair(opts) -- opts: { position, width, height, left_ratio }
  -> { left = {row,col,width,height}, right = {row,col,width,height} }
```

`left_ratio` default ~0.3 (org list needs alias + a marker column, not much
else). Both windows share one border/title row so it reads as one dashboard,
not two unrelated floats.

### Shared state, not two independent widgets

One `S` session table (same shape as the existing picker's `S`) owns:
`records`, `cursor row → selected record`, `active_view id`, per-`(alias,
view_id)` cache, `gen` counter for stale-async guarding, both window/buffer
handles, spinner timer. Closing either window (`q`/`<Esc>`) tears down both.

### Left pane

Exactly today's `H.render_list_lines` output (color-coded by
prod/sandbox/scratch, `●` default marker, dimmed scratch expiry) — extract
it into a small shared module (see below) so both the modal picker and the
dashboard render identically instead of forking the logic.

Two additions the user asked for:

- **Default devhub marker**: today only `is_default` gets `●`. Add a second
  marker column for `is_default_devhub` (needs `isDefaultDevHubUsername`
  threaded from `sf org list --json` into the `helpers.orgs` record in
  `org.lua` — it's already in the JSON, just not read).
- **Relative scratch expiry** ("14d", "6d") instead of the raw
  `expirationDate` string. One pure function, `days_until(date_str) ->
  "14d"|"6d"|"today"|"expired"`, no new dependency.

Footer keymap hints: reuse the existing `win_opts.footer` mechanism
(`has_footer` check already in `org_explorer.lua`), just with the
dashboard's own hint string instead of the picker's.

### Right pane: a view registry, not per-feature plumbing

This is the actual extensibility ask. Keep it a plain Lua array, not a
plugin framework — a table of view descriptors is the whole mechanism:

```lua
-- lua/sf/ui/dashboard_views.lua
return {
  {
    id = "details", key = "d", label = "Details",
    fetch = function(record, cb) ... end,   -- may or may not need a session
    render = function(record, data) -> lines, line_hls end,
  },
  {
    id = "status", key = "S", label = "Instance status",
    fetch = function(record, cb) ... end,
    render = function(record, data) -> lines, line_hls end,
  },
  -- ...
}
```

Right-pane controller (~one small function): on a view keypress, look up
the descriptor, check `S.cache[record.alias .. ":" .. view.id]`, render from
cache immediately or show the existing spinner while `fetch` runs async,
paint on completion, guarded by the existing `gen` pattern. **Adding a
feature is one array entry + whatever backend call it needs** — no new
window/paint/spinner/cache code per feature, because that machinery is
already generic over "some async fetch produces some data to render."

A "combined" view (org details + org status in one screen, the case
explicitly called out) is *just another entry* whose `fetch` kicks off two
lookups and merges the results before calling back — no special-casing
needed in the controller.

Action keys (set default, enable logging, open org) always operate on
**whatever record the left-pane cursor is on**, regardless of which window
has input focus. Simpler than a lazygit-style dual-focus keymap table, and
matches how the picker already reads `current_record()` off the left
window's cursor.

### Extract shared org-record rendering + fetch

Pull these out of `org_explorer.lua` into `lua/sf/ui/org_view.lua` (or
similar — name it for what it does, not `U`/`H`):
`render_list_lines`, `hl_for`, `pad`, `fetch_org_display` (the `sf org
display --json` detail fetch + its redact-key list). Both
`org_explorer.lua` (modal) and the new dashboard import this instead of the
dashboard reimplementing org rendering from scratch. This is the
prerequisite refactor — do it first, it's almost a pure move, and it's what
makes the rest of the plan "add a view," not "add a screen."

## Backend reuse audit (what already exists vs. what's new)

| Feature | Backend | Status |
|---|---|---|
| Org list + colors + expiry | `org.lua: helpers.orgs`, `org_explorer.lua` render | exists, extract & reuse |
| Devhub marker | `isDefaultDevHubUsername` from `sf org list --json` | field already returned, not read into `helpers.orgs` yet — 1-line add |
| Org details | `sf org display --json` (`H.fetch_org_display`) | exists, extract into shared module |
| Set default (local/global) | `helpers.write_target_org_to_config` + `helpers.mark_default` | exists as-is, just wire a dashboard keymap to it |
| Open org | `helpers.open_org(alias)` | exists as-is |
| Enable logging (trace flag) | `Debug.enable_replay_logging({user, minutes, ...})`, `H.upsert_trace_flag` | exists, but keyed off `util.target_org` / `Api.get_session()` with **no alias param** — needs `Api.get_session(alias, cb)` to target an arbitrary highlighted org, not just the global target org |
| See current trace flags | `Api.query` (Tooling SOQL on `TraceFlag`) | query mechanism exists, no view yet — new SOQL + render, small |
| Fetch logs (searchable/filterable) | `helpers.pick_org_log` (`apex list log` + fzf-lua) | **partially reusable**: today's version is fzf-lua-coupled and target-org-only. Dashboard wants logs listed *natively in the right pane* (per user's ask) with native `/` search — needs a `list_org_logs(alias, cb)` split out from the fzf/download bits, reusing `apex list log --json` decode only. Filtering = a small in-buffer substring filter (press a key, prompt, re-render), not a new dependency. |
| Org status (status.salesforce.com) | none yet | new: 1 SOQL (`SELECT InstanceName FROM Organization` via `Api.query_std`) + 1 unauthenticated `curl` to `https://api.status.salesforce.com/v1/instances/<name>/status` |
| Metadata browsing | `md.lua` (retrieve-oriented, not browse-oriented) | new read-only view: `sf org list metadata --json` or Tooling `SELECT ... FROM ...` per type, for a *browse* screen — heavier, keep it a later phase (see below) |

Small necessary infra change (not a "framework," just fixing a gap): thread
an optional `alias` through `Api.get_session` in `rest_api.lua` (it already
builds an `sf org display` command; just needs `:set_org(alias)` when one
is passed), since every dashboard action targets the org under the cursor,
not necessarily `util.target_org`.

## Extra ideas worth bouncing back

- **Org limits** (`/services/data/vNN/limits`, one unauthenticated-by-token
  REST GET) — API usage %, storage, a genuinely useful "org health" view for
  near-zero backend cost, pairs naturally with the status view.
- **Refresh key (`r`)** re-runs `fetch_org_list` without closing the
  dashboard, instead of any auto-polling/background timer — no
  new resource usage, refresh is explicit.
- **Recent deploy/retrieve history** per org (Tooling `DeployRequest`) —
  useful, but defer; needs its own filtering/paging story.
- **Installed packages list** — one Tooling query, cheap, good candidate for
  an early "extra view."
- Cache invalidation is manual (`r`), not TTL-based — one less moving part,
  matches "refresh key" above.

## Explicitly deferred (named so nobody assumes it's in scope)

- Metadata *browsing* (as opposed to today's retrieve-on-demand flow) is a
  real feature on its own (type → members → maybe preview) and shouldn't
  block phase 1. Land it as its own view once the registry exists.
- No live/polling refresh of any view (logs, trace flags, status) — every
  fetch is manual (open view / press `r`). Add polling only if someone
  actually asks for a "tail logs" experience.
- No multi-org compare/diff view. Bounced above as an idea, not a commitment.
- No new external dependency (no HTTP client lib, no JSON schema lib) —
  everything above is `curl` + `vim.json.decode`, same as the rest of the
  plugin.

## Suggested phase breakdown (for the oracle)

1. **Extract** `org_view.lua` (render_list_lines/hl_for/pad/fetch_org_display)
   out of `org_explorer.lua`, both call sites keep passing existing tests.
2. **Dashboard shell**: `float_geometry_pair`, the two-window session, close
   handling, left pane using the extracted render, right pane showing just
   the "details" view (reusing the extracted fetch). No other views yet —
   this proves the split-pane mechanics end to end.
3. **View registry mechanism** + 2-3 real views to validate the shape:
   details (already have it), set-default (action, not fetch), org status
   (new REST+curl view — proves the "new feature = one entry" claim).
4. **Alias-scoped session** (`Api.get_session(alias, cb)`) as a
   prerequisite, then trace-flags view + enable-logging action land on top
   of it.
5. **Native log list view** (`list_org_logs` split out of
   `helpers.pick_org_log`) with in-buffer filter — the most involved item,
   do it once the registry pattern is proven, not first.
6. Everything in "explicitly deferred" is its own follow-up, not part of
   this phase set.

Each phase should carry its own `tests/` coverage per `AGENTS.md` (pure
functions like `days_until`, `list_org_logs` parsing, the geometry-pair
math) — `mini.test`, following existing test file patterns.
