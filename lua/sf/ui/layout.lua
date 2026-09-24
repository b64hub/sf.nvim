-- Floating-window geometry for named corner positions, used by the
-- restyled SFTerm float (and, in a later phase, the progress widget).
-- Also provides a split-pane geometry helper for side-by-side floats.
local layout = {}

--- @return boolean
local function has_tabline()
  return vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
end

--- @param v number fraction (< 1) or absolute cell count (>= 1)
--- @param total number
--- @return number
local function resolve(v, total)
  if v >= 1 then
    return math.floor(v)
  end
  return math.floor(total * v)
end

--- Compute `{ row, col, width, height }` (content dimensions, border
--- excluded) for a named position, accounting for the tabline, the global
--- statusline and the command line, so the float never overlaps them.
--- @param opts table { position, width, height, margin = { row, col } }
--- @return table { row, col, width, height }
function layout.float_geometry(opts)
  local margin = opts.margin or {}
  local mrow = margin.row or 0
  local mcol = margin.col or 0

  local top_offset = has_tabline() and 1 or 0
  local bottom_offset = (vim.o.laststatus > 0 and 1 or 0) + vim.o.cmdheight

  local avail_cols = vim.o.columns
  local avail_rows = vim.o.lines - top_offset - bottom_offset

  local border_cells = 2 -- border consumes 1 cell on each side, per axis

  local width = math.max(resolve(opts.width, avail_cols) - border_cells, 1)
  local height = math.max(resolve(opts.height, avail_rows) - border_cells, 1)

  local position = opts.position or "bottom_right"
  local row, col

  if position == "center" then
    row = top_offset + math.floor((avail_rows - height - border_cells) / 2)
    col = math.floor((avail_cols - width - border_cells) / 2)
  else
    if position == "top_right" or position == "top_left" then
      row = top_offset + mrow
    else -- bottom_right, bottom_left
      row = top_offset + avail_rows - height - border_cells - mrow
    end

    if position == "top_left" or position == "bottom_left" then
      col = mcol
    else -- top_right, bottom_right
      col = avail_cols - width - border_cells - mcol
    end
  end

  return { row = row, col = col, width = width, height = height }
end

--- Row offset (in screen lines) for the nth (0-indexed) small float stacked
--- upward from a base corner position. Used by the progress widget so
--- several spinner handles can stack without overlapping.
--- @param n integer
--- @return integer
function layout.stack_offset(n)
  return n * 3 -- 1-line content + 2 border cells per stacked float
end

--- Split an outer box left/right into two adjacent bordered floats.
--- Both floats share the same row and height. The outer geometry is computed
--- once (respecting margins/position), then split horizontally accounting for
--- both floats' borders so they never overlap.
--- @param opts table { position, width, height, left_ratio = 0.3, margin = { row, col } }
--- @return table { left = {row,col,width,height}, right = {row,col,width,height} }
function layout.float_geometry_pair(opts)
  local left_ratio = opts.left_ratio or 0.3
  local outer = layout.float_geometry(opts)

  -- The outer box already has width/height as content dimensions (borders
  -- subtracted). When we split for two adjacent bordered floats, the right
  -- float's left border (1 cell) and the left float's right border (1 cell)
  -- consume 2 cells of the available width.
  local gap = 2 -- space consumed by the two adjacent borders
  local left_width = math.max(math.floor((outer.width - gap) * left_ratio), 1)
  local right_width = math.max(outer.width - gap - left_width, 1)

  return {
    left = {
      row = outer.row,
      col = outer.col,
      width = left_width,
      height = outer.height,
    },
    right = {
      row = outer.row,
      col = outer.col + left_width + gap,
      width = right_width,
      height = outer.height,
    },
  }
end

return layout
