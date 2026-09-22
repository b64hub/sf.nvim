-- Split-pane org dashboard: left pane shows org list, right pane shows
-- details/actions for the selected org. Mirrors the modal org_explorer's
-- architecture (generation counter, spinner timer, async detail fetch) but
-- stays open and re-renders the right pane on cursor movement instead of
-- toggling views.

local Layout = require("sf.ui.layout")
local org_view = require("sf.ui.org_view")
local dashboard_views = require("sf.ui.dashboard_views")

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
    local parts = {}
    for _, view_desc in ipairs(dashboard_views) do
      table.insert(parts, view_desc.key .. " " .. view_desc.label)
    end
    table.insert(parts, "q close")
    return " " .. table.concat(parts, " · ") .. " "
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

  local get_view_title = function()
    local active_view = nil
    for _, view_desc in ipairs(dashboard_views) do
      if view_desc.id == session.active_view_id then
        active_view = view_desc
        break
      end
    end
    return active_view and (" " .. active_view.label .. " ") or " View "
  end

  local view_win_opts = {
    relative = "editor",
    row = geometry_pair.right.row,
    col = geometry_pair.right.col,
    width = geometry_pair.right.width,
    height = geometry_pair.right.height,
    style = "minimal",
    border = ui_config.border or "rounded",
    title = { { get_view_title(), "SfTitle" } },
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

  local get_view_descriptor = function(view_id)
    for _, view_desc in ipairs(dashboard_views) do
      if view_desc.id == view_id then
        return view_desc
      end
    end
    return nil
  end

  -- The title was only set once at window-creation time (defaulting to
  -- whatever view was active then); refresh it whenever the active view
  -- changes so it doesn't go stale after a view-key switch.
  local update_view_title = function()
    if not vim.api.nvim_win_is_valid(session.view_window) then
      return
    end
    local cfg = {
      relative = "editor",
      row = geometry_pair.right.row,
      col = geometry_pair.right.col,
      width = geometry_pair.right.width,
      height = geometry_pair.right.height,
      title = { { get_view_title(), "SfTitle" } },
      title_pos = "left",
    }
    if has_footer then
      cfg.footer = { { footer_for(), "SfFooter" } }
      cfg.footer_pos = "left"
    end
    vim.api.nvim_win_set_config(session.view_window, cfg)
  end

  local paint_view = function(record, frame)
    if not vim.api.nvim_win_is_valid(session.view_window) then
      return
    end
    local cache_key = record.alias .. ":" .. session.active_view_id
    local cached = session.cache[cache_key]
    local view_data = cached and cached.data or nil
    local fetch_err = cached and cached.err or nil

    local view_desc = get_view_descriptor(session.active_view_id)
    if not view_desc then
      return
    end

    local lines, line_hls
    if fetch_err then
      lines = { "Failed to load: " .. fetch_err }
      line_hls = { { { group = "SfError", col_start = 0, col_end = #lines[1] } } }
    elseif not view_data and cached and cached.fetching then
      local spinner = org_view.SPINNER_FRAMES[(frame % #org_view.SPINNER_FRAMES) + 1]
      lines = { spinner .. " Loading..." }
      line_hls = { { { group = "SfSpinner", col_start = 0, col_end = #lines[1] } } }
    elseif view_data then
      lines, line_hls = view_desc.render(record, view_data)
    else
      lines = { "" }
      line_hls = { {} }
    end

    org_view.paint(session.view_buffer, lines, line_hls)
  end

  local show_view = function(record, view_id)
    local cache_key = record.alias .. ":" .. view_id
    local cached = session.cache[cache_key]

    -- Cache hit: paint immediately, no refetch
    if cached and cached.data then
      paint_view(record, 0)
      return
    end

    -- Already fetching: don't start another fetch
    if cached and cached.fetching then
      return
    end

    local view_desc = get_view_descriptor(view_id)
    if not view_desc then
      return
    end

    local frame = 0
    -- ponytail: switching views doesn't bump `generation` (only close()
    -- does), so rapid view-switching while a previous view's fetch is
    -- still in flight can have that fetch's completion callback steal
    -- the shared spinner_timer slot from whatever view is now active.
    -- End state is still correct (each fetch paints its own cache_key
    -- once done) -- worst case is a spinner freezing a frame early.
    -- Upgrade path: a per-cache-key generation/timer instead of one
    -- shared slot, if this ever turns out to be more than cosmetic.
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

    view_desc.fetch(record, function(result, err)
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
      show_view(record, session.active_view_id)
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

  -- Bind view selection keys
  for _, view_desc in ipairs(dashboard_views) do
    local view_key = view_desc.key
    local view_id = view_desc.id
    vim.keymap.set("n", view_key, function()
      local record = current_record()
      if record then
        session.active_view_id = view_id
        update_view_title()
        show_view(record, view_id)
      end
    end, { buffer = session.list_buffer, nowait = true })
  end

  -- Fetch view for the first org
  on_cursor_move()

  -- Make sure focus is on the list window
  vim.api.nvim_set_current_win(session.list_window)
end

return dashboard
