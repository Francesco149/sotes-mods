-- recettear/dungeon.lua — THE HALL OF TRIALS: Recettear's first dungeon as side-view cave floors of this game.
--
-- What comes from where:
--   * the floors: new every visit (a seed per run), drawn with the game's own Mountain Cave tiles (cave.lua) — rooms
--     240901..240905 (copies of 240120's record: cave tile set, not a town), maps DATA 4021..4025 re-served before
--     each floor loads (maps.set, loader api 1.13)
--   * the monsters, per floor, and what each drops (common / rare): Recettear's own data/enemylist.txt ("dungeon 1"),
--     read by setup.lua — green and red slimes, kobolds, green ropers, in their Recettear sprites over this game's
--     slime / kobold / myconid bodies and AI (actors.define)
--   * the treasure chests: the game's own chests (map object 70220: retail opens them, "You found X inside the
--     treasure chest."), filled from Recettear's dungeon-1 treasure (item.txt "ダ(1M)": M = how deep it lies)
--   * the way down: Recettear's magic circle; standing on it asks "Go to the next floor?"
--   * falling in battle: the game's own Game Over runs (Try Again / Return To Safety), then Recettear's rule —
--     everything found in the Hall is lost except ONE item, and Tear brings you back to the shop
--   * floor 5 is the boss's den (the Crown Slime in Recettear): for now an empty den with the last treasure; the
--     exit there leads home.  The boss is future work.
-- The opened state of chests is the game's own "object perpetuity" table (room +0x40ac, +0x1804: 2048 records
-- {handle, state, map}; handle = room * 1000 + the object's id): each floor's records are freed when the floor is
-- generated, so a new run finds the chests closed and the table never grows past one run's worth.
local C = ...                                            -- the shared pieces from init.lua
local S, SND, ACT, MAPS, A = C.S, C.SND, C.ACT, C.MAPS, C.A
local cave = assert(C.loadmod('cave.lua'))

local H = {}
local FLOORS = 5                                         -- 1..4 + the den
local ROOM0, MAP0 = 240900, 4020                         -- floor n: room 240900 + n, DATA 4020 + n
local LIKE = 240120                                      -- a Mountain Cave room (its record: tile set, BGM, kind)
local TEMPLATE = 1048                                    -- its map: the header, the walk-in zone, the arch
local CHEST_MAP, TORCH_MAP, FOE_MAP = 1049, 1049, 1047   -- maps holding a chest / a torch / a slime record to copy
local F = { RUN = 991000020, CLEARS = 991000021, RUNS = 991000022 }   -- story flags (saved with the game)
H.F = F
local function room_of(n) return ROOM0 + n end
local function floor_of(area) if area and area > ROOM0 and area <= ROOM0 + FLOORS then return area - ROOM0 end end
H.room_of, H.floor_of = room_of, floor_of

-- a seeded generator (Park–Miller): the same seed + floor gives the same floor, so a saved run can be rebuilt
local function rng_for(seed, n)
  local s = (seed * 7919 + n * 104729) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(a, b)
    s = (s * 48271) % 2147483647
    if not a then return s / 2147483647 end
    return a + s % (b - a + 1)
  end
end

-- ── the Hall's tables (from the user's Recettear, setup 3) ─────────────────────────────────────────────────────────
local HALL = A.hall or { pool = {}, floors = {} }
local function foes_of(n)                                -- floor n's monsters + drops (the last table covers deeper)
  local best
  for _, sec in ipairs(HALL.floors) do if sec.lo <= n and n <= sec.hi then best = sec end end
  if not best then best = HALL.floors[#HALL.floors] end
  return best and best.foes or {}
end
local function treasure(rng, n)                          -- a chest's content for floor n: {id, count}
  local pick, total = {}, 0
  for _, e in ipairs(HALL.pool) do
    local it = C.item_of(e.id)
    if it and e.depth <= 2 * n + 1 then
      local w = 10 - e.depth
      pick[#pick + 1] = { id = it, w = w }
      total = total + w
    end
  end
  if total == 0 or rng(1, 100) <= 20 then                -- coins: copper / silver
    if rng(1, 2) == 1 then return 1, rng(20, 60) * n end
    return 2, rng(3, 8) * n
  end
  local r = rng(1, total)
  for _, p in ipairs(pick) do r = r - p.w if r <= 0 then return p.id, 1 end end
  return pick[#pick].id, 1
end

-- ── a floor ─────────────────────────────────────────────────────────────────────────────────────────────────────
local tmpl                                                -- the map objects copied into every floor
local function templates()
  if tmpl then return tmpl end
  local t = assert(MAPS.read(TEMPLATE))
  tmpl = {
    map = t,
    chest = assert(MAPS.read(CHEST_MAP):find(function(o) return o.rec[5] == 70220 end), 'no chest to copy'),
    torch = assert(MAPS.read(TORCH_MAP):find(function(o) return o.rec[5] == 70371 end), 'no torch to copy'),
    foe = assert(MAPS.read(FOE_MAP):find(function(o) return o.rec[5] == 51010 end), 'no slime record to copy'),
    npc = assert(MAPS.read(C.HOUSE_MAP):find(function(o) return o.rec[5] == 50240 end), 'no townswoman record'),
  }
  return tmpl
end

-- the arch: plane-0 piece 131041 frame 2 (tile set 1480) — 128 x 160 px, its cells left empty under it (as the game's
-- rooms do: DATA 1049 at its gate)
local function arch(m, px, feet)
  local cx, cy = math.floor(px / 32), math.floor(feet / 32) - 5
  for y = cy - 1, cy + 4 do for x = cx - 1, cx + 3 do
    if y >= cy then m:set_cell(0, y, x, { 0, 0, 0, 0, 0, 0, 0 }) end
    if y >= 0 and x >= 0 then m:set_cell(1, y, x, { 0, 0, 0, 0, 0, 0, 0 }) end   -- no stalagmite in front of it
  end end
  m:set_cell(0, cy, cx, { 6640, 131041, 1480, 2, 0, 0, 0 })
end

local function build(n, seed)
  local T = templates()
  local rng = rng_for(seed, n)
  local den = n == FLOORS
  local m, info = cave.build(MAPS, T.map, { w = den and 22 or (34 + 6 * n), h = 14, rng = rng, den = den })
  -- the backdrop of a lit cave: the lighter rock wall (131001 frame 0, as the game's cave rooms use inside)
  for i = 1, #m.cells do
    local c = m.cells[i]
    if c[2] == 131002 then c[1], c[2], c[4] = 5910, 131001, 0 end
  end
  local runs, first, last = info.runs, info.runs[1], info.runs[#info.runs]
  arch(m, (first.x0 + 1) * 64, first.h * 64)                         -- where the party came in
  arch(m, (last.x1 - 2) * 64, last.h * 64)                            -- the way on, behind the circle
  local placed = { exit = { x = (last.x1 - 1) * 64, feet = last.h * 64 } }
  -- the circle (a character of ours, inert), in front of the far arch
  -- (its sheet is re-set into the townsperson base's 96 px cell, feet on the bottom row: init.lua char_bank)
  m:add_character { like = T.npc, code = C.CODE.circle, x = placed.exit.x - 64, floor = placed.exit.feet,
                    cell_h = math.max(C.BASE_CELL_H, A.chars.circle and A.chars.circle.cell_h or 0), facing = 'right' }
  -- torches on the walls of the taller stretches
  for i, r in ipairs(runs) do                             -- (not the first / last stretch: the arches stand there)
    if i > 1 and i < #runs and (r.h - r.c) >= 5 and (r.x1 - r.x0) >= 3 and rng(1, 3) <= 2 then
      local t = MAPS.clone(T.torch)
      t.rec[2], t.rec[3] = (r.x0 + rng(1, r.x1 - r.x0 - 1)) * 64, r.h * 64 - 176
      m:add(t)
    end
  end
  -- monsters: map records (the room loader makes them; presence 1 = always, 0 = 70 %)
  local foes = foes_of(n)
  local inner = {}
  for i = 2, #runs - 1 do inner[#inner + 1] = runs[i] end
  if not den and #foes > 0 and #inner > 0 then
    for k = 1, 3 + 2 * n do
      local r = inner[rng(1, #inner)]
      local f = foes[rng(1, #foes)]
      local code = C.CODE.hall[f.key]
      if code then
        local o = MAPS.clone(T.foe)
        o.rec[5] = code
        o.rec[2] = (r.x0 * 64) + rng(0, math.max(0, (r.x1 - r.x0) * 64))
        o.rec[3] = r.h * 64 - 160                                      -- the body drops onto the floor
        while #o.A < 7 do o.A[#o.A + 1] = 0 end
        o.A[7] = (k <= 2 + n) and 1 or 0
        m:add(o)
      end
    end
  end
  -- treasure chests: the game's own (object 70220: A[2] its id, A[7] the item or 1 / 2 / 3 = coins, A[8] count)
  local nchest = den and 1 or rng(1, 2) + (n >= 3 and 1 or 0)
  local spots = {}
  for i = 2, #runs do if (runs[i].x1 - runs[i].x0) >= 2 then spots[#spots + 1] = runs[i] end end
  for k = 1, nchest do
    if #spots == 0 then break end
    local r = den and last or table.remove(spots, rng(1, #spots))
    local o = MAPS.clone(T.chest)
    o.rec[2] = den and (last.x0 + 2) * 64 or (r.x0 + (rng(0, 1) == 0 and 0 or (r.x1 - r.x0 - 1))) * 64 + 16
    o.rec[3] = r.h * 64 - 32
    local id, count
    if den then
      local best
      for _, e in ipairs(HALL.pool) do if e.depth >= 5 and C.item_of(e.id) and (not best or rng(1, 2) == 1) then best = C.item_of(e.id) end end
      id, count = best or 3, best and 1 or 5
    else
      id, count = treasure(rng, n)
    end
    while #o.A < 8 do o.A[#o.A + 1] = 0 end
    o.A[2], o.A[7], o.A[8] = 500 + k, id, count
    m:add(o)
  end
  info.exit = placed.exit
  return m, info
end

-- free this floor's records in the object perpetuity table (opened chests): handle = room * 1000 + id
local function forget(n)
  local w = mod.mem.read_u32(mod.sym.va('g_world'))
  local room = w and w ~= 0 and mod.mem.read_u32(w + (mod.edition == 'enold' and 0x2784 or 0x3788))
  if not room or room == 0 then return 0 end
  local p = mod.mem.read_u32(room + 0x40ac)
  if not p or p == 0 then return 0 end
  local cnt, freed = mod.mem.read_u32(p + 0x7804) or 0, 0
  local key = room_of(n)
  for i = 0, math.min(cnt, 2048) - 1 do
    local r = p + 0x1804 + 12 * i
    local h = mod.mem.read_i32(r)
    if h and h ~= 0 and math.floor(h / 1000) == key then
      mod.mem.write_i32(r, 0); mod.mem.write_i32(r + 4, 0); mod.mem.write_i32(r + 8, 0)
      freed = freed + 1
    end
  end
  return freed
end

-- ── the run ─────────────────────────────────────────────────────────────────────────────────────────────────────
local run = { active = false }
H.run = run
local function defeats()
  local w = mod.mem.read_u32(mod.sym.va('g_world'))
  if not w or w == 0 then return nil end
  local room = mod.mem.read_u32(w + (mod.edition == 'enold' and 0x2784 or 0x3788))
  return room and room ~= 0 and mod.mem.read_i32(room + 0x40b0) or nil
end
local function bag()                                     -- Recettear items carried (unstored): id → units
  local t = {}
  for _, it in ipairs(mod.game.items.list() or {}) do
    if it.id >= 70400000 and it.id < 70410000 and not it.stored then t[it.id] = (t[it.id] or 0) + math.max(1, it.count) end
  end
  return t
end
H.bag = bag
local function finds()                                   -- what this run found: {{id, n}, ...}
  local now, t = bag(), {}
  for id, k in pairs(now) do
    local d = k - (run.bag0 and run.bag0[id] or 0)
    if d > 0 then t[#t + 1] = { id = id, n = d } end
  end
  table.sort(t, function(a, b) return a.id < b.id end)
  return t
end
H.finds = finds

local function serve(n)
  local m, info = build(n, run.seed)
  local ok, err = MAPS.set(MAP0 + n, m, 'recettear')
  if not ok then return nil, err end
  run.info = info
  run.built = n
  local freed = forget(n)
  mod.log(('hall: floor %d built (seed %d, %d x %d pieces, %d runs, %d objects; %d chest records freed)'):format(
    n, run.seed, info.W, info.H, #info.runs, #m.objs, freed))
  return true
end
-- go to floor n (from anywhere: the shop, the floor above)
local function go(n)
  local ok, err = serve(n)
  if not ok then return nil, err end
  run.floor_target = n
  return mod.game.map.warp(room_of(n), 1, true)
end
H.go = go

function H.start()
  run.active = true
  -- a new layout every run: the clock + the frame count (math.random is never seeded: the same each session).  Kept in
  -- a story flag: a save made down here rebuilds the same floors
  run.seed = (os.time() * 7 + math.floor(os.clock() * 1000) + (mod.frame and mod.frame() or 0) * 131 + math.random(1, 99991)) % 999999937 + 1
  run.bag0 = bag()
  run.gold0 = mod.game.items.gold()
  run.defeats0 = defeats() or 0
  run.floor = 0
  run.banner = nil
  run.seen = nil
  run.exit_armed = true
  C.fset(F.RUN, run.seed)
  C.fset(F.RUNS, C.fget(F.RUNS) + 1)
  for n = 1, FLOORS do forget(n) end
  return go(1)
end
local function finish(how)
  run.active = false
  run.floor = 0
  run.how = how
  C.fset(F.RUN, 0)
end

-- the end of a run: back to the branch
local function home(how)
  finish(how)
  run.leaving = true
  S.after(function() mod.game.map.warp(C.SHOP, 2, true) end)
end

-- Recettear's rule when the adventurer falls: everything found here is lost, but one item comes home
-- Two ways back from the game's Game Over: "Return To Safety" loads the save it wrote at the defeat (the bag as it was:
-- the finds are taken here), "Try Again" the checkpoint retail wrote when the party last left a room by a normal exit —
-- before this run (the Hall's floors are entered by warps): the finds are gone with it, and the one item Tear saved
-- is handed back (the run's finds are tracked as it goes: run.seen).
local function fallen(s)
  local got = finds()
  local keep, units, lost, restored = nil, 0, 0, false
  for _, f in ipairs(got) do units = units + f.n end
  if units == 0 and run.seen and #run.seen > 0 then got, restored = run.seen, true end
  local total = 0
  for _, f in ipairs(got) do total = total + f.n end
  if total > 0 then
    local r = math.random(1, total)
    for _, f in ipairs(got) do r = r - f.n if r <= 0 then keep = f break end end
  end
  if restored then
    lost = total - (keep and 1 or 0)
    if keep then mod.game.items.give(keep.id, 1) end
  else
    for _, f in ipairs(got) do
      local n = f.n - ((keep and keep.id == f.id) and 1 or 0)
      if n > 0 then lost = lost + (mod.game.items.take(f.id, n) or 0) end
    end
  end
  units = total
  run.seen = nil
  s:sound(C.SFX.fanfare)
  C.say(s, 'tear', 'You fainted in the Hall of Trials. I dragged you out myself. The guild\'s rules: whatever was found down there stays down there.', 2)
  if keep then
    local d = mod.game.items.def(keep.id)
    C.say(s, 'recette', ('I managed to hang on to one thing, though... the %s!'):format(d and d.name or 'item'), 3)
  elseif lost == 0 then
    C.say(s, 'recette', 'At least we had not found anything yet to lose...', 2)
  end
  run.last_fall = { floor = run.fell_on, lost = lost, kept = keep and keep.id or nil, found = units }
  mod.log(('hall: fallen on floor %s — %d of %d found item(s) lost, kept %s'):format(tostring(run.fell_on), lost, units, keep and keep.id or '-'))
end

-- ── floors as they load ─────────────────────────────────────────────────────────────────────────────────────────
local NEWS = {                                            -- a word from Tear as each floor opens
  'The Hall of Trials. The guild sends its beginners here. Slimes, mostly. Stay on your feet.',
  'Red slimes from here on. They hit harder than the green ones.',
  'Kobolds. They carry chestnuts, for some reason. And sometimes a sword.',
  'Ropers on this floor. Do not let them touch you. The next floor is the last.',
  'The den at the bottom of the Hall. The guild\'s notes say a Crown Slime lives here... it appears to be out.',
}
local function arrive(n)
  run.floor = n
  run.exit_armed = false                                 -- step off the circle (or arrive away from it) first
  if not run.info or run.built ~= n then serve(n) end    -- a floor loaded another way (a load, Try Again): same seed
  -- this floor's drop table (Recettear's: the common drop first, through the game's own drop roll; the rare after)
  for _, f in ipairs(foes_of(n)) do
    local code = C.CODE.hall[f.key]
    local d = code and ACT.defined(code)
    if d then
      local drops = {}
      if f.common and C.item_of(f.common) then drops[#drops + 1] = { id = C.item_of(f.common), chance = 300 } end
      if f.rare and C.item_of(f.rare) then drops[#drops + 1] = { id = C.item_of(f.rare), chance = 50 } end
      d.drops = drops
    end
  end
  S.run(function(s)
    run.banner = n
    s:pause(30)
    s:narrate(n < FLOORS and ('The Hall of Trials  -  %dF'):format(n) or 'The Hall of Trials  -  the Den')
    C.say(s, 'tear', NEWS[n] or NEWS[1])
  end, { what = 'hall floor ' .. n })
end

local function on_circle()
  local e = run.info and run.info.exit
  if not e then return false end
  local me = mod.game.coordinates.player()
  if not me then return false end
  local L
  for _, a in ipairs(ACT.list() or {}) do if a.leader then L = a break end end
  if not L then return false end
  local cx, feet = L.x + L.w / 2, L.y + L.h
  return math.abs(cx - e.x * 100) <= 4800 and math.abs(feet - e.feet * 100) <= 3200
end

local function exit_prompt(s)
  local n = run.floor
  if n < FLOORS then
    if s:yes_no() then
      S.after(function()
        local ok, err = go(n + 1)
        if not ok then mod.log('hall: ' .. tostring(err)) end
      end)
    end
  else
    s:narrate('The circle leads back up to the surface.')
    if s:yes_no() then
      C.fset(F.CLEARS, C.fget(F.CLEARS) + 1)
      run.cleared = true
      home('cleared')
    end
  end
end

-- per game tick (free roam only)
function H.tick()
  local m = mod.game.map.get()
  local n = m and floor_of(m.area)
  if not n then return end
  if not run.active then                                 -- a save loaded inside the Hall (no run in memory):
    if run.leaving then return end                       -- (or the run just ended here: the warp home is queued)
    if C.fget(F.RUN) == 0 then                           -- no run on record: back to the branch
      run.leaving = true
      S.after(function() mod.game.map.warp(C.SHOP, 2, true) end)
      return
    end
    run.active, run.seed = true, C.fget(F.RUN)
    run.bag0, run.defeats0, run.floor = bag(), defeats() or 0, n   -- what was carried in counts as brought along
    C.fset(F.RUN, run.seed)
    mod.log('hall: a run picked up from a save (floor ' .. n .. ', seed ' .. run.seed .. ')')
    serve(n)                                             -- that run's floor again, and reload it (the loaded map may be
    run.floor = 0                                        -- another layout: the party could stand inside the rock)
    S.after(function() mod.game.map.warp(room_of(n), 1, true) end)
    return
  end
  if run.floor ~= n then return end
  local on = on_circle()
  if on and run.exit_armed and not mod.game.map.event() then
    run.exit_armed = false
    S.run(function(s)
      if n < FLOORS then s:narrate('A magic circle glows on the floor. Go to the next floor?') end
      exit_prompt(s)
    end, { what = 'hall exit' })
  elseif not on then
    run.exit_armed = true
  end
end

-- per presented frame: floor arrivals, defeats, leaving the Hall another way
function H.frame()
  if not run.active then
    if run.leaving then                                  -- the warp home: done once the party is out of the Hall
      local m = mod.game.map.get()
      if m and not floor_of(m.area) and mod.game.map.warp_status() == 'idle' then run.leaving = nil end
    end
    return
  end
  local d = defeats()
  if d == nil then return end                            -- the Game Over screen: the world is gone
  local m = mod.game.map.get()
  if not m then return end
  if d > (run.defeats0 or d) then                        -- fell (Try Again or Return To Safety has run): Recettear's rule
    if mod.game.map.event() or mod.game.map.warp_status() ~= 'idle' then return end
    run.defeats0 = d
    run.fell_on = run.floor
    local where = m.area
    finish('fallen')
    run.leaving = where ~= C.SHOP or nil
    S.run(function(s)
      fallen(s)
      -- queued from inside the scene: a warp armed while an event runs is consumed by the event's frames and lost
      if where ~= C.SHOP then S.after(function() mod.game.map.warp(C.SHOP, 2, true) end) end
    end, { what = 'hall fallen' })
    return
  end
  local n = floor_of(m.area)
  if n and run.floor == n and (mod.frame() % 30) == 0 then run.seen = finds() end   -- what the run has found so far
  if n and n ~= run.floor and not mod.game.map.event() and mod.game.map.warp_status() == 'idle' then
    arrive(n)
  elseif not n and run.floor > 0 and m.area ~= C.SHOP and mod.game.map.warp_status() == 'idle' then
    finish('left')                                       -- a Recall Lamp or the like: what was found is kept
    mod.log('hall: left the Hall another way (room ' .. tostring(m.area) .. ')')
  end
end

-- ── install ──────────────────────────────────────────────────────────────────────────────────────────────────────
function H.install()
  local T = templates()
  run.seed = 1
  for n = 1, FLOORS do                                   -- a first version of each floor (re-served before each visit)
    local m = build(n, 1)
    assert(MAPS.define(MAP0 + n, m, 'recettear'))
    assert(mod.game.map.add_room { key = room_of(n), like = LIKE, map = MAP0 + n, town = false })
  end
  run.seed = nil
  if A.music and A.music.cave then
    for n = 1, FLOORS do SND.room_music(room_of(n), mod.data_dir .. 'bgm_cave.wav') end
  end
  mod.log(('hall: installed, floors %d..%d (DATA %d..%d), %d treasures, %d monster tables'):format(
    room_of(1), room_of(FLOORS), MAP0 + 1, MAP0 + FLOORS, #HALL.pool, #HALL.floors))
end

return H
