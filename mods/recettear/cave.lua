-- recettear/cave.lua — side-view cave floors built from the game's own Mountain Cave tiles.
--
-- A floor is drawn on a grid of PIECES (64 px = 2 x 2 map cells).  The generator works on a solid / open grid; the
-- autotiler turns it into the three planes a Mountain Cave room uses (read from the game's own maps, DATA 1047..1066):
--   plane 0  the rock backdrop: piece 131002 (tile set 1450), frames 21 / 22 — everywhere
--   plane 1  decoration: 131021 (1470) stalagmites / stalactites
--   plane 2  the terrain: 131011 (1460).  A piece is black rock with its edge line on the open side(s); its collision
--            shape is fixed by the frame (retail's maps always pair them):
--                 open:  U       U+L  U+R   D       D+L  D+R   L          R          (diagonal only)
--                 frame: 2,16-19 1    3     8,20-22 9    7     11,28,29   5,24,25    UL 12, UR 4, DL 10, DR 6
--            interior 0.  `co` (cell word 0) = the tile's global id: per frame below (also from the game's maps).
-- Every rule here was read off the game's own rooms: for each terrain piece, which neighbours are open (tools: the
-- mod's dev notes in HANDOFF).  A solid region must be at least 2 pieces thick both ways (no piece open on two
-- opposite sides) — the generator below works on BLOCKS of 2 x 2 pieces, which guarantees it.
local M = {}

local T = 131011                                        -- terrain piece (tile set 1460)
local CO = { [0] = 6140, 6150, 6160, 6170, 6180, 6190, 6200, 6210, 6220, 6230, 6240, 6250, 6260,
             [16] = 6270, [17] = 6280, [18] = 6290, [19] = 6740, [20] = 6300, [21] = 6310, [22] = 6320,
             [24] = 6330, [25] = 6340, [28] = 6350, [29] = 6360 }
local SHAPE = { [0] = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, [16] = 2, [17] = 2, [18] = 2, [19] = 2,
                [20] = 8, [21] = 8, [22] = 8, [24] = 5, [25] = 5, [28] = 11, [29] = 11 }
local TOP, BOTTOM, LEFT, RIGHT = { 2, 2, 16, 17, 18, 19 }, { 8, 20, 21, 22 }, { 11, 28, 29 }, { 5, 24, 25 }
-- decoration (plane 1, piece 131021 / 1470): placed on the piece just above a floor (stalagmites) or on the last
-- ceiling piece (stalactites hang from it), as in the game's rooms
local DECO = { floor = { 13, 19, 27 }, ceil = { 8, 16, 24 } }
local DECO_CO = { [8] = 6390, [13] = 6440, [16] = 6470, [19] = 6500, [24] = 6520, [27] = 6550 }

local function pick(rng, t) return t[rng(1, #t)] end

-- grid: g[x][y] = true (rock), x 0..W-1, y 0..H-1 (pieces); outside = rock
function M.autotile(m, g, W, H, rng)
  local function solid(x, y) if x < 0 or y < 0 or x >= W or y >= H then return true end return g[x][y] end
  m.cols, m.rows = W * 2, H * 2
  m.cells = {}
  for i = 1, m.cols * m.rows * m.planes do m.cells[i] = { 0, 0, 0, 0, 0, 0, 0 } end
  local function put(z, py, px, piece, set, frame, shape, co) m:set_cell(z, py * 2, px * 2, { co, piece, set, frame, shape, 0, 0 }) end
  for x = 0, W - 1 do
    for y = 0, H - 1 do
      put(0, y, x, 131002, 1450, (rng(0, 2) == 0) and 21 or 22, 0, 0)   -- co filled below
      if g[x][y] then
        local u, d, l, r = not solid(x, y - 1), not solid(x, y + 1), not solid(x - 1, y), not solid(x + 1, y)
        local f
        if u and l then f = 1 elseif u and r then f = 3 elseif d and l then f = 9 elseif d and r then f = 7
        elseif u then f = pick(rng, TOP) elseif d then f = pick(rng, BOTTOM)
        elseif l then f = pick(rng, LEFT) elseif r then f = pick(rng, RIGHT)
        elseif not solid(x - 1, y - 1) then f = 12 elseif not solid(x + 1, y - 1) then f = 4
        elseif not solid(x - 1, y + 1) then f = 10 elseif not solid(x + 1, y + 1) then f = 6
        else f = 0 end
        put(2, y, x, T, 1460, f, SHAPE[f], CO[f])
      end
    end
  end
  for i = 1, #m.cells do                                 -- the backdrop's ids (frame 21 = 6070, 22 = 6080)
    local c = m.cells[i]
    if c[2] == 131002 then c[1] = c[4] == 21 and 6070 or 6080 end
  end
  -- decoration, sparingly
  for x = 1, W - 2 do
    for y = 1, H - 2 do
      if not g[x][y] and g[x][y + 1] and not g[x][y - 1] and rng(1, 7) == 1 then
        local f = pick(rng, DECO.floor)
        put(1, y, x, 131021, 1470, f, 0, DECO_CO[f])
      elseif g[x][y] and not g[x][y + 1] and g[x][y - 1] and not solid(x, y + 2) and rng(1, 6) == 1 then
        local f = pick(rng, DECO.ceil)
        put(1, y, x, 131021, 1470, f, 0, DECO_CO[f])
      end
    end
  end
end

-- ── the layout ───────────────────────────────────────────────────────────────────────────────────────────────────
-- A HEIGHTMAP of pieces: for each column x, the floor's first rock row h[x] and the ceiling's first open row c[x].
-- What keeps every piece drawable by the tile rules above, and every floor walkable by the party:
--   * floor and ceiling change only between RUNS at least 2 pieces wide (no rock 1 piece thick sideways)
--   * a floor step is at most 2 pieces (128 px: what a jump clears; 192 px does not — measured with Arche)
--   * headroom (h - c) at least 4 pieces (256 px), and rock at least 2 pieces thick above and below
-- The floor is a row of runs; a run is a stretch of level floor 2..7 pieces wide.  Some runs are "chambers" (tall),
-- some "tunnels" (low ceiling).  Returns g (g[x][y] = rock), W, H and the runs {x0, x1, h, c}.
--   opts: w, h (pieces), rng
function M.layout(opts)
  local rng, W, H = opts.rng, opts.w, opts.h
  local runs, x, floor = {}, 2, H - 3
  while x < W - 2 do
    local w = #runs == 0 and rng(5, 7) or rng(2, 7)
    if W - 2 - x - w < 6 then w = W - 2 - x end          -- the last run takes the rest: at least 6 wide
    if #runs > 0 then floor = math.max(7, math.min(H - 2, floor + ({ -2, -1, -1, 0, 0, 1, 1, 2 })[rng(1, 8)])) end
    local open = ({ 4, 4, 5, 5, 6, 7, 8 })[rng(1, 7)]
    local c = math.max(2, floor - open)
    runs[#runs + 1] = { x0 = x, x1 = x + w - 1, h = floor, c = c }
    x = x + w
  end
  -- the first and last runs (where the party arrives / leaves) are at least 5 / 6 wide
  local g = {}
  for cx = 0, W - 1 do g[cx] = {} for cy = 0, H - 1 do g[cx][cy] = true end end
  for _, r in ipairs(runs) do
    for cx = r.x0, r.x1 do for cy = r.c, r.h - 1 do g[cx][cy] = false end end
  end
  return g, W, H, runs
end

-- ── a whole floor ────────────────────────────────────────────────────────────────────────────────────────────────
-- template: a Mountain Cave room's Map (its header; its walk-in zone device, code 70101, becomes our gate 1).
-- Returns the Map and the floor's facts in px: gate {x, feet}, exit {x0, x1, feet} (the last run), runs.
function M.build(maps, template, opts)
  local rng = opts.rng
  local m = maps.parse(template:serialize())
  local g, W, H, runs = M.layout(opts)
  M.autotile(m, g, W, H, rng)
  local gate = template:find(function(o) return o.rec[5] == 70101 end)
  assert(gate, 'the template has no walk-in zone')
  local first, last = runs[1], runs[#runs]
  m.objs = {}
  local gz = maps.clone(gate)
  gz.rec[2], gz.rec[3] = (first.x0 + 1) * 64, first.h * 64 - 64
  gz.A[1] = 1
  m:add(gz)
  local info = { W = W, H = H, runs = runs, gate = { x = (first.x0 + 1) * 64, feet = first.h * 64 },
                 exit = { x0 = last.x0 * 64, x1 = (last.x1 + 1) * 64, cx = math.floor((last.x0 + last.x1) / 2) * 64 + 64, feet = last.h * 64 } }
  return m, info
end

return M
