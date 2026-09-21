-- Floating-window geometry for named corner positions, used by the
-- restyled SFTerm float (and, in a later phase, the progress widget).
local M = {}

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
function M.float_geometry(opts)
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
function M.stack_offset(n)
  return n * 3 -- 1-line content + 2 border cells per stacked float
end

return M
