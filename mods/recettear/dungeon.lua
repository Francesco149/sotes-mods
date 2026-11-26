-- recettear/dungeon.lua — THE HALL OF TRIALS: Recettear's first dungeon as side-view floors of this game.
--
-- What comes from where:
--   * the floors: new every visit (a seed per run).  Recettear carves each floor as a maze on a grid of rooms; here
--     the same maze stands upright (floors.lua): chambers joined by doorways and by shafts climbed on jump-through
--     ledges.  1F / 2F are the Hall itself — brick halls, drawn with this game's grey ruin tiles (Recettear's Hall is
--     a brick dungeon) — 3F / 4F the caves under it (the Mountain Cave tiles), 5F the vault.  Maps DATA 4021..4025,
--     re-served before each floor loads (maps.set, loader api 1.13)
--   * the monsters, per floor, and what each drops (common / rare): Recettear's own data/enemylist.txt ("dungeon 1"),
--     read by setup.lua — green and red slimes, kobolds, green ropers, in their Recettear sprites over this game's
--     slime / kobold / myconid bodies and AI (actors.define).  Their strength is Recettear's too (see STATS)
--   * the treasure chests: the game's own chests (map object 70220: retail opens them, "You found X inside the
--     treasure chest."), filled from Recettear's dungeon-1 treasure (item.txt "ダ(1M)": M = how deep it lies)
--   * the way down: Recettear's magic circle; standing on it asks "Go to the next floor?"
--   * falling in battle: the game's own Game Over runs (Try Again / Return To Safety), then Recettear's rule —
--     everything found in the Hall is lost except ONE item, and Tear brings you back to the shop
--   * floor 5 is the vault, as in Recettear (its Hall has no boss: a treasure chest and the way out)
-- The opened state of chests is the game's own "object perpetuity" table (room +0x40ac, +0x1804: 2048 records
-- {handle, state, map}; handle = room * 1000 + the object's id): each floor's records are freed when the floor is
-- generated, so a new run finds the chests closed and the table never grows past one run's worth.
local C = ...                                            -- the shared pieces from init.lua
local S, SND, ACT, MAPS, A = C.S, C.SND, C.ACT, C.MAPS, C.A
local floors = assert(C.loadmod('floors.lua'))

local H = {}
local FLOORS = 5                                         -- 1..4 + the vault
-- floor n: its look and its maze (chambers across x down).  Recettear: 3 x 5 rooms on 1F..3F, 5 x 5 on 4F.
local PLAN = {
  { theme = 'hall', nc = 3, nr = 2 },
  { theme = 'hall', nc = 4, nr = 2 },
  { theme = 'cave', nc = 3, nr = 3 },
  { theme = 'cave', nc = 4, nr = 3 },
  { theme = 'hall', nc = 2, nr = 1, vault = true },
}
H.PLAN = PLAN
-- floor n: room ROOM0[theme] + n (a copy of a room of that look: its record's backdrop / palette / kind), DATA 4020 + n
local ROOM0, MAP0 = { cave = 240900, hall = 245900 }, 4020
local LIKE = { cave = 240120, hall = 245140 }            -- a Mountain Cave room / a room of the ruins
local TEMPLATE = 1048                                    -- a map for the header and the walk-in zone
local CHEST_MAP, TORCH_MAP, FOE_MAP = 1049, 1049, 1047   -- maps holding a chest / a torch / a slime record to copy
local F = { RUN = 991000020, CLEARS = 991000021, RUNS = 991000022 }   -- story flags (saved with the game)
H.F = F
local function room_of(n) return ROOM0[PLAN[n].theme] + n end
-- (a save made on a floor of version 0.3 stands in 240900 + n whatever the look: those rooms stay defined)
local function floor_of(area)
  if not area then return end
  for _, r0 in pairs(ROOM0) do if area > r0 and area <= r0 + FLOORS then return area - r0 end end
end
H.room_of, H.floor_of = room_of, floor_of
function H.reload() floors = assert(C.loadmod('floors.lua')) return true end   -- (development: floors.lua again)

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

-- Recettear's own numbers (bmpdata.bin data/enemy.txt: HP / EXP / AT / DF), at this game's beginner scale: the green
-- slime IS this game's Green Slime (attack 18, defence 14, 3 EXP on the SE's default difficulty), the others keep
-- Recettear's proportions to it — so the Hall tops out below a Blue Slime (attack 30), the next monster the story
-- brings.  (Version 0.3 only set HP: a kobold hit with the stock Kobold's attack 40 and gave its 58 EXP.)
--   Recettear:  green 15 / 3 / 14 / 4    red 20 / 5 / 18 / 14    kobold 20 / 9 / 17 / 4    roper 15 / 10 / 16 / 4
-- and Recettear's growth per floor below the first: HP x (1 + 0.2 k), attack x (1 + 0.1 k).
local STATS = {
  slime    = { hp = 30, atk = 18, def = 14, exp = 3,  gold = 4 },
  redslime = { hp = 36, atk = 22, def = 20, exp = 5,  gold = 5 },
  kobold   = { hp = 36, atk = 22, def = 14, exp = 9,  gold = 7 },
  roper    = { hp = 30, atk = 21, def = 14, exp = 10, gold = 7 },
}
H.STATS = STATS
local ST = { enold = { blk = 0x750, exp = 0xf0, gold = 0xf4 }, se = { blk = 0x760, exp = 0xf4, gold = 0xf8 } }
local function strength(a, key, n)                        -- a monster of ours as it appears on floor n
  local st, L = STATS[key], mod.edition == 'enold' and ST.enold or ST.se
  local sb = a and a.ptr and mod.mem.read_u32(a.ptr + L.blk)
  if not st or not sb or sb == 0 then return end
  local k = math.max(0, (n or 1) - 1)
  local hp = math.floor(st.hp * (1 + 0.2 * k) + 0.5)
  mod.mem.write_i32(sb + 0x54, hp) mod.mem.write_i32(sb + 0x58, hp)
  mod.mem.write_i32(sb + 0x64, math.floor(st.atk * (1 + 0.1 * k) + 0.5))
  mod.mem.write_i32(sb + 0x68, st.def)
  mod.mem.write_i32(sb + L.exp, st.exp + math.floor(k / 2))
  mod.mem.write_i32(sb + L.gold, st.gold + k)
end

local function build(n, seed)
  local T = templates()
  local rng = rng_for(seed, n)
  local plan = PLAN[n]
  local m, info = floors.build(MAPS, T.map, { nc = plan.nc, nr = plan.nr, theme = plan.theme, rng = rng,
                                              dais = plan.vault and 0 or 45, way = plan.vault and 0 or 1 })
  local IW = floors.CW - floors.WALL
  local start, exit, surface = info.start, info.exit, info.surface
  local placed = { exit = { x = info.way.x + 64, feet = info.way.feet } }
  -- the circle (a character of ours, inert), in front of the far archway
  -- (its sheet is re-set into the townsperson base's 96 px cell, feet on the bottom row: init.lua char_bank)
  m:add_character { like = T.npc, code = C.CODE.circle, x = placed.exit.x - 64, floor = placed.exit.feet,
                    cell_h = math.max(C.BASE_CELL_H, A.chars.circle and A.chars.circle.cell_h or 0), facing = 'right' }
  -- level floor in a chamber, away from doorways' landings, shafts and the arches: the interior columns to stand on
  local function spots(ch, edge)
    local t = {}
    for i = edge and 0 or 1, IW - (edge and 1 or 2) do
      local shaft = (ch.down and ch.x0 + i >= ch.down - 1 and ch.x0 + i <= ch.down + 4)
      local ledges = (ch.up and ch.x0 + i >= ch.up and ch.x0 + i < ch.up + 4)
      if not shaft and not ledges and not (ch.keep and ch.keep[i]) then t[#t + 1] = i end
    end
    return t
  end
  -- torches on the back wall
  for _, ch in ipairs(info.chambers) do
    for _, i in ipairs(spots(ch)) do
      if rng(1, 6) == 1 and not (ch.dais and i >= ch.dais[1] and i <= ch.dais[2]) then
        local t = MAPS.clone(T.torch)
        t.rec[2], t.rec[3] = (ch.x0 + i) * 64 + 16, surface(ch, i) - info.T.torch_up
        m:add(t)
      end
    end
  end
  -- monsters: map records (the room loader makes them; presence 1 = always, 0 = 70 %).  As Recettear places them: in
  -- groups, never in the room the party arrives in nor the exit's.
  local foes = foes_of(n)
  local rooms = {}
  for _, ch in ipairs(info.chambers) do if ch ~= start and ch ~= exit then rooms[#rooms + 1] = ch end end
  if not plan.vault and #foes > 0 and #rooms > 0 then
    local groups = { 2, 1, 1, 1, 3 }
    for i = #rooms, 2, -1 do local j = rng(1, i) rooms[i], rooms[j] = rooms[j], rooms[i] end
    for gi, ch in ipairs(rooms) do
      local sp = spots(ch, true)
      for k = 1, #sp > 0 and groups[(gi - 1) % #groups + 1] or 0 do
        local f = foes[rng(1, #foes)]
        local code = C.CODE.hall[f.key]
        if code then
          local i = sp[rng(1, #sp)]
          local o = MAPS.clone(T.foe)
          o.rec[5] = code
          o.rec[2] = (ch.x0 + i) * 64 + rng(0, 32)
          o.rec[3] = surface(ch, i) - 192                               -- the body drops onto the floor
          while #o.A < 7 do o.A[#o.A + 1] = 0 end
          o.A[7] = (k == 1) and 1 or 0
          m:add(o)
        end
      end
    end
  end
  -- treasure chests: the game's own (object 70220: A[2] its id, A[7] the item or 1 / 2 / 3 = coins, A[8] count), in
  -- the dead ends first (Recettear marks cells off the way through), the farthest from the start first
  local ends = {}
  for _, ch in ipairs(rooms) do
    local links = 0
    for _ in pairs(ch.link) do links = links + 1 end
    ends[#ends + 1] = { ch = ch, w = (links == 1 and 100 or 0) + ch.dist }
  end
  table.sort(ends, function(a, b) if a.w ~= b.w then return a.w > b.w end return a.ch.order < b.ch.order end)
  local nchest = plan.vault and 1 or math.min(#ends, rng(1, 2) + (n >= 3 and 1 or 0))
  for k = 1, nchest do
    local ch = plan.vault and exit or ends[k].ch
    local sp = spots(ch)
    if #sp > 0 then
      -- on the dais when the chamber has one (a little prize for the hop), else anywhere level
      local i = sp[rng(1, #sp)]
      if ch.dais then i = ch.dais[1] + rng(0, ch.dais[2] - ch.dais[1]) end
      if plan.vault then i = math.min(IW - 2, exit.arch + 3) end
      local o = MAPS.clone(T.chest)
      o.rec[2], o.rec[3] = (ch.x0 + i) * 64 + 16, surface(ch, i) - 64
      local id, count
      if plan.vault then
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
  end
  info.exit_at = placed.exit
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
  run.exit = info.exit_at
  run.built = n
  local freed = forget(n)
  mod.log(('hall: floor %d built (seed %d, %s, %d x %d pieces, %d chambers, %d objects; %d chest records freed)'):format(
    n, run.seed, info.theme, info.W, info.H, #info.chambers, #m.objs, freed))
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
  'The Hall of Trials. The guild sends its beginners here. Slimes, mostly. The way on is never where it was last time: look up as well as ahead.',
  'Red slimes from here on. They hit harder than the green ones.',
  'The masonry ends here: these are the caves the Hall was built over. Kobolds live in them. They carry chestnuts, for some reason. And sometimes a sword.',
  'Ropers on this floor. Do not let them touch you. The next floor is the last.',
  'The vault at the bottom of the Hall. Whatever the guild left here for whoever gets this far is yours.',
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
    s:narrate(n < FLOORS and ('The Hall of Trials  -  %dF'):format(n) or 'The Hall of Trials  -  the Vault')
    C.say(s, 'tear', NEWS[n] or NEWS[1])
  end, { what = 'hall floor ' .. n })
end

local function on_circle()
  local e = run.exit
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
  templates()
  run.seed = 1
  for n = 1, FLOORS do                                   -- a first version of each floor (re-served before each visit)
    local m = build(n, 1)
    assert(MAPS.define(MAP0 + n, m, 'recettear'))
    assert(mod.game.map.add_room { key = room_of(n), like = LIKE[PLAN[n].theme], map = MAP0 + n, town = false })
    if room_of(n) ~= ROOM0.cave + n then                 -- version 0.3's room for this floor: a save made there loads
      assert(mod.game.map.add_room { key = ROOM0.cave + n, like = LIKE.cave, map = MAP0 + n, town = false })
    end
  end
  run.seed = nil
  if A.music and A.music.cave then
    for n = 1, FLOORS do
      SND.room_music(room_of(n), mod.data_dir .. 'bgm_cave.wav')
      if room_of(n) ~= ROOM0.cave + n then SND.room_music(ROOM0.cave + n, mod.data_dir .. 'bgm_cave.wav') end
    end
  end
  -- the monsters' strength, as each appears (Recettear's numbers: STATS), by the floor it stands on
  for key, code in pairs(C.CODE.hall) do
    local d = ACT.defined(code)
    if d then
      d.on_spawn = function(a)
        local here = mod.game.map.get()
        strength(a, key, here and floor_of(here.area) or 1)
      end
    end
  end
  mod.log(('hall: installed, floors %d..%d (DATA %d..%d), %d treasures, %d monster tables'):format(
    room_of(1), room_of(FLOORS), MAP0 + 1, MAP0 + FLOORS, #HALL.pool, #HALL.floors))
end

return H
