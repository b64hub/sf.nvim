-- Split-pane org dashboard: left pane shows org list, right pane shows
-- details/actions for the selected org. Uses a generation counter, spinner
-- timer, and async detail fetching; stays open and re-renders the right pane
-- on cursor movement.

local util = require("sf.util")
local Icons = require("sf.ui.icons")
local Layout = require("sf.ui.layout")
local org_view = require("sf.ui.org_view")
local dashboard_views = require("sf.ui.dashboard_views")
local Org = require("sf.org")
local rest_api = require("sf.sub.rest_api")

local dashboard = {}

-- Singleton guard: hold the active session so only one dashboard instance
-- can be open at a time.
local active_session = nil

--- Repaint the org list pane if a dashboard is open, e.g. after a
--- background org-list refresh (helpers.orgs is mutated in place, so this
--- is the only thing an outside caller still needs to trigger by hand).
--- No-op when no dashboard is open or its window has since closed.
function dashboard.refresh_list()
  if active_session and vim.api.nvim_win_is_valid(active_session.list_window) then
    active_session.repaint_list()
  end
end

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

--- Navigate to `opts.view_id` (optionally for `opts.alias`), reusing the
--- dashboard session if one is already open instead of stacking a second
--- pair of floats, opening a fresh one otherwise. This is the one
--- entrypoint every "jump to dashboard at X" keymap/command should call -
--- see `sf.org`'s `Org.goto_dashboard` for the higher-level wrapper that
--- also resolves the org list first.
---@param records table[] org records, same shape `dashboard.open` takes;
---  only used when a new session needs to be created
---@param opts table { prompt = string|nil, view_id = string|nil, alias = string|nil }
function dashboard.navigate(records, opts)
  opts = opts or {}

  if active_session and vim.api.nvim_win_is_valid(active_session.list_window) then
    if opts.alias then
      active_session.select_alias(opts.alias)
    end
    if opts.view_id then
      active_session.switch_view(opts.view_id)
    end
    vim.api.nvim_set_current_win(active_session.list_window)
    return
  end

  dashboard.open(records, { prompt = opts.prompt, initial_view_id = opts.view_id, initial_alias = opts.alias })
end

--- Open a split-pane dashboard showing orgs on the left, details on the right.
---@param records table[] org records (alias, username, is_scratch, is_sandbox, is_prod, is_default, is_default_devhub, expiration_date)
---@param opts table { prompt = string, initial_view_id = string|nil, initial_alias = string|nil }
function dashboard.open(records, opts)
  if #records == 0 then
    return vim.notify("Sf: no orgs available. Run :SF org fetchList first.", vim.log.levels.WARN)
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
    active_view_id = opts.initial_view_id or "details", -- which view to show
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
    table.insert(parts, "D delete")
    table.insert(parts, "? help")
    return " " .. table.concat(parts, " · ") .. " "
  end

  -- Right pane (detail view) footer: misc/view-scoped actions plus
  -- dashboard-level keys that have no descriptor.
  local footer_for_view = function()
    local parts = {}
    for _, view_desc in ipairs(dashboard_views.action_views("right")) do
      table.insert(parts, view_desc.key .. " " .. view_desc.label)
    end
    if session.active_view_id == "logs" then
      table.insert(parts, "<CR> open")
      table.insert(parts, "D dl")
    end
    table.insert(parts, "f filter")
    table.insert(parts, "r refresh")
    table.insert(parts, "? help")
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
    return record and (" " .. Icons.CLOUD .. " " .. record.alias .. " ") or " Org "
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

  -- Move the list cursor onto `alias`'s row, if found; no-op otherwise
  -- (leaves the cursor wherever it already was). Shared by the initial-
  -- open jump below and `session.select_alias` (used to jump an
  -- already-open session, e.g. from `dashboard.navigate`).
  local jump_to_alias = function(alias)
    for row, record in ipairs(records) do
      if record.alias == alias then
        vim.api.nvim_win_set_cursor(list_window, { row, 0 })
        return
      end
    end
  end

  -- e.g. so `Org.goto_dashboard("logs")` lands on the current target_org's
  -- row instead of whatever happens to render first.
  if opts.initial_alias then
    jump_to_alias(opts.initial_alias)
  end

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

  -- Views whose fetch result is worth persisting to disk as a last-known-
  -- good snapshot, so the *next* nvim session can show it instantly while
  -- refreshing in the background instead of a spinner. Deliberately a
  -- positive list, not "everything except logs/trace_flags": logs and
  -- trace flags are excluded because they're expected to change constantly
  -- and a stale list is actively misleading, but any *new* tab added later
  -- should have to opt in too, not silently start caching to disk.
  local DISK_CACHEABLE_VIEWS = { details = true, limits = true, packages = true }

  local view_disk_cache_file = function(record, view_id)
    return string.format("dashboard_%s_%s.json", record.alias, view_id)
  end

  -- Only the "details" fetch can hand back a non-nil result that's still
  -- a total failure (it always calls back with err = nil to avoid
  -- blanking the pane on a partial failure -- see its fetch in
  -- dashboard_views.lua) -- guard against persisting that as if it were
  -- good data. Every other cacheable view already returns nil on error.
  local view_result_is_persistable = function(view_id, result)
    if view_id == "details" then
      return result.detail ~= nil
    end
    return true
  end

  -- Disk snapshot for a disk-cacheable view, or nil (both for views that
  -- never persist, and on any cache miss/read failure).
  local seed_from_disk = function(record, view_id)
    if not DISK_CACHEABLE_VIEWS[view_id] then
      return nil
    end
    return util.read_cache_json(view_disk_cache_file(record, view_id))
  end

  -- Shared "fetch landed" handling for show_view and fetch_view_into_cache:
  -- store the fresh result (persisting it if this view is disk-cacheable),
  -- or -- on a failed background refresh that already had seeded/stale
  -- data on screen -- keep showing that instead of blanking the pane.
  local settle_view_cache = function(record, view_id, cache_key, seed, result, err)
    if result then
      session.cache[cache_key] = { fetching = false, data = result, err = nil }
      if DISK_CACHEABLE_VIEWS[view_id] and view_result_is_persistable(view_id, result) then
        util.write_cache_json(view_disk_cache_file(record, view_id), result)
      end
    elseif seed then
      session.cache[cache_key] = { fetching = false, data = seed, err = nil }
    else
      session.cache[cache_key] = { fetching = false, data = nil, err = err }
    end
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
    local seed = seed_from_disk(record, view_id)
    session.cache[cache_key] = { fetching = true, data = seed }

    view_desc.fetch(record, function(result, err)
      if current_gen ~= session.generation then
        return
      end
      settle_view_cache(record, view_id, cache_key, seed, result, err)
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
          and record.alias == (current_record_func() or {}).alias
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

    -- Already fetching (e.g. a background prefetch beat us to it) and no
    -- data/seed to show yet: paint now so the spinner replaces whatever the
    -- previous tab left on screen, instead of leaving stale content up
    -- until this fetch happens to land. Don't start another fetch.
    if cached and cached.fetching then
      paint_view(record, 0)
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

    -- Seed from disk (if this view persists a snapshot) so the tab shows
    -- last-known-good data instantly instead of a spinner; the fetch below
    -- still runs and refreshes it in the background either way.
    local seed = seed_from_disk(record, view_id)
    session.cache[cache_key] = { fetching = true, data = seed }
    paint_view(record, frame)

    if not seed then
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
    end

    view_desc.fetch(record, function(result, err)
      if current_gen ~= session.generation then
        return
      end
      stop_spinner()
      settle_view_cache(record, view_id, cache_key, seed, result, err)
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

  -- Forward-declared: `close` below closes the help float too (if open),
  -- but the float itself is built lazily by `toggle_help` further down.
  local close_help

  local close = function()
    session.generation = session.generation + 1
    stop_spinner()
    close_help()
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

  -- "?" help overlay: the footers only have room for short labels (that
  -- was the whole point of shortening them), so this is where the full
  -- description for every key lives. Built from the same view registry
  -- the footers/winbar already draw from, plus the handful of keys that
  -- have no descriptor (scroll/cycle/logs/close) -- one source of truth,
  -- nothing to keep in sync by hand when a key changes.
  local help_window = nil

  close_help = function()
    if help_window and vim.api.nvim_win_is_valid(help_window) then
      vim.api.nvim_win_close(help_window, true)
    end
    help_window = nil
  end

  local build_help_lines = function()
    local lines = {}
    local add = function(key, desc)
      table.insert(lines, string.format("  %-18s %s", key, desc))
    end

    table.insert(lines, "Tabs")
    for _, view_desc in ipairs(dashboard_views.tab_views()) do
      add(view_desc.key, view_desc.label)
    end
    add("<Left>/<Right>, h/l", "Cycle tabs")
    table.insert(lines, "")

    table.insert(lines, "Org actions")
    for _, view_desc in ipairs(dashboard_views.action_views("left")) do
      add(view_desc.key, view_desc.help or view_desc.label)
    end
    add("D", "Delete org (scratch/sandbox only, asks to confirm)")
    table.insert(lines, "")

    table.insert(lines, "View actions")
    for _, view_desc in ipairs(dashboard_views.action_views("right")) do
      add(view_desc.key, view_desc.help or view_desc.label)
    end
    add("f", "Filter (logs view)")
    add("r", "Refresh org list")
    add("<C-d>/<C-u>", "Scroll view half page")
    add("<Up>/<Down>", "Scroll view one line")
    table.insert(lines, "")

    table.insert(lines, "Logs tab")
    add("<CR>", "Download log under cursor, open it, close dashboard")
    add("D", "Download log under cursor")
    table.insert(lines, "")

    table.insert(lines, "Other")
    add("?", "Toggle this help")
    add("q, <Esc>", "Close dashboard")

    return lines
  end

  local toggle_help = function()
    if help_window and vim.api.nvim_win_is_valid(help_window) then
      return close_help()
    end

    local lines = build_help_lines()
    local help_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(help_buffer, 0, -1, false, lines)
    vim.bo[help_buffer].modifiable = false
    vim.bo[help_buffer].filetype = "SfOrgDashboard"
    -- Toggled open/closed repeatedly within one dashboard session (unlike
    -- list_buffer/view_buffer, created once) -- wipe it on close instead
    -- of piling up an orphaned scratch buffer per toggle.
    vim.bo[help_buffer].bufhidden = "wipe"

    local width = 0
    for _, line in ipairs(lines) do
      width = math.max(width, #line)
    end
    width = math.min(width, vim.o.columns - 4)
    local height = math.min(#lines, vim.o.lines - 4)

    help_window = vim.api.nvim_open_win(help_buffer, true, {
      relative = "editor",
      row = math.floor((vim.o.lines - height - 2) / 2),
      col = math.floor((vim.o.columns - width - 2) / 2),
      width = width,
      height = height,
      style = "minimal",
      border = ui_config.border or "rounded",
      title = { { " Keys ", "SfTitle" } },
      title_pos = "left",
      zindex = 60,
    })
    vim.api.nvim_win_set_option(help_window, "winhl", "Normal:SfNormal,FloatBorder:SfBorder,FloatTitle:SfTitle")

    for _, key in ipairs({ "q", "<Esc>", "?" }) do
      vim.keymap.set("n", key, close_help, { buffer = help_buffer, nowait = true })
    end
  end

  vim.keymap.set("n", "?", toggle_help, { buffer = session.list_buffer, nowait = true })
  vim.keymap.set("n", "?", toggle_help, { buffer = session.view_buffer, nowait = true })

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

  -- Download the log under the cursor in the view pane's logs table.
  -- The cursor read is always `session.view_window`'s (that's what indexes
  -- into `session.filtered_logs`, not `records`), but the keymap itself is
  -- bound on BOTH buffers: the shared <Up>/<Down> handlers above already
  -- move the view pane's cursor without switching window focus away from
  -- the list, so a user picks a log with plain <Down>/<Up> and hits <CR>
  -- without ever needing <C-w>w - view-buffer-only left that common path
  -- silently doing nothing.
  -- Row 1 is the logs table's header (see dashboard_views.lua's logs
  -- view), so it's offset by one from `session.filtered_logs`.
  ---@param opts table { open = boolean, close = boolean }
  local download_selected_log = function(opts)
    if session.active_view_id ~= "logs" then
      return
    end
    local view_row = vim.api.nvim_win_get_cursor(session.view_window)[1] - 1
    if view_row <= 0 or view_row > #session.filtered_logs then
      return
    end
    local record = current_record()
    if not record then
      return
    end
    local log_record = session.filtered_logs[view_row]
    -- sfdx-conventional location, not the sf_cache plugin folder -- same
    -- place the replay debugger's local-log picker already looks, so a log
    -- downloaded here is immediately pickable for replay debugging too.
    local log_dir = util.get_sf_root() .. ".sfdx/tools/debug/logs/"

    -- Close *before* kicking off the download/open: the dashboard's list
    -- and view panes are minimal floats, not meant to host a real file --
    -- `util.try_open_file` does `:e!` in the current window, so closing
    -- first leaves the editor's own window current for it to land in,
    -- instead of clobbering the org list pane with log text.
    if opts.close then
      close()
    end

    -- Scoped to `record.alias`, not whatever the global target_org happens
    -- to be: without this, downloading while browsing a non-default org's
    -- logs tab silently fetched from the wrong org.
    Org.download_log(log_record.id, log_dir, function(path)
      if opts.open then
        util.try_open_file(path)
      end
    end, record.alias)
  end

  -- Delete the org under the list cursor (scratch orgs and sandboxes
  -- only) after an explicit y/N confirmation -- a destructive, no-undo
  -- action, so it never fires on a bare keypress. Shares the "D" key with
  -- download_selected_log below: the logs tab already claims "D" for
  -- "download log", so this only runs when some other tab is active.
  local delete_selected_org = function()
    local record = current_record()
    if not record then
      return
    end
    if not record.is_scratch and not record.is_sandbox then
      return util.show_err("Only scratch orgs and sandboxes can be deleted.")
    end

    local kind = record.is_scratch and "scratch org" or "sandbox"
    vim.ui.input({ prompt = string.format("Delete %s '%s'? (y/N): ", kind, record.alias) }, function(input)
      if input ~= "y" and input ~= "Y" then
        return
      end
      Org.delete_org(record, repaint_list)
    end)
  end

  -- <CR>: download + open + close (you're done browsing, you want to read
  -- this one log). D (capital -- lowercase "d" is already the "details"
  -- tab shortcut, registered below): download only, dashboard stays open,
  -- so multiple logs can be grabbed in one go without reopening the
  -- dashboard each time. Outside the logs tab, D deletes the selected org
  -- instead (see delete_selected_org above).
  for _, buffer in ipairs({ session.list_buffer, session.view_buffer }) do
    vim.keymap.set("n", "<CR>", function()
      download_selected_log({ open = true, close = true })
    end, { buffer = buffer, nowait = true })
    vim.keymap.set("n", "D", function()
      if session.active_view_id == "logs" then
        download_selected_log({ open = false, close = false })
      else
        delete_selected_org()
      end
    end, { buffer = buffer, nowait = true })
  end

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

  -- Attach helper functions to session so handle_tab_click (and
  -- dashboard.refresh_list) can access them
  session.show_view = show_view
  session.current_record = current_record
  session.repaint_list = repaint_list
  session.update_tab_strip = update_tab_strip
  session.switch_view = tab_switch_body
  -- Used by `dashboard.navigate` to jump an already-open session to a
  -- given org: move the list cursor onto that alias's row, then re-run the
  -- same fetch+render `on_cursor_move` does for any other cursor move.
  session.select_alias = function(alias)
    jump_to_alias(alias)
    on_cursor_move()
  end

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
