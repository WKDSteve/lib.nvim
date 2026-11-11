-- TESTS/image_preview_cells_spec.lua — lib.nvim.image_preview.cells (cell selection -> pixel box)

return function(H)
  local eq = H.eq
  local cells = require("lib.nvim.image_preview.cells")

  local function same(box, x1, y1, x2, y2, msg)
    H.ok(box ~= nil, msg .. ": a box")
    eq(box.x1, x1, msg .. ": x1")
    eq(box.y1, y1, msg .. ": y1")
    eq(box.x2, x2, msg .. ": x2")
    eq(box.y2, y2, msg .. ": y2")
  end

  -- rect: corners in either order
  local r = cells.rect({ row = 6, col = 12 }, { row = 3, col = 5 })
  eq(r.row, 3, "rect: top row")
  eq(r.col, 5, "rect: left col")
  eq(r.h, 4, "rect: height in rows")
  eq(r.w, 8, "rect: width in cols")
  eq(cells.rect({ row = 2, col = 2 }, { row = 2, col = 2 }).w, 1, "rect: a single cell is 1 wide")

  -- to_pixels: image starts at cell (1,1), cell 10x20
  same(
    cells.to_pixels({ row = 1, col = 1, h = 1, w = 1 }, { w = 10, h = 20 }),
    0,
    0,
    9,
    19,
    "first cell"
  )
  same(
    cells.to_pixels({ row = 3, col = 5, h = 2, w = 3 }, { w = 10, h = 20 }),
    40,
    40,
    69,
    79,
    "inner block"
  )

  -- origin: the image starts at cell (2,4); cells before it clamp to 0
  same(
    cells.to_pixels(
      { row = 3, col = 5, h = 1, w = 1 },
      { w = 10, h = 20 },
      { origin = { row = 2, col = 4 } }
    ),
    10,
    20,
    19,
    39,
    "origin offset"
  )
  same(
    cells.to_pixels(
      { row = 1, col = 1, h = 2, w = 2 },
      { w = 10, h = 20 },
      { origin = { row = 2, col = 2 } }
    ),
    0,
    0,
    9,
    19,
    "a selection starting before the image clamps to its edge"
  )

  -- padding: whole cells on each side, clamped at 0 and at the bounds
  same(
    cells.to_pixels({ row = 3, col = 5, h = 2, w = 3 }, { w = 10, h = 20 }, { padding = 1 }),
    30,
    20,
    79,
    99,
    "padding of one cell"
  )
  same(
    cells.to_pixels({ row = 1, col = 1, h = 1, w = 1 }, { w = 10, h = 20 }, { padding = 2 }),
    0,
    0,
    29,
    59,
    "padding clamps at 0"
  )
  same(
    cells.to_pixels(
      { row = 1, col = 1, h = 1, w = 1 },
      { w = 10, h = 20 },
      { padding = -3, bounds = { w = 100, h = 100 } }
    ),
    0,
    0,
    9,
    19,
    "a negative padding counts as none"
  )

  -- bounds: clamped into the image; wholly outside is nil
  same(
    cells.to_pixels(
      { row = 1, col = 1, h = 50, w = 50 },
      { w = 10, h = 20 },
      { bounds = { w = 100, h = 60 } }
    ),
    0,
    0,
    99,
    59,
    "bounds clamp the far corner"
  )
  eq(
    cells.to_pixels(
      { row = 20, col = 20, h = 1, w = 1 },
      { w = 10, h = 20 },
      { bounds = { w = 100, h = 60 } }
    ),
    nil,
    "a box wholly outside the image is nil"
  )

  -- fractional cell size (a real terminal): the box still covers every pixel of the cells
  same(
    cells.to_pixels({ row = 1, col = 2, h = 1, w = 1 }, { w = 9.5, h = 18.25 }),
    9,
    0,
    18,
    18,
    "fractional cell"
  )

  -- unusable cell sizes
  eq(cells.to_pixels({ row = 1, col = 1, h = 1, w = 1 }, { w = 0, h = 10 }), nil, "zero width")
  eq(cells.to_pixels({ row = 1, col = 1, h = 1, w = 1 }, { w = 10 }), nil, "missing height")
  eq(cells.to_pixels({ row = 1, col = 1, h = 1, w = 1 }, nil), nil, "no cell size")
  eq(cells.to_pixels({ row = 1, col = 1, h = 1, w = 1 }, { w = 0 / 0, h = 10 }), nil, "NaN width")
end
