-- Normalizes Salesforce org data (from `sf org list` and `sf org display`)
-- into one record shape, and is the single authority for the org-type
-- predicates/highlight/badge logic derived from it. Pure functions only --
-- no I/O, no `vim.g` reads -- so every branch here is unit-testable
-- without a Neovim child process.
--
-- "is_default"/"is_default_devhub" are deliberately NOT part of this
-- model: they're session/CLI config state (which org is currently
-- targeted), not a property of the org itself, and change independently
-- of `sf org list` (e.g. `sf config set target-org` in another terminal).
-- Callers derive them at render time by comparing `record.alias` against
-- `util.target_org`/`require("sf.org").get_default_devhub_alias()` --
-- see org.lua's `Org.refresh_target_org_from_disk`.

local org_model = {}

--- Fields from `sf org display --json` that must never be written to disk
--- or rendered -- auth material that stays in the org's in-memory session
--- only (see rest_api.lua's TTL=300s `org_display_cache`, which exists
--- specifically because these expire and must not be persisted).
org_model.REDACT_KEYS = {
  accessToken = true,
  refreshToken = true,
  clientSecret = true,
  sfdxAuthUrl = true,
  privateKey = true,
}

--- Fields from `sf org display --json` safe to persist to disk, as an
--- ALLOWLIST rather than the REDACT_KEYS denylist above: rendering
--- (org_view.render_detail_lines) stays in-memory and TTL-bounded, so it
--- can fail open (show any field the CLI returns, except the denylist).
--- Persisting to a file in the user's project must fail closed instead --
--- a `sf` CLI field this list doesn't know about is simply dropped, not
--- written -- so a future CLI version can never silently leak a new
--- secret field into a cache file that might end up committed.
org_model.PERSISTED_DETAIL_KEYS = {
  "id",
  "instanceUrl",
  "orgName",
  "edition",
  "apiVersion",
  "connectedStatus",
  "status",
  "expirationDate",
  "createdDate",
  "devHubId",
}

--- @alias sf.OrgType "production"|"sandbox"|"scratch"

--- Normalize one `sf org list` entry (an element of `nonScratchOrgs` or
--- `scratchOrgs`) into this plugin's org record shape.
---@param raw table raw entry from `sf org list --json`
---@return table record { alias, username, org_type, expiration_date,
---  devhub_username, org_id }
function org_model.from_org_list(raw)
  local org_type
  if raw.isScratch == true then
    org_type = "scratch"
  elseif raw.isSandbox == true then
    org_type = "sandbox"
  else
    -- ponytail: "production" here just means "neither scratch nor
    -- sandbox" -- `sf org list` has no stronger signal, so a Developer
    -- Edition or trial org also lands here. Upgrade path: refine using
    -- the `edition` field (see merge_detail below) once a dashboard tab
    -- needs that distinction.
    org_type = "production"
  end

  return {
    alias = raw.alias or raw.username,
    username = raw.username,
    org_type = org_type,
    expiration_date = raw.expirationDate,
    -- Only present on scratch orgs; used by Org.delete_org to resolve
    -- which org's session to delete the ActiveScratchOrg record through.
    devhub_username = raw.devHubUsername,
    -- Used by Org.refresh_sandbox to look up the sandbox's
    -- SandboxProcess/SandboxName on the Dev Hub.
    org_id = raw.orgId,
  }
end

---@param record table
---@return boolean
function org_model.is_scratch(record)
  return record.org_type == "scratch"
end

---@param record table
---@return boolean
function org_model.is_sandbox(record)
  return record.org_type == "sandbox"
end

---@param record table
---@return boolean
function org_model.is_production(record)
  return record.org_type == "production"
end

--- Scratch orgs and sandboxes can be deleted from the dashboard; production
--- orgs cannot.
---@param record table
---@return boolean
function org_model.can_delete(record)
  return org_model.is_scratch(record) or org_model.is_sandbox(record)
end

--- Only sandboxes can be refreshed from their Dev Hub.
---@param record table
---@return boolean
function org_model.can_refresh(record)
  return org_model.is_sandbox(record)
end

--- Highlight group for the current org, colored by type.
---@param record table
---@return string highlight group name
function org_model.highlight_group(record)
  if org_model.is_production(record) then
    return "SfStatusProd"
  end
  if org_model.is_sandbox(record) then
    return "SfStatusSandbox"
  end
  if org_model.is_scratch(record) then
    return "SfStatusScratch"
  end
  return "SfStatusOrg"
end

--- Marker for the org-list pane: ● = default target org, ◆ = default
--- Dev Hub, ◈ = both. `is_default`/`is_default_devhub` are resolved by the
--- caller (see module doc comment above), not stored on the record.
---@param is_default boolean
---@param is_default_devhub boolean
---@return string
function org_model.badge(is_default, is_default_devhub)
  if is_default and is_default_devhub then
    return "◈ "
  elseif is_default then
    return "● "
  elseif is_default_devhub then
    return "◆ "
  end
  return "  "
end

--- Filter a raw `sf org display` result down to the allowlisted,
--- disk-safe fields -- see PERSISTED_DETAIL_KEYS. This is the ONLY
--- transformation `sf org display` output is allowed to reach disk
--- through (directly, or via `merge_detail` below) -- callers persisting
--- anything derived from `sf org display` must route it through this.
---@param display_result table raw `sf org display` result -- MAY contain
---  REDACT_KEYS fields; they are dropped here unconditionally
---@return table allowlisted fields only
function org_model.persistable_detail(display_result)
  local detail = {}
  for _, key in ipairs(org_model.PERSISTED_DETAIL_KEYS) do
    if display_result[key] ~= nil then
      detail[key] = display_result[key]
    end
  end
  return detail
end

--- Merge an (unredacted) `sf org display` result into `record`, keeping
--- only the allowlisted fields (`persistable_detail` above). Returns a new
--- table; does not mutate `record` or `display_result`.
---@param record table a record from `from_org_list` (or a previous
---  `merge_detail` call)
---@param display_result table raw `sf org display` result
---@return table merged record with `detail` and `detail_fetched_at` added
function org_model.merge_detail(record, display_result)
  local merged = vim.deepcopy(record)
  merged.detail = org_model.persistable_detail(display_result)
  merged.detail_fetched_at = os.time()
  return merged
end

return org_model
