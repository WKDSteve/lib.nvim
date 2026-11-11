---@module 'lib.nvim.image_preview.cells'
--- Cell selection to pixel box: the pure geometry behind "mark a region of an
--- image drawn into a window and cut that region out of the original".
---
--- A terminal draws an image over a grid of character cells. A selection made
--- in that grid (a visual selection on a scratch buffer, a mouse drag) is in
--- cells; the original image is in pixels. The two are related by the size of
--- one cell and by where the image starts in the window. Everything here is
--- arithmetic: no editor calls, no terminal queries (the caller measures the
--- cell size, e.g. from `lib.nvim.terminal.capabilities` or CSI 16 t).
---
---```lua
--- local cells = require("lib.nvim.image_preview.cells")
--- local rect = cells.rect({ row = 3, col = 5 }, { row = 6, col = 12 })   -- 4 rows x 8 cols
--- local box  = cells.to_pixels(rect, { w = 9, h = 18 }, { padding = 1, bounds = { w = 1920, h = 1080 } })
--- -- box = { x1, y1, x2, y2 } inclusive pixel corners in the original image
---```
---
--- Positions are 1-based (row, col), the way `vim.fn.getpos` and
--- `nvim_win_get_cursor` count (the latter's col is 0-based: add 1).

local M = {}

---@class Lib.ImagePreview.Pos
---@field row integer 1-based row
---@field col integer 1-based column

---@class Lib.ImagePreview.CellRect
---@field row integer 1-based top row
---@field col integer 1-based left column
---@field h integer height in rows (>= 1)
---@field w integer width in columns (>= 1)

---@class Lib.ImagePreview.PixelBox
---@field x1 integer left, inclusive
---@field y1 integer top, inclusive
---@field x2 integer right, inclusive
---@field y2 integer bottom, inclusive

---Normalized rectangle spanning two corner positions, in either order. This is
---also what a blockwise visual selection is (`getpos("v")` and `getpos(".")`);
---for a charwise or linewise selection pass the corners the user means.
---@param a Lib.ImagePreview.Pos
---@param b Lib.ImagePreview.Pos
---@return Lib.ImagePreview.CellRect
function M.rect(a, b)
  local row1, row2 = math.min(a.row, b.row), math.max(a.row, b.row)
  local col1, col2 = math.min(a.col, b.col), math.max(a.col, b.col)
  return { row = row1, col = col1, h = row2 - row1 + 1, w = col2 - col1 + 1 }
end

---Convert a cell rectangle to an inclusive pixel box.
---
---`opts.origin` is the cell (row, col) of the image's top-left corner inside
---the same grid (default 1,1: the image starts at the first cell). Cells left
---of or above the image clamp to its edge. `opts.padding` widens the box by that
---many cells on each side (a safety margin, e.g. around a redaction; a
---non-number or negative value counts as none). `opts.bounds` is the image size
---in pixels; the box is clamped into it. Without bounds only the top-left is
---clamped (to 0).
---@param rect Lib.ImagePreview.CellRect
---@param cell { w: number, h: number } pixel size of one cell
---@param opts? { origin?: Lib.ImagePreview.Pos, padding?: number, bounds?: { w: integer, h: integer } }
---@return Lib.ImagePreview.PixelBox|nil box nil when the cell size is unusable or the box falls outside `bounds`
function M.to_pixels(rect, cell, opts)
  opts = opts or {}
  if
    type(cell) ~= "table"
    or type(cell.w) ~= "number"
    or type(cell.h) ~= "number"
    or cell.w ~= cell.w
    or cell.h ~= cell.h
    or cell.w <= 0
    or cell.h <= 0
  then
    return nil
  end

  local padding = opts.padding
  if type(padding) ~= "number" or padding ~= padding or padding < 0 then
    padding = 0
  end
  local origin = opts.origin or { row = 1, col = 1 }

  local pad_x = math.ceil(padding * cell.w)
  local pad_y = math.ceil(padding * cell.h)
  local x1 = math.floor((rect.col - origin.col) * cell.w) - pad_x
  local y1 = math.floor((rect.row - origin.row) * cell.h) - pad_y
  local x2 = math.ceil((rect.col - origin.col + rect.w) * cell.w) - 1 + pad_x
  local y2 = math.ceil((rect.row - origin.row + rect.h) * cell.h) - 1 + pad_y

  x1, y1 = math.max(0, x1), math.max(0, y1)
  if opts.bounds then
    x2 = math.min(opts.bounds.w - 1, x2)
    y2 = math.min(opts.bounds.h - 1, y2)
    if x1 > x2 or y1 > y2 then
      return nil -- the selection lies wholly outside the image
    end
  end
  return { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
end

return M
