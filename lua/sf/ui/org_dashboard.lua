-- Split-pane org dashboard: left pane shows org list, right pane shows
-- details/actions for the selected org. Mirrors the modal org_explorer's
-- architecture (generation counter, spinner timer, async detail fetch) but
-- stays open and re-renders the right pane on cursor movement instead of
-- toggling views.

local Layout = require("sf.ui.layout")
local org_view = require("sf.ui.org_view")

local dashboard = {}

--- Open a split-pane dashboard showing orgs on the left, details on the right.
---@param records table[] org records (alias, username, is_scratch, is_sandbox, is_prod, is_default, is_default_devhub, expiration_date)
---@param opts table { prompt = string }
function dashboard.open(records, opts)
  if #records == 0 then
    return vim.notify("Sf: no orgs available. Run :SF org list first.", vim.log.levels.WARN)
  end

  local list_lines, list_hls = org_view.render_list_lines(records)

  local list_buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buffer].filetype = "SfOrgDashboard"
  org_view.paint(list_buffer, list_lines, list_hls)

  local view_buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[view_buffer].filetype = "SfOrgDashboard"

  local ui_config = (vim.g.sf and vim.g.sf.ui) or {}
  local has_footer = vim.fn.has("nvim-0.10") == 1

  --- Session state for this dashboard.
  local session = {
    list_buffer = list_buffer,
    list_window = nil,
    view_buffer = view_buffer,
    view_window = nil,
    active_view_id = "details", -- which view to show
    cache = {}, -- key = "alias:view_id", value = { data = ..., fetching = bool }
    generation = 0, -- bumped on state changes; guards stale async results
    spinner_timer = nil,
  }

  local footer_for = function()
    return " <CR> open · q close "
  end

  local geometry_pair = Layout.float_geometry_pair({
    position = "center",
    width = 0.9,
    height = 0.8,
    left_ratio = 0.3,
  })

  local list_win_opts = {
    relative = "editor",
    row = geometry_pair.left.row,
    col = geometry_pair.left.col,
    width = geometry_pair.left.width,
    height = geometry_pair.left.height,
    style = "minimal",
    border = ui_config.border or "rounded",
    title = { { " " .. (opts.prompt or "Orgs") .. " ", "SfTitle" } },
    title_pos = "left",
  }
  if has_footer then
    list_win_opts.footer = { { footer_for(), "SfFooter" } }
    list_win_opts.footer_pos = "left"
  end

  local view_win_opts = {
    relative = "editor",
    row = geometry_pair.right.row,
    col = geometry_pair.right.col,
    width = geometry_pair.right.width,
    height = geometry_pair.right.height,
    style = "minimal",
    border = ui_config.border or "rounded",
    title = { { " Details ", "SfTitle" } },
    title_pos = "left",
  }
  if has_footer then
    view_win_opts.footer = { { footer_for(), "SfFooter" } }
    view_win_opts.footer_pos = "left"
  end

  local list_window = vim.api.nvim_open_win(list_buffer, true, list_win_opts)
  local view_window = vim.api.nvim_open_win(view_buffer, false, view_win_opts)

  session.list_window = list_window
  session.view_window = view_window

  vim.wo[list_window].cursorline = true
  vim.wo[view_window].cursorline = false

  vim.api.nvim_win_set_option(
    list_window,
    "winhl",
    "Normal:SfNormal,FloatBorder:SfBorder,FloatTitle:SfTitle,FloatFooter:SfFooter,CursorLine:Visual"
  )
  vim.api.nvim_win_set_option(
    view_window,
    "winhl",
    "Normal:SfNormal,FloatBorder:SfBorder,FloatTitle:SfTitle,FloatFooter:SfFooter"
  )

  local stop_spinner = function()
    if session.spinner_timer then
      session.spinner_timer:stop()
      session.spinner_timer:close()
      session.spinner_timer = nil
    end
  end

  local paint_view = function(record, frame)
    if not vim.api.nvim_win_is_valid(session.view_window) then
      return
    end
    local cache_key = record.alias .. ":" .. session.active_view_id
    local cached = session.cache[cache_key]
    local detail = cached and cached.data or nil
    local fetch_err = cached and cached.err or nil

    local detail_lines, detail_hls = org_view.render_detail_lines(record, frame, detail, fetch_err)
    org_view.paint(session.view_buffer, detail_lines, detail_hls)
  end

  local fetch_detail = function(record)
    local cache_key = record.alias .. ":" .. session.active_view_id
    local cached = session.cache[cache_key]

    if cached and cached.data then
      paint_view(record, 0)
      return
    end

    if cached and cached.fetching then
      return
    end

    local frame = 0
    local current_gen = session.generation

    stop_spinner()
    session.cache[cache_key] = { fetching = true, data = nil }
    paint_view(record, frame)

    session.spinner_timer = vim.uv.new_timer()
    session.spinner_timer:start(
      0,
      100,
      vim.schedule_wrap(function()
        if current_gen ~= session.generation or not vim.api.nvim_win_is_valid(session.view_window) then
          return
        end
        frame = frame + 1
        paint_view(record, frame)
      end)
    )

    org_view.fetch_org_display(record, function(result, err)
      if current_gen ~= session.generation then
        return
      end
      stop_spinner()
      session.cache[cache_key] = { fetching = false, data = result, err = err }
      if vim.api.nvim_win_is_valid(session.view_window) then
        paint_view(record, 0)
      end
    end)
  end

  local current_record = function()
    if not vim.api.nvim_win_is_valid(session.list_window) then
      return nil
    end
    local row = vim.api.nvim_win_get_cursor(session.list_window)[1]
    return records[row]
  end

  local on_cursor_move = function()
    local record = current_record()
    if record then
      fetch_detail(record)
    end
  end

  local close = function()
    session.generation = session.generation + 1
    stop_spinner()
    if vim.api.nvim_win_is_valid(session.list_window) then
      vim.api.nvim_win_close(session.list_window, true)
    end
    if vim.api.nvim_win_is_valid(session.view_window) then
      vim.api.nvim_win_close(session.view_window, true)
    end
    pcall(vim.api.nvim_del_augroup_by_name, "SfOrgDashboardCursor")
  end

  -- Set up CursorMoved autocommand on the list buffer.
  vim.api.nvim_create_augroup("SfOrgDashboardCursor", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = "SfOrgDashboardCursor",
    buffer = session.list_buffer,
    callback = on_cursor_move,
  })

  vim.keymap.set("n", "q", close, { buffer = session.list_buffer, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = session.list_buffer, nowait = true })

  -- Fetch detail for the first org
  on_cursor_move()

  -- Make sure focus is on the list window
  vim.api.nvim_set_current_win(session.list_window)
end

return dashboard
