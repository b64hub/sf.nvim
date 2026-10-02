# AGENTS.md

Guidance for AI agents (and humans) contributing to this fork of sf.nvim.

## Context

This is a fork under new maintainership, diverging from upstream conventions.
Where this file conflicts with existing code, this file wins for new/changed
code — don't spread old patterns, but don't mass-rewrite unrelated code
either. Fix style in a file only when you're already touching it.

## Naming

No single/double-letter identifiers except trivial loop indices (`i`, `_`).
This includes the existing `U` (util), `M`/`H` (module/helpers) table
convention — do not reuse it in new code.

- Full, descriptive names: `local util = require("sf.util")`,
  `local helpers = {}`.
- Module return table: name it after the module's purpose or just keep it
  local and return it directly, not a bare `M`.
- When you're already editing a file for something else, rename any
  `U`/`M`/`H`/`B`/`T`/etc. single- or double-letter identifiers it still has
  to descriptive names as part of that change (whole file, not just the
  lines you touched) — this is a case where AGENTS.md wins over the old
  in-file pattern. Don't go out of your way to open unrelated files just to
  rename them.

## General style

- Follow standard Lua / Neovim plugin best practices (existing `.stylua.toml`
  formatting still applies — 2-space indent).
- Prefer small, focused functions over deeply nested ones.
- Public API surface stays documented via doc-comments in `init.lua` (these
  generate `:h sf.nvim` — don't break that).

## Salesforce API vs CLI

Prefer direct Salesforce API calls (REST/Tooling/Metadata API, e.g. via
`curl`/`plenary.curl` against the org's instance URL + access token) over
shelling out to `sf` CLI, when a direct call can do the job.

Rationale: `sf` CLI spawns a Node process per invocation — slow, and often the
CLI command itself is a thin wrapper around one API call anyway.

- Reuse `sf org display`/existing auth plumbing to get the access token +
  instance URL, then call the API directly instead of adding another CLI
  shell-out.
- CLI remains the right choice where there's no simple direct equivalent
  (e.g. `sf project deploy start` source-format conversion/deploy
  orchestration) — don't reimplement that.

## Caching

Everything this plugin persists to disk lives under one project-local,
configurable folder: `vim.g.sf.cache_dir` (default `/.nvim/sf/`, resolved
under the sf project root via `util.get_sf_root()` — same place as `.sf/`/
`.sfdx/`). It's project-local, not a global `stdpath("cache")`, because the
content is keyed by *which org this project talks to*, the same reasoning
behind Salesforce's own `.sfdx/tools/`. Don't add a second config key for
this — the folder also holds a few non-cache working files (retrieve-diff
scratch space, metadata listings), and one key is enough; see `util.lua`'s
`get_cache_dir` doc comment.

Two primitives in `lua/sf/cache.lua` are the only things that should ever
touch that folder directly (besides `util.lua`'s low-level
`read_cache_json`/`write_cache_json`/`read_cache_text`/`write_cache_text`/
`delete_cache_file`, which `cache.lua` itself is built on):

- `cache.new({ ttl_seconds, fetch })` — in-memory-only TTL + in-flight-
  coalescing cache for one kind of keyed async fetch (e.g. `sf org
  display`, `sf org list`). Never persists anything; use this alone when a
  value must never reach disk (tokens, anything from `rest_api.lua`'s
  session).
- `cache.disk_store(locate)` — a disk-backed key/value store, where
  `locate(key)` returns `(file, subkey)`. Several keys sharing one file
  (e.g. every dashboard view cached for one org, in one
  `orgs/<alias>.json`) is deliberate and safe: the store loads a file into
  memory at most once and, on every `:set`, mutates that in-memory table
  and dumps the WHOLE table back in one synchronous call — never
  read-modify-write. A read-modify-write that spans an async fetch IS the
  actual race (two such sequences for different keys can interleave at the
  await boundary and the second write clobbers the first), and
  single-threaded Neovim does not protect against that; mutate-then-dump
  has no suspension point in between, so it can't lose a sibling key's
  update. Don't "fix" this with a write queue — that solves a problem
  mutate-then-dump already doesn't have.
- Cross-process races (two Neovim instances touching the same file) are
  deliberately unhandled: last write wins, `util.write_cache_json`'s atomic
  rename guarantees the loser's write is still a complete, valid file, and
  since this is all disposable cache, the next read just refetches. Don't
  add a lockfile unless a real shared-project workflow shows lost
  snapshots.

**Org domain data** (`lua/sf/org_model.lua`) is a separate concern from
storage: one normalized `org_type: "production"|"sandbox"|"scratch"`
replaces what used to be three booleans, with `org_model` as the sole
authority for every predicate/highlight/badge derived from it
(`is_scratch`, `can_delete`, `highlight_group`, ...). Never add a new
`is_*` boolean field to an org record — add a predicate function to
`org_model.lua` instead, even if today it's a one-line wrapper around
`org_type`.

`is_default`/`is_default_devhub` ("is this the current target org / Dev
Hub") are deliberately **not** part of an org record at all, and must never
be persisted. They're session/CLI config state that can change outside
Nvim (`sf config set target-org` in another terminal), so they're always
resolved fresh by comparing an alias against `util.target_org`/
`Org.get_default_devhub_alias()` — both of which are themselves read from
the `sf` CLI's own `.sf/config.json` (project, then global), not stored or
inferred. If this plugin's cache and the `sf` CLI's own config ever
disagree, the CLI's config wins — that's what re-reading it instead of
caching a flag achieves. Don't reintroduce a stored `is_default` field to
"optimize away" that reread; it was a real bug before (a stale `●` marker
could point at the wrong org on cold start).

**Secrets never reach disk.** `sf org display`'s raw result may contain
`accessToken`/`refreshToken`/`clientSecret`/`sfdxAuthUrl`/`privateKey` —
fine to hold in memory (`rest_api.lua`'s `org_display_cache` is TTL-bounded
and exists for exactly this), never fine to write to a file. Rendering
(`org_view.lua`) uses `org_model.REDACT_KEYS` as a denylist, which is
acceptable there because it's in-memory and TTL-bounded (fail-open on an
unknown future field is a cosmetic risk at worst). Anything persisted
must instead go through `org_model.persistable_detail`'s **allowlist**
(`org_model.PERSISTED_DETAIL_KEYS`) so an unknown field fails closed —
dropped, not written — instead of silently leaking a future secret field
into a cache file that might sit in the user's repo. If you add a new
disk-persisted cache sourced from `sf org display` (or any other command
that can return auth material), route it through that allowlist; don't
invent a second denylist for a new disk write path.

## Tests

- Test framework: `mini.test` (see `Makefile`, `make test`).
- Non-trivial logic (branches, parsing, filtering) added or changed should
  get a test in `tests/`, following existing test file patterns.
