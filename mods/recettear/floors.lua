-- recettear/floors.lua — the Hall of Trials' floors: a maze of chambers, seen from the side, built from the game's tiles.
--
-- Recettear's Hall is a maze carved on a grid of rooms (a recursive backtracker, new on every visit).  Here the same
-- maze stands upright: a grid of CHAMBERS, neighbours joined by a doorway (sideways) or by a SHAFT (up / down) the
-- party climbs on jump-through ledges and drops back down.  Two looks, both read off the game's own rooms:
--   'hall'  the grey brick ruins (DATA 1057..1066): 32 px cells — terrain 121001, brick backdrop 11001 with lighter
--           panels 11000, a frieze and reliefs 11060, pillars 11050, ledges 11211 (a one-way cell), a door 11310
--   'cave'  the Mountain Cave (DATA 1047..1056): 64 px pieces — terrain 131011, the lit wall 131001 over dark rock
--           131002, columns / stalactites 131021, plank ledges 131004 (one-way), the arch 131041
-- The layout is made on a grid of PIECES (64 px) for both: g[x][y] = rock.  Every rock region is at least 2 pieces
-- thick where it could be seen from two opposite sides (the tile sets have no piece for thinner rock).
--
-- Where things stand (measured in the game's rooms, not guessed):
--   hall: the floor's surface is the top of its cell row.  cave: the surface is 32 px INSIDE the top piece (a piece's
--   rock is its inner half: shapes 2 / 8 / 5 / 11), so the arch, the stalagmites and everything else stand at
--   piece top + 32, and what hangs from a ceiling starts 32 px up inside the ceiling piece.
local M = {}

M.CW, M.CH, M.WALL = 12, 7, 2          -- a chamber's pitch in pieces (interior 10 x 5), the rock between two chambers
local CW, CH, WALL = M.CW, M.CH, M.WALL
local IW, IH = CW - WALL, CH - WALL
local SHAFT_W = 4                       -- a shaft's width (pieces): two ledges of 2 side by side
local DOOR_H = 3                        -- a doorway's height (pieces)
-- A shaft's ledges rise 1 piece (64 px) each.  Arche's jump, measured on the SE: 59 px with the key held 28 frames,
-- 79 px at 40, 106 px at 60 — a 96 px rise needs nearly the whole jump every time, 128 px cannot be made.
local LEDGE_RISE = 1

local function pick(rng, t) return t[rng(1, #t)] end
local function shuffle(rng, t) for i = #t, 2, -1 do local j = rng(1, i) t[i], t[j] = t[j], t[i] end return t end

-- ── the maze ─────────────────────────────────────────────────────────────────────────────────────────────────────
-- nc x nr chambers; ch.link = {L=, R=, U=, D=} (the neighbour chamber or nil); start / exit: the two ends of the
-- longest way through.  Returns chambers (list; ch.c, ch.r, ch.order = carve order), start, exit.
local DIRS = { L = { -1, 0, 'R' }, R = { 1, 0, 'L' }, U = { 0, -1, 'D' }, D = { 0, 1, 'U' } }
function M.maze(nc, nr, rng)
  local at, list = {}, {}
  for r = 0, nr - 1 do for c = 0, nc - 1 do
    local ch = { c = c, r = r, link = {} }
    at[c .. ',' .. r] = ch
    list[#list + 1] = ch
  end end
  local function nb(ch, d) local v = DIRS[d] return at[(ch.c + v[1]) .. ',' .. (ch.r + v[2])] end
  local order = 0
  local function carve(ch)
    order = order + 1
    ch.order = order
    -- sideways first more often than not: long vertical runs of shafts are tiring
    local ds = shuffle(rng, { 'L', 'R', 'U', 'D' })
    if rng(1, 3) > 1 then table.sort(ds, function(a, b) return (a == 'L' or a == 'R') and not (b == 'L' or b == 'R') end) end
    for _, d in ipairs(ds) do
      local o = nb(ch, d)
      if o and not o.order then
        ch.link[d], o.link[DIRS[d][3]] = o, ch
        carve(o)
      end
    end
  end
  local first = at['0,' .. rng(0, nr - 1)]
  carve(first)
  -- one more doorway where two neighbours are not joined (a loop: more than one way round), on the larger floors
  if #list >= 6 then
    local cand = {}
    for _, ch in ipairs(list) do
      local o = nb(ch, 'R')
      if o and not ch.link.R then cand[#cand + 1] = ch end
    end
    if #cand > 0 then
      local ch = pick(rng, cand)
      local o = nb(ch, 'R')
      ch.link.R, o.link.L = o, ch
    end
  end
  local function far(from)                               -- the farthest chamber from `from` (steps through links)
    local dist, q, best = { [from] = 0 }, { from }, from
    local i = 1
    while q[i] do
      local ch = q[i]
      i = i + 1
      for _, o in pairs(ch.link) do
        if not dist[o] then
          dist[o] = dist[ch] + 1
          q[#q + 1] = o
          if dist[o] > dist[best] then best = o end
        end
      end
    end
    return best, dist
  end
  local a = far(first)
  local b, dist = far(a)
  -- the party comes in low and to the left when it can: of the two ends, start at the lower / more leftward one
  if (b.r > a.r) or (b.r == a.r and b.c < a.c) then a, b = b, a; local _; _, dist = far(a) end
  for _, ch in ipairs(list) do ch.dist = dist[ch] or 0 end
  return list, a, b
end

-- ── the rock ─────────────────────────────────────────────────────────────────────────────────────────────────────
-- Carves the chambers, doorways and shafts into a solid grid.  Each chamber gets:
--   x0, y0 (its interior's first piece), floor (the piece row of its floor), up / down = the shaft's first column
--   (pieces) through its ceiling / floor, used[i] (interior column i taken: a doorway's landing, a shaft), dais
function M.carve(list, nc, nr, rng, opts)
  local W, H = nc * CW + WALL, nr * CH + WALL
  local g = {}
  for x = 0, W - 1 do g[x] = {} for y = 0, H - 1 do g[x][y] = true end end
  for _, ch in ipairs(list) do
    ch.x0, ch.y0 = WALL + ch.c * CW, WALL + ch.r * CH
    ch.floor = ch.y0 + IH
    ch.used = {}
    for x = ch.x0, ch.x0 + IW - 1 do for y = ch.y0, ch.floor - 1 do g[x][y] = false end end
  end
  for _, ch in ipairs(list) do
    if ch.link.R then                                    -- a doorway through the wall to the right
      for x = ch.x0 + IW, ch.x0 + CW - 1 do for y = ch.floor - DOOR_H, ch.floor - 1 do g[x][y] = false end end
      ch.used[IW - 1], ch.used[IW - 2] = true, true
      ch.link.R.used[0], ch.link.R.used[1] = true, true
    end
    if ch.link.D then                                    -- a shaft down: left or right half, by the row
      local o = ch.link.D
      local off = ((ch.r + ch.c) % 2 == 0) and 1 or (IW - SHAFT_W - 1)
      ch.down, o.up = ch.x0 + off, ch.x0 + off
      for x = ch.down, ch.down + SHAFT_W - 1 do
        for y = ch.floor, ch.floor + WALL - 1 do g[x][y] = false end
        ch.used[x - ch.x0], o.used[x - ch.x0] = true, true
      end
    end
  end
  -- a raised step (a dais) in some chambers: 1 piece high, 2..4 wide, on free floor; never the start's or the exit's
  for _, ch in ipairs(list) do
    if not ch.plain and rng(1, 100) <= (opts.dais or 45) then
      local runs, a = {}, nil
      for i = 2, IW - 2 do                                -- (columns 0, 1, IW-2, IW-1 stay level: where doors land)
        local free = i <= IW - 3 and not ch.used[i]
        -- (two clear columns beside a shaft's mouth: its last ledge is 64 px under the floor, a dais would add to it)
        if ch.down and ch.x0 + i >= ch.down - 2 and ch.x0 + i <= ch.down + SHAFT_W + 1 then free = false end
        if free and not a then a = i end
        if not free and a then if i - a >= 2 then runs[#runs + 1] = { a, i - 1 } end a = nil end
      end
      if #runs > 0 then
        local r = pick(rng, runs)
        local w = math.min(r[2] - r[1] + 1, rng(2, 4))
        local s = r[1] + rng(0, r[2] - r[1] + 1 - w)
        ch.dais = { s, s + w - 1 }
        if opts.dais_rock then for i = s, s + w - 1 do g[ch.x0 + i][ch.floor - 1] = true end end
      end
    end
  end
  -- (the cave) the ceiling hangs lower over a stretch or two: 1 piece, at least 2 wide, never over a shaft's mouth
  if opts.bulges then
    for _, ch in ipairs(list) do
      local i = rng(0, 3)
      while i < IW - 1 do
        local w = rng(2, 4)
        if i + w > IW then w = IW - i end
        local ok = w >= 2 and rng(1, 100) <= opts.bulges
        for k = i, i + w - 1 do
          if ch.up and ch.x0 + k >= ch.up - 1 and ch.x0 + k <= ch.up + SHAFT_W then ok = false end
        end
        if ok then
          for k = i, i + w - 1 do g[ch.x0 + k][ch.y0] = true end
          ch.low = ch.low or {}
          for k = i, i + w - 1 do ch.low[k] = true end
        end
        i = i + w + rng(1, 3)
      end
    end
  end
  return g, W, H
end

local function on_dais(ch, i) return ch.dais and i >= ch.dais[1] and i <= ch.dais[2] end
-- (the cave) the floor's piece row under interior column i of a chamber: a dais is one higher
local function floor_at(ch, i) return on_dais(ch, i) and ch.floor - 1 or ch.floor end
M.on_dais = on_dais

-- ── themes ───────────────────────────────────────────────────────────────────────────────────────────────────────
local function blank(m, W, H)
  m.cols, m.rows = W * 2, H * 2
  m.cells = {}
  for i = 1, m.cols * m.rows * m.planes do m.cells[i] = { 0, 0, 0, 0, 0, 0, 0 } end
end
local function put(m, z, cy, cx, co, piece, set, frame, shape)
  if cx < 0 or cy < 0 or cx >= m.cols or cy >= m.rows then return end
  m:set_cell(z, cy, cx, { co, piece, set, frame, shape or 0, 0, 0 })
end
local function clear(m, z, cy, cx)
  if cx < 0 or cy < 0 or cx >= m.cols or cy >= m.rows then return end
  m:set_cell(z, cy, cx, { 0, 0, 0, 0, 0, 0, 0 })
end

-- The frame ↔ open-side convention is the same for the cave terrain, the cave's lit wall and the brick terrain:
--   1 2 3     open up-left / up / up-right        12 . 4    (only a diagonal open: the inner corners)
--   11 0 5    left / none / right                 .  0 .
--   9 8 7     down-left / down / down-right       10 . 6
local function edge_frame(u, d, l, r, ul, ur, dl, dr, var, rng)
  if u and l then return 1 elseif u and r then return 3 elseif d and l then return 9 elseif d and r then return 7
  elseif u then return pick(rng, var.U) elseif d then return pick(rng, var.D)
  elseif l then return pick(rng, var.L) elseif r then return pick(rng, var.R)
  elseif ul then return 12 elseif ur then return 4 elseif dl then return 10 elseif dr then return 6 end
  return pick(rng, var.C)
end

-- ·· the cave ··
local CAVE = {}
local C_T = { U = { 2, 2, 16, 17, 18, 19 }, D = { 8, 20, 21, 22 }, L = { 11, 28, 29 }, R = { 5, 24, 25 }, C = { 0 } }
local C_T_CO = { [0] = 6140, 6150, 6160, 6170, 6180, 6190, 6200, 6210, 6220, 6230, 6240, 6250, 6260,
                 [16] = 6270, [17] = 6280, [18] = 6290, [19] = 6740, [20] = 6300, [21] = 6310, [22] = 6320,
                 [24] = 6330, [25] = 6340, [28] = 6350, [29] = 6360 }
local C_T_SHAPE = { [0] = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, [16] = 2, [17] = 2, [18] = 2, [19] = 2,
                    [20] = 8, [21] = 8, [22] = 8, [24] = 5, [25] = 5, [28] = 11, [29] = 11 }
local C_W = { U = { 2, 24, 25 }, D = { 8, 28, 29 }, L = { 11 }, R = { 5 }, C = { 0, 0, 0, 16, 17 } }   -- the lit wall
local C_W_CO = { [16] = 6040, [17] = 6050, [24] = 6100, [25] = 6110, [28] = 6120, [29] = 6130 }
for f = 0, 12 do C_W_CO[f] = 5910 + 10 * f end
local function deco_co(f) return (f >= 24 and 6280 or 6310) + 10 * f end
CAVE.surface = 32                                        -- px from a floor piece's top to where feet stand
CAVE.torch_up, CAVE.dais_h, CAVE.dais_rock, CAVE.bulges = 176, 64, true, 30

function CAVE.paint(m, g, W, H, list, rng)
  local function solid(x, y) if x < 0 or y < 0 or x >= W or y >= H then return true end return g[x][y] end
  local function open(x, y) return not solid(x, y) end
  for x = 0, W - 1 do for y = 0, H - 1 do
    if g[x][y] then
      local dark = rng(0, 2) == 0 and 21 or 22
      put(m, 0, y * 2, x * 2, dark == 21 and 6070 or 6080, 131002, 1450, dark, 0)
      local f = edge_frame(open(x, y - 1), open(x, y + 1), open(x - 1, y), open(x + 1, y),
                           open(x - 1, y - 1), open(x + 1, y - 1), open(x - 1, y + 1), open(x + 1, y + 1), C_T, rng)
      put(m, 2, y * 2, x * 2, C_T_CO[f], 131011, 1460, f, C_T_SHAPE[f])
    else                                                 -- the lit wall, shaded where it meets the rock
      local f = edge_frame(solid(x, y - 1), solid(x, y + 1), solid(x - 1, y), solid(x + 1, y), false, false, false, false, C_W, rng)
      put(m, 0, y * 2, x * 2, C_W_CO[f], 131001, 1450, f, 0)
    end
  end end
  -- decoration (plane 1, one cell lower than the piece grid: 32 px inside the ceiling / floor piece).  The game's
  -- columns: a head under the ceiling, a shaft per piece, a foot on the floor — three kinds (8 9.. 13 / 16 17.. 19 /
  -- 24 25.. 27); hanging: 1 alone, 16 18, 24 26; standing: 0 alone, 28 27.
  local function deco(px, py, f) put(m, 1, py * 2 + 1, px * 2, deco_co(f), 131021, 1470, f, 0) end
  for _, ch in ipairs(list) do
    local taken = {}
    for i = 0, IW - 1 do taken[i] = ch.used[i] or (ch.dais and i >= ch.dais[1] - 1 and i <= ch.dais[2] + 1) or ch.keep and ch.keep[i] end
    local function top_at(i) return (ch.low and ch.low[i]) and ch.y0 or ch.y0 - 1 end   -- the ceiling's piece row
    local n = 0
    for i = 1, IW - 2 do
      if not taken[i] and not taken[i - 1] and n < 2 and rng(1, 9) == 1 then        -- a column, ceiling to floor
        local k = pick(rng, { { 8, 9, 13 }, { 16, 17, 19 }, { 24, 25, 27 } })
        local top = top_at(i)
        deco(ch.x0 + i, top, k[1])
        for y = top + 1, ch.floor - 2 do deco(ch.x0 + i, y, k[2]) end
        deco(ch.x0 + i, ch.floor - 1, k[3])
        taken[i], n = true, n + 1
      end
    end
    for i = 0, IW - 1 do
      local mouth = ch.up and ch.x0 + i >= ch.up and ch.x0 + i < ch.up + SHAFT_W
      if not mouth and not taken[i] or (ch.used[i] and not mouth and not (ch.keep and ch.keep[i])) then
        local r, top = rng(1, 12), top_at(i)              -- hanging (never under a shaft's mouth)
        if r == 1 then deco(ch.x0 + i, top, 1)
        elseif r == 2 then deco(ch.x0 + i, top, 16) deco(ch.x0 + i, top + 1, 18)
        elseif r == 3 then deco(ch.x0 + i, top, 24) deco(ch.x0 + i, top + 1, 26) end
      end
      if not taken[i] then                                -- standing
        local r = rng(1, 12)
        local fl = floor_at(ch, i)
        if r == 1 then deco(ch.x0 + i, fl - 1, 0)
        elseif r == 2 then deco(ch.x0 + i, fl - 2, 28) deco(ch.x0 + i, fl - 1, 27) end
      end
    end
  end
end
-- a one-way plank: the wall piece with a wooden ledge (131004), 64 px wide, feet 32 px below the piece's top
function CAVE.ledge(m, px, py) put(m, 0, py * 2, px * 2, 7400, 131004, 1450, 15, 0) end
-- the arch (131041 frame 2: 128 x 160 px, its cells left empty under it), standing on the surface at piece row `fl`
function CAVE.door(m, px, fl, kind)
  local cx, cy = px * 2, fl * 2 + 1 - 5
  for y = cy, cy + 4 do for x = cx, cx + 3 do clear(m, 0, y, x) end end
  for y = cy - 1, cy + 5 do for x = cx - 2, cx + 5 do clear(m, 1, y, x) end end
  put(m, 0, cy, cx, 6640, 131041, 1480, 2, 0)
end

-- ·· the brick hall ··
local HALL = {}
local H_T = { U = { 2, 2, 16, 17 }, D = { 8, 18, 19 }, L = { 11, 22, 23 }, R = { 5, 20, 21 }, C = { 0 } }
local H_T_CO = { [16] = 5400, [17] = 5410, [18] = 5420, [19] = 5430, [20] = 5790, [21] = 5800, [22] = 5810, [23] = 5820 }
for f = 0, 12 do H_T_CO[f] = 5270 + 10 * f end
local H_T_SHAPE = { [7] = 1, [8] = 1, [9] = 1, [18] = 1, [19] = 1 }     -- (the game's rooms: every under-side frame)
local H_B_CO = { [16] = 1470, [17] = 1430, [18] = 1480, [19] = 5480 }   -- brick backdrop 11001
local H_P_CO = { [20] = 1440, [21] = 1450, [22] = 1460, [23] = 5490 }   -- panel 11000
for f = 0, 12 do H_P_CO[f] = 1300 + 10 * f end
HALL.surface = 0
HALL.torch_up, HALL.dais_h = 144, 32            -- (a dais here: one cell of masonry on the floor, painted below)

function HALL.paint(m, g, W, H, list, rng)
  local cw, chh = W * 2, H * 2
  local step = {}                                        -- the daises: one cell high
  for _, ch in ipairs(list) do
    if ch.dais then
      for cx = (ch.x0 + ch.dais[1]) * 2, (ch.x0 + ch.dais[2]) * 2 + 1 do step[cx .. ',' .. (ch.floor * 2 - 1)] = true end
    end
  end
  local function solid(cx, cy)
    if cx < 0 or cy < 0 or cx >= cw or cy >= chh then return true end
    return g[math.floor(cx / 2)][math.floor(cy / 2)] or step[cx .. ',' .. cy] or false
  end
  local function open(cx, cy) return not solid(cx, cy) end
  for cx = 0, cw - 1 do for cy = 0, chh - 1 do
    if solid(cx, cy) then
      local f = edge_frame(open(cx, cy - 1), open(cx, cy + 1), open(cx - 1, cy), open(cx + 1, cy),
                           open(cx - 1, cy - 1), open(cx + 1, cy - 1), open(cx - 1, cy + 1), open(cx + 1, cy + 1), H_T, rng)
      put(m, 2, cy, cx, H_T_CO[f], 121001, 1230, f, H_T_SHAPE[f] or 0)
      if f ~= 0 then local b = rng(16, 19) put(m, 0, cy, cx, H_B_CO[b], 11001, 1040, b, 0) end
    else
      local b = rng(16, 19)
      put(m, 0, cy, cx, H_B_CO[b], 11001, 1040, b, 0)
    end
  end end
  for _, ch in ipairs(list) do
    local x0, y0, x1, y1 = ch.x0 * 2, ch.y0 * 2, (ch.x0 + IW) * 2 - 1, ch.floor * 2 - 1     -- the interior, in cells
    -- lighter panels set into the wall (11000, framed by its own edge pieces): one or two per chamber
    local function panel(a, b, top, bot)
      for cx = a, b do for cy = top, bot do
        local f
        local l, r, u, d = cx == a, cx == b, cy == top, cy == bot
        if u and l then f = 1 elseif u and r then f = 3 elseif d and l then f = 9 elseif d and r then f = 7
        elseif u then f = 2 elseif d then f = 8 elseif l then f = 11 elseif r then f = 5
        else f = pick(rng, { 0, 0, 0, 20, 21, 22, 23 }) end
        if open(cx, cy) then put(m, 0, cy, cx, H_P_CO[f], 11000, 1040, f, 0) end
      end end
    end
    local style = rng(1, 3)
    if style == 1 then
      panel(x0 + 3, x1 - 3, y0 + 4, y1 - 1)
    elseif style == 2 then
      panel(x0 + 2, x0 + 7, y0 + 4, y1 - 1)
      panel(x1 - 7, x1 - 2, y0 + 4, y1 - 1)
    end
    -- a frieze under the ceiling (11060 frames 12..17: 64 x 64 pieces), broken by the shaft's mouth
    for cx = x0, x1 - 1, 2 do
      local px = math.floor(cx / 2)
      if not (ch.up and px >= ch.up and px < ch.up + SHAFT_W) then
        local f = rng(12, 17)
        put(m, 0, y0 + 1, cx, 5510 + 10 * (f - 12), 11060, 1070, f, 0)
        clear(m, 0, y0 + 1, cx + 1) clear(m, 0, y0 + 2, cx) clear(m, 0, y0 + 2, cx + 1)
      end
    end
    -- pillars (plane 1, 11050: capital 2, shaft 1, base 0 — some under ivy: 52 56 .. / .. 55 54), ceiling to floor
    local taken = {}
    for i = 0, IW - 1 do taken[i] = ch.used[i] or (ch.dais and i >= ch.dais[1] and i <= ch.dais[2]) or ch.keep and ch.keep[i] end
    local spots = {}
    for _, i in ipairs { 2, IW - 3, 4, IW - 5 } do if not taken[i] then spots[#spots + 1] = i end end
    for k = 1, math.min(#spots, rng(0, 2)) do
      local i = spots[k]
      local cx, n = (ch.x0 + i) * 2, IH
      local ivy = rng(1, 3)
      for j = 0, n - 1 do
        local f = j == 0 and 2 or (j == n - 1 and 0 or 1)
        if ivy == 1 then f = j == 0 and 52 or (j == 1 and 56 or f)
        elseif ivy == 2 then f = j == n - 1 and 54 or (j == n - 2 and 55 or f) end
        local co = f < 4 and 1730 + 10 * f or 14390 + 10 * (f - 52)
        put(m, 1, y0 + 2 * j, cx, co, 11050, 1420, f, 0)
      end
      taken[i] = true
    end
    -- a relief or a brazier niche on a free stretch of wall (11060: 1 eye, 2 dragons, 4 niche, 5 brazier)
    for i = 3, IW - 4 do
      if not taken[i] and not taken[i + 1] and rng(1, 10) == 1 then
        local f = pick(rng, { 1, 2, 4, 5 })
        local cx, cy = (ch.x0 + i) * 2, y0 + 4
        put(m, 0, cy, cx, ({ [1] = 6800, [2] = 6810, [4] = 1770, [5] = 6820 })[f], 11060, 1070, f, 0)
        clear(m, 0, cy, cx + 1) clear(m, 0, cy + 1, cx) clear(m, 0, cy + 1, cx + 1)
        taken[i], taken[i + 1] = true, true
      end
    end
  end
end
-- a one-way ledge: 11211 (a single 32 px cell of stone shelf), two side by side per piece
function HALL.ledge(m, px, py)
  local cy = py * 2
  for cx = px * 2, px * 2 + 1 do put(m, 0, cy, cx, 9020, 11211, 1040, 25, 0) end
end
-- a doorway in the back wall (11310: 128 x 128 px; frame 2 a wooden door, 0 stairs up, 1 stairs down)
function HALL.door(m, px, fl, kind)
  local cx, cy = px * 2, fl * 2 - 4
  for y = cy, cy + 3 do for x = cx, cx + 3 do clear(m, 0, y, x) end end
  for y = cy - 1, cy + 3 do for x = cx - 2, cx + 5 do clear(m, 1, y, x) end end
  put(m, 0, cy, cx, 3080 + 10 * kind, 11310, 1240, kind, 0)
end
M.themes = { cave = CAVE, hall = HALL }

-- ── a whole floor ────────────────────────────────────────────────────────────────────────────────────────────────
-- template: a room's Map (its header; its walk-in zone device, code 70101, becomes our gate 1).
-- opts: nc, nr (chambers), theme ('hall' | 'cave'), rng, dais (% of chambers with a raised step), way (the far
-- archway in a hall: 1 = stairs down, 0 = stairs up)
-- Returns the Map and info: theme, W, H (pieces), chambers, start, exit (chambers), surface(ch, i) -> feet y (px)
-- under interior column i, gate {x, feet}, door {x} / way {x} (the arches' left edge, px).
function M.build(maps, template, opts)
  local rng, T = opts.rng, assert(M.themes[opts.theme], 'floors.build: theme')
  local list, start, exit = M.maze(opts.nc, opts.nr, rng)
  start.plain, exit.plain = true, true
  local g, W, H = M.carve(list, opts.nc, opts.nr, rng, { dais = opts.dais, dais_rock = T.dais_rock, bulges = T.bulges })
  -- where the arches stand (2 pieces wide, on level floor away from the doorways' landings): kept clear of decor
  local function free_pair(ch)
    local c = {}
    for i = 2, IW - 4 do if not ch.used[i] and not ch.used[i + 1] then c[#c + 1] = i end end
    if #c == 0 then for i = 1, IW - 3 do if not (ch.down and ch.x0 + i + 1 >= ch.down and ch.x0 + i < ch.down + SHAFT_W) then c[#c + 1] = i end end end
    return pick(rng, c)
  end
  start.arch, exit.arch = free_pair(start), free_pair(exit)
  for _, ch in ipairs { start, exit } do ch.keep = { [ch.arch - 1] = true, [ch.arch] = true, [ch.arch + 1] = true, [ch.arch + 2] = true } end

  local m = maps.parse(template:serialize())
  blank(m, W, H)
  T.paint(m, g, W, H, list, rng)
  -- the shafts' ledges: from the lower chamber's floor up to the mouth, left / right in turn, each 2 pieces wide
  for _, ch in ipairs(list) do
    if ch.up then
      for k = 1, CH - 1 do
        local side = (k % 2 == 1) and 0 or 2
        for px = ch.up + side, ch.up + side + 1 do T.ledge(m, px, ch.floor - LEDGE_RISE * k) end
      end
    end
  end
  T.door(m, start.x0 + start.arch, start.floor, 2)
  T.door(m, exit.x0 + exit.arch, exit.floor, opts.way or 1)

  local gate = template:find(function(o) return o.rec[5] == 70101 end)
  assert(gate, 'the template has no walk-in zone')
  local function surface(ch, i) return ch.floor * 64 + T.surface - (on_dais(ch, i) and T.dais_h or 0) end
  m.objs = {}
  local gz = maps.clone(gate)
  local gx = (start.x0 + start.arch) * 64 + 32
  gz.rec[2], gz.rec[3] = gx, surface(start, start.arch) - 96
  gz.A[1] = 1
  m:add(gz)
  local info = { theme = opts.theme, T = T, W = W, H = H, chambers = list, start = start, exit = exit, surface = surface,
                 gate = { x = gx, feet = surface(start, start.arch) },
                 way = { x = (exit.x0 + exit.arch) * 64, feet = surface(exit, exit.arch) }, g = g }
  return m, info
end

return M
