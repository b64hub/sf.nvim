-- Split-pane org dashboard: left pane shows org list, right pane shows
-- details/actions for the selected org. Uses a generation counter, spinner
-- timer, and async detail fetching; stays open and re-renders the right pane
-- on cursor movement.

local util = require("sf.util")
local Layout = require("sf.ui.layout")
local org_view = require("sf.ui.org_view")
local dashboard_views = require("sf.ui.dashboard_views")
local Org = require("sf.org")
local rest_api = require("sf.sub.rest_api")

local dashboard = {}

-- Singleton guard: hold the active session so only one dashboard instance
-- can be open at a time.
local active_session = nil

--- Handle a winbar tab click. Called by Neovim's winbar click routing.
---@param minwid number 1-based index into views.tab_views(), passed by Neovim
---@param clicks number number of clicks (unused, but part of the Neovim signature)
---@param button string mouse button (unused, but part of the Neovim signature)
---@param modifiers string key modifiers (unused, but part of the Neovim signature)
function dashboard.handle_tab_click(minwid, clicks, button, modifiers)
  if not active_session or not vim.api.nvim_win_is_valid(active_session.list_window) then
    return
  end

  local tabs = dashboard_views.tab_views()
  if minwid < 1 or minwid > #tabs then
    return
  end

  local tab_view = tabs[minwid]
  active_session.active_view_id = tab_view.id
  active_session.filter_query = nil
  active_session.update_tab_strip()
  active_session.show_view(active_session.current_record(), tab_view.id)

  if vim.api.nvim_win_is_valid(active_session.list_window) then
    vim.api.nvim_set_current_win(active_session.list_window)
  end
end

--- Open a split-pane dashboard showing orgs on the left, details on the right.
---@param records table[] org records (alias, username, is_scratch, is_sandbox, is_prod, is_default, is_default_devhub, expiration_date)
---@param opts table { prompt = string }
function dashboard.open(records, opts)
  if #records == 0 then
    return vim.notify("Sf: no orgs available. Run :SF org list first.", vim.log.levels.WARN)
  end

  -- Singleton guard: if a dashboard is already open, re-focus its list window
  -- instead of creating a duplicate pair of floats.
  if active_session then
    if vim.api.nvim_win_is_valid(active_session.list_window) then
      vim.api.nvim_set_current_win(active_session.list_window)
      return
    end
    -- Window was closed externally; fall through and create a new session.
    active_session = nil
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
    filter_query = nil, -- current filter query for logs view
    filtered_logs = {}, -- keeps track of log ids in rendered order for download mapping
  }

  -- Left pane (org list) footer: org-identity actions -- which org this is
  -- and what to do with it (set as target, open in browser).
  local footer_for_list = function()
    local parts = {}
    for _, view_desc in ipairs(dashboard_views.action_views("left")) do
      table.insert(parts, view_desc.key .. " " .. view_desc.label)
    end
    return " " .. table.concat(parts, " · ") .. " "
  end

  -- Right pane (detail view) footer: misc/view-scoped actions plus
  -- dashboard-level keys that have no descriptor.
  local footer_for_view = function()
    local parts = {}
    for _, view_desc in ipairs(dashboard_views.action_views("right")) do
      table.insert(parts, view_desc.key .. " " .. view_desc.label)
    end
    table.insert(parts, "f filter")
    table.insert(parts, "r refresh")
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
    list_win_opts.footer = { { footer_for_list(), "SfFooter" } }
    list_win_opts.footer_pos = "left"
  end

  -- Define current_record early since get_view_title needs it
  local current_record_func
  current_record_func = function()
    if not session.list_window or not vim.api.nvim_win_is_valid(session.list_window) then
      return nil
    end
    local row = vim.api.nvim_win_get_cursor(session.list_window)[1]
    return records[row]
  end

  local get_view_title = function()
    -- Get the current org alias to display in the title
    -- If session.list_window is not yet set, use a placeholder
    if not session.list_window then
      return " Org "
    end
    local record = current_record_func()
    return record and (" " .. record.alias .. " ") or " Org "
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
    view_win_opts.footer = { { footer_for_view(), "SfFooter" } }
    view_win_opts.footer_pos = "left"
  end

  local list_window = vim.api.nvim_open_win(list_buffer, true, list_win_opts)
  local view_window = vim.api.nvim_open_win(view_buffer, false, view_win_opts)

  session.list_window = list_window
  session.view_window = view_window
  active_session = session

  vim.wo[list_window].cursorline = true
  -- Normally off (the view pane is a read-only display, not navigated) --
  -- but the logs view is an exception: a user moves focus here to place
  -- the cursor on a specific log line before pressing <CR> to download it,
  -- so a visible cursorline is needed to see which line that is.
  vim.wo[view_window].cursorline = true

  vim.api.nvim_win_set_option(
    list_window,
    "winhl",
    "Normal:SfNormal,FloatBorder:SfBorder,FloatTitle:SfTitle,FloatFooter:SfFooter,CursorLine:Visual"
  )
  vim.api.nvim_win_set_option(
    view_window,
    "winhl",
    "Normal:SfNormal,FloatBorder:SfBorder,FloatTitle:SfTitle,FloatFooter:SfFooter,WinBar:SfNormal,WinBarNC:SfNormal"
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
      cfg.footer = { { footer_for_view(), "SfFooter" } }
      cfg.footer_pos = "left"
    end
    vim.api.nvim_win_set_config(session.view_window, cfg)
  end

  -- Update the winbar with the current tab strip and highlights
  local update_tab_strip = function()
    if not vim.api.nvim_win_is_valid(session.view_window) then
      return
    end
    local winbar_text = dashboard_views.render_winbar(session.active_view_id)
    vim.wo[session.view_window].winbar = winbar_text
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
      -- Apply filter if this is the logs view
      local render_data = view_data
      if session.active_view_id == "logs" and session.filter_query then
        render_data = dashboard_views._filter_logs(view_data, session.filter_query)
      end

      -- Track the logs in rendered order for download mapping
      if session.active_view_id == "logs" then
        session.filtered_logs = render_data
      end

      lines, line_hls = view_desc.render(record, render_data)
    else
      lines = { "" }
      line_hls = { {} }
    end

    org_view.paint(session.view_buffer, lines, line_hls)
  end

  -- Fetch a view into cache without a spinner (used for prefetching background views).
  -- Returns immediately when cache already has data or a fetch is in-flight.
  -- on_painted is optional; prefetch uses it to selectively re-render only when
  -- safe (active view, matching record, valid window).
  local fetch_view_into_cache = function(record, view_id, on_painted)
    local cache_key = record.alias .. ":" .. view_id
    local cached = session.cache[cache_key]

    -- Cache hit or fetching: return immediately
    if cached and (cached.data or cached.fetching) then
      return
    end

    local view_desc = get_view_descriptor(view_id)
    if not view_desc then
      return
    end

    local current_gen = session.generation
    session.cache[cache_key] = { fetching = true, data = nil }

    view_desc.fetch(record, function(result, err)
      if current_gen ~= session.generation then
        return
      end
      session.cache[cache_key] = { fetching = false, data = result, err = err }
      if on_painted then
        on_painted()
      end
    end)
  end

  -- Prefetch all tab views for a record (used for background warming).
  -- Repaints only when all guards pass: active_view_id matches, record alias
  -- matches, and window is valid. No spinner is shown for prefetched views.
  -- ponytail: fixed 5 tab views fired at once; upgrade to concurrency cap
  -- or opt-out flag if registry grows large or metered-link users complain.
  local prefetch_record_views = function(record)
    for _, tab_desc in ipairs(dashboard_views.tab_views()) do
      fetch_view_into_cache(record, tab_desc.id, function()
        -- Only repaint if this view is now the active one, the record hasn't
        -- changed, and the window is still open.
        if
          tab_desc.id == session.active_view_id
          and record.alias == (current_record() or {}).alias
          and vim.api.nvim_win_is_valid(session.view_window)
        then
          paint_view(record, 0)
        end
      end)
    end
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

  -- current_record is already defined above as current_record_func
  local current_record = current_record_func

  local repaint_list = function()
    -- `session.list_buffer` is a *buffer* handle -- validate it with
    -- nvim_buf_is_valid, not nvim_win_is_valid (a buffer id is essentially
    -- never also a valid window id, so that check always failed silently).
    if not vim.api.nvim_buf_is_valid(session.list_buffer) then
      return
    end
    local list_lines, list_hls = org_view.render_list_lines(records)
    org_view.paint(session.list_buffer, list_lines, list_hls)
  end

  local on_cursor_move = function()
    local record = current_record()
    if record then
      show_view(record, session.active_view_id)
      -- Prefetch all other tabs for this record in the background
      prefetch_record_views(record)
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
    active_session = nil
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

  -- Refresh key: clears cache, bumps generation, re-runs fetch_org_list.
  -- Overlapping fetch-org-list calls now resolve via last-writer-wins in
  -- helpers.store_orgs (Phase 1 fix), so no additional in-flight guard is needed.
  vim.keymap.set("n", "r", function()
    rest_api.invalidate_org_display()
    session.cache = {}
    session.generation = session.generation + 1
    Org.fetch_org_list(function()
      repaint_list()
      local record = current_record()
      if record then
        show_view(record, session.active_view_id)
      end
    end)
  end, { buffer = session.list_buffer, nowait = true })

  -- Filter key (f) for logs view
  vim.keymap.set("n", "f", function()
    if session.active_view_id == "logs" then
      local query = vim.fn.input("Filter logs: ")
      session.filter_query = query and query ~= "" and query or nil
      local record = current_record()
      if record then
        paint_view(record, 0)
      end
    end
  end, { buffer = session.list_buffer, nowait = true })

  -- Tab cycling: factor the view-switch body so both registry keys and arrow keys use it
  local tab_switch_body = function(view_id)
    session.active_view_id = view_id
    update_view_title()
    update_tab_strip()
    session.filter_query = nil
    local record = current_record()
    if record then
      show_view(record, view_id)
    end
  end

  -- Cycle tabs with <Right> and <Left> (and h/l for vi mode)
  local cycle_tab = function(step)
    local tabs = dashboard_views.tab_views()
    if #tabs == 0 then
      return
    end
    local current_index = 1
    for i, view_desc in ipairs(tabs) do
      if view_desc.id == session.active_view_id then
        current_index = i
        break
      end
    end
    local next_index = ((current_index - 1 + step) % #tabs) + 1
    tab_switch_body(tabs[next_index].id)
  end

  vim.keymap.set("n", "<Right>", function()
    cycle_tab(1)
  end, { buffer = session.list_buffer, nowait = true })

  vim.keymap.set("n", "<Left>", function()
    cycle_tab(-1)
  end, { buffer = session.list_buffer, nowait = true })

  vim.keymap.set("n", "l", function()
    cycle_tab(1)
  end, { buffer = session.list_buffer, nowait = true })

  vim.keymap.set("n", "h", function()
    cycle_tab(-1)
  end, { buffer = session.list_buffer, nowait = true })

  -- Factor scroll logic into a helper for reuse with <C-d>/<C-u> and arrow keys
  local scroll_view_pane = function(normal_keys)
    if vim.api.nvim_win_is_valid(session.view_window) then
      vim.api.nvim_win_call(session.view_window, function()
        vim.cmd("normal! " .. normal_keys)
      end)
    end
  end

  -- Scroll view window with <C-d> and <C-u> (down/up half page)
  vim.keymap.set("n", "<C-d>", function()
    scroll_view_pane("\4")
  end, { buffer = session.list_buffer, nowait = true })

  vim.keymap.set("n", "<C-u>", function()
    scroll_view_pane("\21")
  end, { buffer = session.list_buffer, nowait = true })

  -- Arrow keys navigate the view pane (not the org list)
  -- <Up>/<Down> move cursor one line in the view window
  vim.keymap.set("n", "<Down>", function()
    scroll_view_pane("j")
  end, { buffer = session.list_buffer, nowait = true })

  vim.keymap.set("n", "<Up>", function()
    scroll_view_pane("k")
  end, { buffer = session.list_buffer, nowait = true })

  -- Download log on <CR> -- bound on the VIEW buffer, not the list buffer:
  -- the list buffer's cursor row indexes into `records` (which org), not
  -- into `session.filtered_logs` (which log). A user downloads a specific
  -- log by moving focus into the view pane (e.g. <C-w>w) and placing the
  -- cursor on that log's line, so nvim_win_get_cursor(session.view_window)
  -- is only meaningful there.
  -- Row 1 is the logs table's header (see dashboard_views.lua's logs
  -- view), so it's offset by one from `session.filtered_logs`.
  vim.keymap.set("n", "<CR>", function()
    if session.active_view_id ~= "logs" then
      return
    end
    local view_row = vim.api.nvim_win_get_cursor(session.view_window)[1] - 1
    if view_row > 0 and view_row <= #session.filtered_logs then
      local log_record = session.filtered_logs[view_row]
      local log_dir = util.get_plugin_folder_path() .. "logs/"
      Org.download_log(log_record.id, log_dir, function(path)
        util.try_open_file(path)
      end)
    end
  end, { buffer = session.view_buffer, nowait = true })

  -- Bind view selection keys and action keys
  for _, view_desc in ipairs(dashboard_views) do
    local view_key = view_desc.key
    local view_id = view_desc.id
    vim.keymap.set("n", view_key, function()
      local record = current_record()
      if record then
        -- Action-only entry: invoke the action immediately
        if vim.tbl_contains(dashboard_views.action_views(), view_desc) then
          local dashboard_api = {
            repaint_list = repaint_list,
          }
          view_desc.action(record, dashboard_api)
        else
          -- Fetch+render entry: show the view
          tab_switch_body(view_id)
        end
      end
    end, { buffer = session.list_buffer, nowait = true })
  end

  -- Attach helper functions to session so handle_tab_click can access them
  session.show_view = show_view
  session.current_record = current_record
  session.update_tab_strip = update_tab_strip

  -- Initialize the winbar with the current tab strip
  update_tab_strip()

  -- Eager warm-up: prefetch all views for default org + devhub (de-duplicated by alias).
  -- Skip if only one record (cursor-landed prefetch already covers it).
  if #records > 1 then
    local warmed_aliases = {}
    for _, record in ipairs(records) do
      if (record.is_default or record.is_default_devhub) and not warmed_aliases[record.alias] then
        warmed_aliases[record.alias] = true
        prefetch_record_views(record)
      end
    end
  end

  -- Fetch view for the first org
  on_cursor_move()

  -- Make sure focus is on the list window
  vim.api.nvim_set_current_win(session.list_window)
end

return dashboard
