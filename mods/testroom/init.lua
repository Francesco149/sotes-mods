-- testroom — proof of concept for custom content (loader api 1.8):
--   * a NEW DOOR in Arche's house (210140, ground floor, left of the front door),
--   * leading to the MOD HALL (210142) — a new room whose map is the back room's, widened to twice its length,
--   * where six NPCs and a bookshelf demonstrate the game's own systems driven from Lua (mod.game.script):
--       Tester (guide)   branching dialogue, choice menus, a quiz remembered in the save (a story flag)
--       Merchant         the game's shop on a custom stock
--       Innkeeper        the game's own inn (its price window, payment, rest + heal); the storage box
--       Warp mage        a destination menu → the warp
--       Bard             stock sound effects and sounds synthesized in Lua (mod.game.sound)
--       Arena master     monsters spawned on demand in a second custom room (210143, town rules off), a reward
--                        cutscene when the wave is cleared
--       bookshelf        the game's book reader on custom pages
--
-- Nothing of the game ships with the mod: the maps are built at load from the user's own map data
-- (mod.res.read) and served back to the game through the loader's resource overlay (mod.res.set).
--
-- Map DATA format (the port's tools/extract/map_data.py; map_res_load 0x587970):
--   0x00 dword 0x30 + 0x30-byte editor block | 0x34 map header: name[0x20], cols, rows, planes, objects, tail
--   0x68 cells: planes*rows*cols × 28 B {co, piece, bank, frame, shape, -, -}  (index (rows*z+y)*cols+x, 32 px)
--   then objects: 60-byte record {id, x, y, depth, code, -, u16 sub, -, nA, nB, nC, nD, variant, tint, -}
--                 + A[nA] dwords, B[nB] × 12 B, C[nC] × 256 B, D[nD] × 8 B.
-- Zone devices (doors): code 70102 = press-Up door, A[0] = zone id → the room record's exit for that zone.
-- Characters (50000s): A[1] = talk handle (actor +0x1d8; < 1000 = local + 1000 × room), A[4] facing,
--                      A[6] presence class (9 = always, never culled near the arrival gate).
local S = mod.game.script
local SND = mod.game.sound

local HOUSE, HOUSE_MAP = 210140, 1025          -- Arche's house (DATA 1025, 34×20)
local TEMPLATE, TEMPLATE_MAP = 210141, 1026    -- the back room (DATA 1026, 20×20): kind / tileset / BGM of a house room
local HALL, HALL_MAP = 210142, 4001            -- ours: unused room ids + unused DATA ids
local ARENA, ARENA_MAP = 210143, 4002
local DOOR_ZONE = 4                            -- the house's new zone (retail uses 1..3 there)
local WIDEN = 10                               -- the hall: 10 more 2-column wall panels (20 → 40 columns)

-- talk handles (≥ 1000: absolute, not remapped per room; no dramatist row → each code's default look)
local H = { GUIDE = 990001, MERCHANT = 990002, INN = 990003, WARP = 990004, BARD = 990005, ARENA = 990006,
            SHELF = 990010 }
local QUIZ_FLAG = 990001001                    -- story flag: the quiz prize was taken (saved with the game)

-- ── little-endian helpers (LuaJIT = Lua 5.1: no string.pack) ──────────────────────────────────────────────────
local function u32(s, o) local a, b, c, d = s:byte(o + 1, o + 4); return a + b * 256 + c * 65536 + d * 16777216 end
local function i32(s, o) local v = u32(s, o); return v >= 2147483648 and v - 4294967296 or v end
local function p32(v)
  v = v % 4294967296
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function ints(s, o, n) local t = {} for i = 1, n do t[i] = i32(s, o + 4 * (i - 1)) end return t end
local function pack(t) local r = {} for i = 1, #t do r[i] = p32(t[i]) end return table.concat(r) end

-- ── map: parse / edit / serialize ─────────────────────────────────────────────────────────────────────────────
local Map = {}
Map.__index = Map
function Map.parse(blob)
  local m = setmetatable({}, Map)
  m.head = blob:sub(1, 0x68)
  m.cols, m.rows, m.planes = u32(blob, 0x54), u32(blob, 0x58), u32(blob, 0x5c)
  local n = u32(blob, 0x60)
  m.cells = {}
  local pos = 0x68
  for i = 1, m.cols * m.rows * m.planes do m.cells[i] = ints(blob, pos, 7); pos = pos + 28 end
  m.objs = {}
  for _ = 1, n do
    local r = ints(blob, pos, 15)
    local na, nb, nc, nd = r[8], r[9], r[10], r[11]
    local o = { rec = r, A = ints(blob, pos + 0x3c, na), B = ints(blob, pos + 0x3c + na * 4, nb * 3) }
    local q = pos + 0x3c + na * 4 + nb * 12
    o.C = blob:sub(q + 1, q + nc * 256); o.D = blob:sub(q + nc * 256 + 1, q + nc * 256 + nd * 8)
    m.objs[#m.objs + 1] = o
    pos = q + nc * 256 + nd * 8
  end
  assert(pos == #blob, "map: trailing bytes")
  return m
end
function Map:cell(z, y, x) return self.cells[(self.rows * z + y) * self.cols + x + 1] end
function Map:set_cell(z, y, x, v) self.cells[(self.rows * z + y) * self.cols + x + 1] = v end
function Map:serialize()
  local out = { self.head:sub(1, 0x54), p32(self.cols), self.head:sub(0x59, 0x60), p32(#self.objs), self.head:sub(0x65, 0x68) }
  for i = 1, #self.cells do out[#out + 1] = pack(self.cells[i]) end
  for _, o in ipairs(self.objs) do
    local r = o.rec
    r[8], r[9], r[10], r[11] = #o.A, #o.B / 3, #o.C / 256, #o.D / 8
    out[#out + 1] = pack(r); out[#out + 1] = pack(o.A); out[#out + 1] = pack(o.B)
    out[#out + 1] = o.C; out[#out + 1] = o.D
  end
  return table.concat(out)
end
function Map:find(pred) for _, o in ipairs(self.objs) do if pred(o) then return o end end end
function Map:filter(pred) local k = {} for _, o in ipairs(self.objs) do if pred(o) then k[#k + 1] = o end end self.objs = k end
function Map:next_id() local n = 0 for _, o in ipairs(self.objs) do if o.rec[1] > n then n = o.rec[1] end end return n + 1 end
-- Insert `copies` copies of the columns [c0, c0 + w) right after them: every plane, every row.  Objects right of
-- the insertion point move right by the inserted width.  (The wall panels repeat every 2 columns, so a 2-column
-- slice of plain panels on every floor widens the room seamlessly.)
function Map:widen(c0, w, copies)
  local cols, add = self.cols, w * copies
  local nc = {}
  for z = 0, self.planes - 1 do
    for y = 0, self.rows - 1 do
      for x = 0, cols + add - 1 do
        local sx
        if x < c0 + w then sx = x
        elseif x < c0 + w + add then sx = c0 + (x - c0 - w) % w
        else sx = x - add end
        nc[(self.rows * z + y) * (cols + add) + x + 1] = { unpack(self:cell(z, y, sx)) }
      end
    end
  end
  self.cells, self.cols = nc, cols + add
  for _, o in ipairs(self.objs) do
    if o.rec[2] >= (c0 + w) * 32 then o.rec[2] = o.rec[2] + add * 32 end
  end
end
local function clone(o)
  return { rec = {unpack(o.rec)}, A = {unpack(o.A)}, B = {unpack(o.B)}, C = o.C, D = o.D }
end

local function read_map(id)
  local mm = mod.sym.va("map_module")
  local h = mm and mod.mem.read_u32(mm) or 0
  return mod.res.read("DATA", id, h ~= 0 and h or nil)
end

-- ── Arche's house + a door ────────────────────────────────────────────────────────────────────────────────────
-- The ground-floor wall = 2-column plain panels (piece 113015, bank 2220) and 4-column feature panels (113035,
-- bank 2230; frame 4 = the front door, 7 = the arched window, 11 = the back-room door; co = 10870 + 10 × frame).
-- The right end is behind the staircase (plane 1, piece 113040), so the new door goes on the LEFT wall: columns
-- 1 + 3 (two plain panels; column 1 carries the wall's left-edge flag) become one back-door panel, left of the
-- front door.  Its press-Up zone sits where the back-room door's sits in its panel (panel x + 32 px) on the
-- ground-floor line (y 544).  The shop props standing in front of that wall (shelves, jars, the plant: structures,
-- code < 70000, and the shelf 70353) move out; the script zones (70105) stay.
local function build_house()
  local raw = read_map(HOUSE_MAP)
  if not raw then return nil, "DATA " .. HOUSE_MAP .. " not found" end
  local m = Map.parse(raw)
  local back, left = m:cell(0, 13, 17), m:cell(0, 13, 1)     -- the back-room door panel, the left plain panel
  assert(back[2] == 113035 and back[4] == 11 and left[2] == 113015, "house map: unexpected wall panels")
  m:set_cell(0, 13, 1, { back[1], back[2], back[3], back[4], left[5], 0, 0 })
  m:set_cell(0, 13, 3, { 0, 0, 0, 0, 0, 0, 0 })
  m:filter(function(o)                                 -- the props + the shelf (70353) in front of that wall
    local r = o.rec
    return not ((r[5] < 70000 or r[5] == 70353) and r[2] < 160 and r[3] >= 400)
  end)
  local door = clone(m:find(function(o) return o.rec[5] == 70102 and o.A[1] == 2 end))
  door.rec[1] = m:next_id()
  door.rec[2] = 1 * 32 + 32                            -- 64
  door.A[1] = DOOR_ZONE
  -- FIRST in the object list: zone_pass takes the first live zone actor overlapping the leader and stops there even
  -- when that zone has no exit — the house's script zones (70105, ids 901–905) run along the ground floor, 905 at
  -- x 96 inside this door's box.  The stock doors come before them in the list (lower actor slots); appended last,
  -- ours only fired on its left edge.
  table.insert(m.objs, 1, door)
  return m:serialize()
end

-- ── the hall and the arena ────────────────────────────────────────────────────────────────────────────────────
-- Both start from the back room's map minus its containers' / switches' handles (they drive 210141's own scripts):
-- walls, props and both doors (zone 2 ground floor, 3 middle floor) stay.
local function template()
  local raw = read_map(TEMPLATE_MAP)
  if not raw then return nil, "DATA " .. TEMPLATE_MAP .. " not found" end
  local m = Map.parse(raw)
  for _, o in ipairs(m.objs) do                         -- furniture stays, inert: no talk / search handle
    if o.rec[5] >= 70000 and o.rec[5] ~= 70102 and #o.A >= 2 then o.A[2] = 0 end
  end
  return m
end

-- The hall: columns 3–4 (a plain panel on every floor, the floor beams, the ground strip) repeated WIDEN times —
-- 40 columns, 1280 px.  The cast stands on the ground floor (feet y 544) between the left bookshelf and the door
-- (now x 1088).  Each NPC = the house's townswoman record (50240) with another code / handle / place.
local CAST = {   -- code, x, handle, facing (0 right, 1 left)
  { 50240, 960, H.GUIDE, 1 },      -- Tester: Arche's mom's model
  { 50160, 832, H.MERCHANT, 1 },   -- a moustached townsman
  { 50290, 704, H.INN, 1 },        -- a maid
  { 50300, 576, H.WARP, 1 },       -- the green witch
  { 50212, 448, H.BARD, 1 },       -- a blonde girl
  { 50150, 320, H.ARENA, 0 },      -- a hunter
}
local function build_hall()
  local m, err = template()
  if not m then return nil, err end
  local house = Map.parse(read_map(HOUSE_MAP))
  local npc0 = house:find(function(o) return o.rec[5] == 50240 end)
  m:widen(3, 2, WIDEN)
  for _, c in ipairs(CAST) do
    local npc = clone(npc0)
    npc.rec[1] = m:next_id()
    npc.rec[5] = c[1]
    npc.rec[2], npc.rec[3] = c[2], 480                -- ground floor (feet on y 544)
    npc.A[2] = c[3]
    npc.A[5] = c[4]                                     -- facing: 0 = right, ≠ 0 = left
    npc.A[7] = 9                                        -- always present, never culled near the gate
    m.objs[#m.objs + 1] = npc
  end
  -- the ground-floor bookshelf (70353 at x 32, y 448) gets a handle: examining it runs our book
  local shelf = m:find(function(o) return o.rec[5] == 70353 and o.rec[3] == 448 end)
  if shelf then shelf.A[2] = H.SHELF end
  return m:serialize()
end
local function build_arena()
  local m, err = template()
  if not m then return nil, err end
  -- the ground floor cleared for the fight: the props standing on it go (the floors, walls and doors stay)
  m:filter(function(o) local r = o.rec return not (r[5] < 70000 and r[3] >= 400) end)
  return m:serialize()
end

-- ── sounds (synthesized here: nothing shipped) ────────────────────────────────────────────────────────────────
local RATE = 22050
local function tone(out, freq, dur, vol)
  local n = math.floor(dur * RATE)
  for i = 1, n do
    local t = i / RATE
    local env = math.min(1, i / 200) * math.exp(-4 * t / dur)
    out[#out + 1] = vol * env * (math.sin(2 * math.pi * freq * t) + 0.3 * math.sin(4 * math.pi * freq * t))
  end
end
local function melody(notes, vol)
  local s = {}
  for _, n in ipairs(notes) do
    if n[1] == 0 then for _ = 1, math.floor(n[2] * RATE) do s[#s + 1] = 0 end else tone(s, n[1], n[2], vol or 0.35) end
  end
  return SND.add(SND.wav(s, RATE))
end
local SFX = {}
local function make_sounds()
  SFX.chime = melody({ { 1318.5, 0.12 }, { 1568, 0.12 }, { 2093, 0.35 } })                         -- E6 G6 C7
  SFX.fanfare = melody({ { 523.3, 0.12 }, { 659.3, 0.12 }, { 784, 0.12 }, { 1046.5, 0.4 }, { 0, 0.05 },
                         { 784, 0.12 }, { 1046.5, 0.6 } })
  SFX.sad = melody({ { 392, 0.25 }, { 370, 0.25 }, { 349.2, 0.25 }, { 329.6, 0.7 } })
end

-- ── the scripts ────────────────────────────────────────────────────────────────────────────────────────────────
local talks = {}
local function count(h) talks[h] = (talks[h] or 0) + 1 return talks[h] end

S.on_talk(H.GUIDE, function(s)
  if count(H.GUIDE) == 1 then
    s:say("Oh! A visitor! You found the door that wasn't there yesterday.")
    s:say("Welcome to the Mod Hall. Everything in here is the game's own machinery, driven by a Lua mod.")
  end
  while true do
    local c = s:choose({ "What is this place?", "Who are these people?", "Give me a quiz!", "Goodbye" })
    if c == 1 then
      s:say("This room didn't exist until the mod loader built it from the house's own tiles.\nThe door you came through was added to your house the same way.")
      s:say("Nothing here ships with the mod: the maps are made from your copy of the game at startup.")
    elseif c == 2 then
      s:say("Everyone here shows off a different part of the game: the merchant's shop, the inn, the warp, the music, the arena.")
      s:say("Oh, and the bookshelf by the left wall. Try examining it.")
    elseif c == 3 then
      local right = 0
      local q = {
        { "How many columns wide is this hall?", { "20", "40", "64" }, 2 },
        { "What does a mod script talk to the game through?", { "Magic", "The game's own functions", "Carrier pigeons" }, 2 },
        { "Which of these is a slime?", { "Green Slime", "Org Sworder", "Kobold" }, 1 },
      }
      for i, qq in ipairs(q) do
        s:narrate(("Question %d: %s"):format(i, qq[1]))
        local a = s:choose(qq[2], { no_cancel = true })
        if a == qq[3] then right = right + 1; s:sound(SFX.chime) else s:sound(SFX.sad) end
      end
      if right == #q then
        s:sound(SFX.fanfare)
        if mod.game.flags.story.get(QUIZ_FLAG) then
          s:say("All right again! The prize was already yours, though.")
        else
          s:say("All correct! Here, a prize.")
          s:give(3, 5)                                  -- 5 gold coins (500 CP), retail's "obtained" message
          mod.game.flags.story.set(QUIZ_FLAG, 1)        -- saved with the game
        end
      else
        s:say(("%d out of %d. Try again any time!"):format(right, #q))
      end
    else
      break
    end
  end
  s:say("Enjoy the hall!")
end, { name = "Tester" })

S.on_talk(H.MERCHANT, function(s)
  s:say("Rare goods from all over the kingdom! Have a look.")
  s:shop({ 110161, 110092, 110150, 120091, 150050, 164050, 201040, 201012, 202010 })
  s:say("Come again!")
end, { name = "Merchant" })

local INN_PRICE = 2000                                  -- CP (20 silver)
S.on_talk(H.INN, function(s)
  local c = s:choose({ "A room for the night", "Storage box", "Nothing" })
  if c == 1 then
    s:inn {                                             -- the game's own inn: its price window, payment, rest, heal
      price = INN_PRICE,
      offer = "A room for the night is %d copper. Will you stay?",
      decline = "Maybe another time, then.",
      broke = "Oh dear, you don't have enough money.",
      morning = "Good morning! Did you sleep well?",
      bye = "Come back any time!",
    }
  elseif c == 2 then
    s:storage()
  else
    s:say("Take care!")
  end
end, { name = "Innkeeper" })

local DESTS = {
  { "Arche's house", HOUSE, DOOR_ZONE },
  { "Barness Hills", 280110, 0 },
  { "Flower field north of Chartreux", 420125, 0 },
}
S.on_talk(H.WARP, function(s)
  s:say("I can send you anywhere I've been. Careful: travelling ahead of the story can confuse it.")
  local items = {}
  for i, d in ipairs(DESTS) do items[i] = d[1] end
  items[#items + 1] = "Stay here"
  local c = s:choose(items)
  local d = c and DESTS[c]
  if not d then s:say("Another time.") return end
  s:say(("To %s, then. Hold still!"):format(d[1]))
  s:sound(SFX.chime)
  S.after(function() mod.game.map.warp(d[2], d[3], true) end)   -- after the event: a warp armed during one is lost
end, { name = "Warp Mage" })

S.on_talk(H.BARD, function(s)
  s:say("Want to hear something? Some of these the game already knows; the others I made up just now.")
  local list = {
    { "Chime (made in Lua)", SFX.chime }, { "Fanfare (made in Lua)", SFX.fanfare }, { "Sad trombone (made in Lua)", SFX.sad },
    { "Stock sound 5", 5 }, { "Stock sound 12", 12 }, { "Stock sound 40", 40 }, { "Stock sound 100", 100 },
  }
  while true do
    local items = {}
    for i, l in ipairs(list) do items[i] = l[1] end
    items[#items + 1] = "That's enough"
    local c = s:choose(items)
    if not c or not list[c] then break end
    s:sound(list[c][2])
    s:wait(600)
  end
  s:say("Thanks for listening!")
end, { name = "Bard" })

-- the arena: a wave chosen here, spawned when the party arrives in 210143, a reward cutscene when it is cleared
local WAVES = {
  { "Slimes (easy)", { 51010, 51011, 51010 }, 2 },
  { "Kobolds (normal)", { 51030, 51030, 51031 }, 5 },
  { "Orgs (hard)", { 51100, 51120, 51110 }, 12 },
}
local arena = { wave = nil, slots = nil, cleared = 0 }
S.on_talk(H.ARENA, function(s)
  s:say("Looking for a fight? The arena is through here. Pick your opponents.")
  local items = {}
  for i, w in ipairs(WAVES) do items[i] = w[1] end
  items[#items + 1] = "Not now"
  local c = s:choose(items)
  if not c or not WAVES[c] then s:say("Come back when you're ready.") return end
  s:say("Good luck! Leave through the door when you're done.")
  arena.wave, arena.slots = WAVES[c], nil
  S.after(function() mod.game.map.warp(ARENA, 2, true) end)
end, { name = "Arena Master" })

local function reward(w)
  return function(s)
    s:sound(SFX.fanfare)
    s:narrate(("The %s are beaten!"):format(w[1]:match("^(%S+)"):lower()))
    s:give(3, w[3])                                     -- w[3] gold coins
    s:narrate("Leave through the door to return to the hall.")
  end
end
local function arena_tick()
  local m = mod.game.map.get()
  if not m or m.area ~= ARENA then
    if arena.slots then arena.slots = nil end           -- left mid-fight: the wave is gone with the room
    return
  end
  if mod.game.map.event() then return end
  if arena.wave and not arena.slots then                -- just arrived: the wave comes in from the left
    arena.slots = {}
    for i, code in ipairs(arena.wave[2]) do
      local slot = mod.game.actors.spawn(code, { x = (120 + 90 * i) * 100, y = 54400, facing = 1 })
      if slot then arena.slots[#arena.slots + 1] = slot end
    end
    return
  end
  if arena.slots and #arena.slots > 0 then
    local alive = {}
    for _, a in ipairs(mod.game.actors.list() or {}) do alive[a.slot] = a end
    for _, sl in ipairs(arena.slots) do if alive[sl] then return end end
    local w = arena.wave
    arena.wave, arena.slots = nil, nil
    arena.cleared = arena.cleared + 1
    S.run(reward(w), { what = "arena reward" })
  end
end

S.on_talk(H.SHELF, function(s)
  s:book("The Modder's Handbook", {
    "Chapter 1: Doors\n\nA door is an invisible zone device in front of a door-shaped wall panel. Press Up in it, and the room's exit table says where you go.",
    "Chapter 2: Rooms\n\nA room is a record in the area table plus a map resource. The loader adds both; the game loads them like its own.",
    "Chapter 3: People\n\nEveryone you can talk to carries a handle. When you talk to them, the game asks every script whether that handle is theirs. Ours answer in Lua.",
    "Chapter 4: Everything else\n\nShops, inns, books, choices, gifts: the game already knows how to do all of these. A mod only has to ask.",
  })
end)

-- ── install ────────────────────────────────────────────────────────────────────────────────────────────────────
local function install()
  if read_map(HALL_MAP) or read_map(ARENA_MAP) then return mod.log("testroom: DATA 4001/4002 already exist in the game — refusing") end
  local house, e1 = build_house()
  local hall, e2 = build_hall()
  local ar, e3 = build_arena()
  if not house or not hall or not ar then return mod.log("testroom: " .. tostring(e1 or e2 or e3)) end
  mod.res.set("DATA", HOUSE_MAP, house)
  mod.res.set("DATA", HALL_MAP, hall)
  mod.res.set("DATA", ARENA_MAP, ar)
  assert(mod.game.map.add_room { key = HALL, like = TEMPLATE, map = HALL_MAP })
  assert(mod.game.map.add_room { key = ARENA, like = TEMPLATE, map = ARENA_MAP, town = false })   -- hits do damage
  assert(mod.game.map.set_exit(HOUSE, DOOR_ZONE, HALL, 2))   -- house door → the hall's ground-floor door
  assert(mod.game.map.set_exit(HALL, 2, HOUSE, DOOR_ZONE))   -- hall doors → back through the new house door
  assert(mod.game.map.set_exit(HALL, 3, HOUSE, DOOR_ZONE))
  assert(mod.game.map.set_exit(ARENA, 2, HALL, 2))           -- arena doors → the hall
  assert(mod.game.map.set_exit(ARENA, 3, HALL, 2))
  make_sounds()
  mod.on_frame(arena_tick)
  mod.log(("testroom: house %d B, hall %d B (DATA %d), arena %d B (DATA %d)"):format(#house, #hall, HALL_MAP, #ar, ARENA_MAP))
end

_G.testroom = { Map = Map, read_map = read_map, talks = function(h) return talks[h or H.GUIDE] or 0 end, arena = arena,
                ROOM = HALL, HALL = HALL, ARENA = ARENA, HOUSE = HOUSE, H = H, SFX = SFX, NPC_HANDLE = H.GUIDE }
install()
