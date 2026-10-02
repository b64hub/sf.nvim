local helpers = dofile("tests/helpers.lua")
local child = helpers.new_child_neovim()
local eq = MiniTest.expect.equality
local new_set = MiniTest.new_set

local T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      child.lua([[org_model = require('sf.org_model')]])
    end,
    post_once = child.stop,
  },
})

T["from_org_list"] = new_set()

T["from_org_list"]["a scratch org (isScratch = true)"] = function()
  child.lua([[
    R = org_model.from_org_list({
      alias = "scratch1", username = "u@scratch", isScratch = true, isSandbox = false,
      expirationDate = "2025-01-15", devHubUsername = "hub@example.com", orgId = "00D1",
    })
  ]])
  eq(child.lua_get([[R.org_type]]), "scratch")
  eq(child.lua_get([[R.alias]]), "scratch1")
  eq(child.lua_get([[R.devhub_username]]), "hub@example.com")
  eq(child.lua_get([[R.expiration_date]]), "2025-01-15")
  eq(child.lua_get([[R.org_id]]), "00D1")
end

T["from_org_list"]["a sandbox (isSandbox = true, isScratch = false)"] = function()
  child.lua([[R = org_model.from_org_list({ alias = "sb1", username = "u@sb", isScratch = false, isSandbox = true })]])
  eq(child.lua_get([[R.org_type]]), "sandbox")
end

T["from_org_list"]["neither scratch nor sandbox normalizes to production"] = function()
  child.lua([[R = org_model.from_org_list({ alias = "prod1", username = "u@prod", isScratch = false, isSandbox = false })]])
  eq(child.lua_get([[R.org_type]]), "production")
end

T["from_org_list"]["falls back to username when alias is nil"] = function()
  child.lua([[R = org_model.from_org_list({ username = "u@prod", isScratch = false, isSandbox = false })]])
  eq(child.lua_get([[R.alias]]), "u@prod")
end

T["predicates"] = new_set()

T["predicates"]["is_scratch/is_sandbox/is_production are mutually exclusive"] = function()
  child.lua([[
    SCRATCH = { org_type = "scratch" }
    SANDBOX = { org_type = "sandbox" }
    PROD = { org_type = "production" }
  ]])
  eq(child.lua_get([[org_model.is_scratch(SCRATCH)]]), true)
  eq(child.lua_get([[org_model.is_sandbox(SCRATCH)]]), false)
  eq(child.lua_get([[org_model.is_production(SCRATCH)]]), false)

  eq(child.lua_get([[org_model.is_sandbox(SANDBOX)]]), true)
  eq(child.lua_get([[org_model.is_scratch(SANDBOX)]]), false)

  eq(child.lua_get([[org_model.is_production(PROD)]]), true)
  eq(child.lua_get([[org_model.is_scratch(PROD)]]), false)
  eq(child.lua_get([[org_model.is_sandbox(PROD)]]), false)
end

T["can_delete / can_refresh"] = new_set()

T["can_delete / can_refresh"]["scratch orgs and sandboxes can be deleted; production cannot"] = function()
  eq(child.lua_get([[org_model.can_delete({ org_type = "scratch" })]]), true)
  eq(child.lua_get([[org_model.can_delete({ org_type = "sandbox" })]]), true)
  eq(child.lua_get([[org_model.can_delete({ org_type = "production" })]]), false)
end

T["can_delete / can_refresh"]["only sandboxes can be refreshed"] = function()
  eq(child.lua_get([[org_model.can_refresh({ org_type = "sandbox" })]]), true)
  eq(child.lua_get([[org_model.can_refresh({ org_type = "scratch" })]]), false)
  eq(child.lua_get([[org_model.can_refresh({ org_type = "production" })]]), false)
end

T["highlight_group"] = new_set()

T["highlight_group"]["one highlight group per org type"] = function()
  eq(child.lua_get([[org_model.highlight_group({ org_type = "production" })]]), "SfStatusProd")
  eq(child.lua_get([[org_model.highlight_group({ org_type = "sandbox" })]]), "SfStatusSandbox")
  eq(child.lua_get([[org_model.highlight_group({ org_type = "scratch" })]]), "SfStatusScratch")
end

T["badge"] = new_set()

T["badge"]["neither default nor default devhub"] = function()
  eq(child.lua_get([[org_model.badge(false, false)]]), "  ")
end

T["badge"]["default target org only"] = function()
  eq(child.lua_get([[org_model.badge(true, false)]]), "● ")
end

T["badge"]["default devhub only"] = function()
  eq(child.lua_get([[org_model.badge(false, true)]]), "◆ ")
end

T["badge"]["both"] = function()
  eq(child.lua_get([[org_model.badge(true, true)]]), "◈ ")
end

T["merge_detail"] = new_set()

T["merge_detail"]["keeps only allowlisted fields, dropping unknown ones"] = function()
  child.lua([[
    RECORD = { alias = "org1", org_type = "production" }
    MERGED = org_model.merge_detail(RECORD, {
      id = "00D1", instanceUrl = "https://x", orgName = "Acme", edition = "Enterprise Edition",
      apiVersion = "60.0", connectedStatus = "Connected", status = "Active",
      expirationDate = "2025-01-01", createdDate = "2020-01-01", devHubId = "00D2",
      someFutureField = "unexpected",
    })
  ]])
  eq(child.lua_get([[MERGED.detail.id]]), "00D1")
  eq(child.lua_get([[MERGED.detail.orgName]]), "Acme")
  eq(child.lua_get([[MERGED.detail.someFutureField == nil]]), true)
  eq(child.lua_get([[type(MERGED.detail_fetched_at)]]), "number")
end

T["merge_detail"]["never persists a REDACT_KEYS field, even though the raw result carries one"] = function()
  child.lua([[
    MERGED = org_model.merge_detail({ alias = "org1", org_type = "production" }, {
      id = "00D1",
      accessToken = "00D1!super-secret-token",
      refreshToken = "also-secret",
      clientSecret = "also-secret",
      sfdxAuthUrl = "force://also-secret",
      privateKey = "also-secret",
    })
  ]])
  eq(child.lua_get([[MERGED.detail.accessToken == nil]]), true)
  eq(child.lua_get([[MERGED.detail.refreshToken == nil]]), true)
  eq(child.lua_get([[MERGED.detail.clientSecret == nil]]), true)
  eq(child.lua_get([[MERGED.detail.sfdxAuthUrl == nil]]), true)
  eq(child.lua_get([[MERGED.detail.privateKey == nil]]), true)
  eq(child.lua_get([[MERGED.detail.id]]), "00D1")
end

T["merge_detail"]["does not mutate the original record or display_result"] = function()
  child.lua([[
    RECORD = { alias = "org1", org_type = "production" }
    DISPLAY = { id = "00D1" }
    MERGED = org_model.merge_detail(RECORD, DISPLAY)
  ]])
  eq(child.lua_get([[RECORD.detail == nil]]), true)
  eq(child.lua_get([[DISPLAY.detail == nil]]), true)
end

return T
