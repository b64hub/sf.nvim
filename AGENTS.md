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

## Tests

- Test framework: `mini.test` (see `Makefile`, `make test`).
- Non-trivial logic (branches, parsing, filtering) added or changed should
  get a test in `tests/`, following existing test file patterns.
