-- Modal org explorer: a plain table (icon, alias, username, expiry for
-- scratch orgs), with `<Tab>` to drill into full `sf org display` detail
-- for the org under the cursor. Not a general-purpose picker -- specific
-- to org records, mirroring `sf org list` for the summary and
-- `sf org display` for detail.
--
-- Rendering and fetching logic is extracted into org_view.lua so it can be
-- reused by both this modal and the future dashboard.
local Layout = require("sf.ui.layout")
local org_view = require("sf.ui.org_view")

local explorer = {}

--- Show the explorer. `<CR>` calls `opts.on_choice(record)` for the org
--- under the cursor (list view) or currently expanded (detail view).
--- `<Tab>` toggles list/detail. `o` calls `opts.on_open(record)` (e.g. `sf
--- org open`) without closing. `q`/`<Esc>`/`<BS>` go back to the list from
--- detail, or close entirely from the list.
---@param records table[] { alias, username, is_scratch, is_sandbox, is_prod, is_default, expiration_date }
---@param opts table { prompt = string, on_choice = fun(record: table), on_open = fun(record: table)|nil }
function explorer.pick(records, opts)
  if #records == 0 then
    return vim.notify("Sf: no orgs available. Run :SF org list first.", vim.log.levels.WARN)
  end

  local list_lines, list_hls = org_view.render_list_lines(records)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "SfOrgExplorer"
  org_view.paint(buf, list_lines, list_hls)

  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  local has_footer = vim.fn.has("nvim-0.10") == 1

  --- Session state for this one explorer invocation.
  local session = {
    view = "list", -- "list" | "detail"
    detail_alias = nil,
    cache = {}, -- alias -> parsed `sf org display` result
    gen = 0, -- bumped on every view/alias change; guards stale async results
    win = nil,
    spinner_timer = nil,
  }

  local footer_for = function()
    if session.view == "detail" then
      return " <CR> select · o open · <Tab>/q/<BS> back "
    end
    local open_hint = opts.on_open and "o open · " or ""
    return " <CR> select · <Tab> details · " .. open_hint .. "q close "
  end

  local geometry_for = function(lines)
    local content_width = 0
    for _, line in ipairs(lines) do
      content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
    end
    content_width = math.min(content_width, vim.o.columns - 6)
    local content_height = math.min(#lines, vim.o.lines - 8)
    return Layout.float_geometry({
      position = "center",
      width = content_width + 2, -- float_geometry subtracts border cells back off
      height = content_height + 2,
    })
  end

  local geo = geometry_for(list_lines)

  local win_opts = {
    relative = "editor",
    row = geo.row,
    col = geo.col,
    width = geo.width,
    height = geo.height,
    style = "minimal",
    border = ui.border or "rounded",
    title = { { " " .. (opts.prompt or "Select org") .. " ", "SfTitle" } },
    title_pos = "left",
  }
  if has_footer then
    win_opts.footer = { { footer_for(), "SfFooter" } }
    win_opts.footer_pos = "left"
  end

  local win = vim.api.nvim_open_win(buf, true, win_opts)
  session.win = win

  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_option(
    win,
    "winhl",
    "Normal:SfNormal,FloatBorder:SfBorder,FloatTitle:SfTitle,FloatFooter:SfFooter,CursorLine:Visual"
  )

  local stop_spinner = function()
    if session.spinner_timer then
      session.spinner_timer:stop()
      session.spinner_timer:close()
      session.spinner_timer = nil
    end
  end

  local resize = function(lines)
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local geometry = geometry_for(lines)
    local cfg = { relative = "editor", row = geometry.row, col = geometry.col, width = geometry.width, height = geometry.height }
    if has_footer then
      cfg.footer = { { footer_for(), "SfFooter" } }
      cfg.footer_pos = "left"
    end
    vim.api.nvim_win_set_config(win, cfg)
  end

  local render_detail = function(record)
    local frame = 0
    local detail = session.cache[record.alias]
    local dlines, dhls = org_view.render_detail_lines(record, frame, detail, nil)
    resize(dlines)
    org_view.paint(buf, dlines, dhls)

    if detail then
      return -- cached; nothing to fetch
    end

    local gen = session.gen
    stop_spinner()
    session.spinner_timer = vim.uv.new_timer()
    session.spinner_timer:start(
      0,
      100,
      vim.schedule_wrap(function()
        if gen ~= session.gen or not vim.api.nvim_win_is_valid(win) then
          return
        end
        frame = frame + 1
        local lines2, hls2 = org_view.render_detail_lines(record, frame, session.cache[record.alias], nil)
        org_view.paint(buf, lines2, hls2)
      end)
    )

    org_view.fetch_org_display(record, function(result, err)
      if gen ~= session.gen then
        return -- user moved on (closed, went back, expanded a different org)
      end
      stop_spinner()
      if result then
        session.cache[record.alias] = result
      end
      if vim.api.nvim_win_is_valid(win) then
        local lines3, hls3 = org_view.render_detail_lines(record, 0, result, err)
        resize(lines3)
        org_view.paint(buf, lines3, hls3)
      end
    end)
  end

  local render_list = function()
    resize(list_lines)
    org_view.paint(buf, list_lines, list_hls)
  end

  local current_record = function()
    if session.view == "detail" then
      for _, record in ipairs(records) do
        if record.alias == session.detail_alias then
          return record
        end
      end
      return nil
    end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    return records[row]
  end

  local close = function()
    session.gen = session.gen + 1
    stop_spinner()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local toggle_detail = function()
    session.gen = session.gen + 1
    stop_spinner()
    if session.view == "list" then
      local record = current_record()
      if not record then
        return
      end
      session.view = "detail"
      session.detail_alias = record.alias
      render_detail(record)
    else
      session.view = "list"
      session.detail_alias = nil
      render_list()
    end
  end

  -- q / <Esc> / <BS>: go back to the list from detail, close from the list.
  local back_or_close = function()
    if session.view == "detail" then
      toggle_detail()
    else
      close()
    end
  end

  local select_current = function()
    local record = current_record()
    close()
    if record then
      opts.on_choice(record)
    end
  end

  local open_current = function()
    if not opts.on_open then
      return
    end
    local record = current_record()
    if record then
      opts.on_open(record)
    end
  end

  vim.keymap.set("n", "<CR>", select_current, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Tab>", toggle_detail, { buffer = buf, nowait = true })
  vim.keymap.set("n", "o", open_current, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", back_or_close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", back_or_close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<BS>", back_or_close, { buffer = buf, nowait = true })

  -- `nvim_open_win(..., enter=true, ...)` above already focuses it; this is
  -- belt-and-suspenders for callers that trigger the picker from unusual
  -- contexts (e.g. a lualine mouse click), where focus previously leaked to
  -- whatever buffer was underneath.
  vim.api.nvim_set_current_win(win)
end

return explorer
