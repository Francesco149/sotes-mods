-- testroom — proof of concept for custom content (loader api 1.10):
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
--       Bit              a NEW character: its own sprite sheet (bit.bmp, original art drawn by art/make_art.py), its
--                        own animations (idle / wave / walk / dance clips), a patrol driven from Lua
--   * new character types (mod.game.actors.define): Bit and the Glitch Cubes have codes of their own (50990, 51990,
--     51991) — the map places Bit by his, the arena spawns cubes by theirs
--   * custom sprites (mod.game.sprites): the Tester wears a recoloured copy of her stock sheet (built at load from the
--     user's own data), Bit is drawn from the mod's own BMP, and the arena's Glitch Cubes are a NEW monster: the
--     slime's body and AI under an original sheet (cube.bmp, same pose layout), with behaviours added in Lua —
--     glitch-teleporting next to the leader, blinking faster when hurt, splitting in two when killed.
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
            BIT = 990007, SHELF = 990010 }
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
-- (loader api 1.11: an EDIT of the house map through mod.game.maps — it composes with other mods' edits of the same
-- map, and is served for the map module only)
local function edit_house(m)
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
-- A character record's x / y = the TOP-LEFT OF ITS SPRITE CELL: char_init hangs the body in the cell (x centred, the
-- feet on the cell's bottom row), so feet = y + the sheet's cell height — and that height differs per character
-- (townsfolk 96, the tall ones — guard, witch — 128, children 80).  Retail's maps follow it: in the opening town
-- (DATA 1022) the guard's record is at y 384 and a townswoman's at 416 for the same street (feet 512); children
-- sit at y % 32 == 16.  One y for everyone leaves the tall ones a tile deep in the floor (their bodies start inside
-- it, so nothing pushes them out), while a short one just drops onto it.
local FLOOR = 576                                -- the ground floor's walk line, px (the leader's feet)
local CAST = {   -- code, x, handle, facing (0 right, 1 left), sprite cell height
  { 50240, 960, H.GUIDE, 1, 96 },      -- Tester: Arche's mom's model
  { 50160, 832, H.MERCHANT, 1, 96 },   -- a moustached townsman
  { 50290, 704, H.INN, 1, 96 },        -- a maid
  { 50300, 576, H.WARP, 1, 128 },      -- the green witch
  { 50212, 448, H.BARD, 1, 80 },       -- a blonde girl
  { 50150, 320, H.ARENA, 0, 128 },     -- a hunter
  { 50990, 192, H.BIT, 0, 96 },        -- Bit: a NEW character code (actors.define below: a townswoman underneath)
}
local BIT_CODE, CUBE_CODE, CUBELET_CODE = 50990, 51990, 51991   -- new character types (unused codes in 50001..59999)
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
    npc.rec[2], npc.rec[3] = c[2], FLOOR - c[5]       -- feet on the ground floor
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
  SFX.beep = melody({ { 880, 0.06 }, { 0, 0.03 }, { 1320, 0.08 }, { 0, 0.02 }, { 990, 0.06 } }, 0.25)
  -- Bit's dance tune: 64 eighth notes of 0.2 s (12.8 s) — a square-ish lead over a bass on every beat
  local N = { C4 = 261.6, D4 = 293.7, E4 = 329.6, F4 = 349.2, G4 = 392, A4 = 440, B4 = 493.9, C5 = 523.3, D5 = 587.3,
              E5 = 659.3, F5 = 698.5, G5 = 784, A5 = 880, C6 = 1046.5 }
  local lead = {
    "C5", "E5", "G5", "E5", "C5", "E5", "G5", 0, "A5", "G5", "E5", "G5", "A5", "G5", "E5", 0,          -- sway
    "F5", "A5", "C6", "A5", "F5", "A5", "C6", 0, "G5", "E5", "D5", "E5", "G5", "E5", "D5", 0,          -- moonwalk
    "C5", 0, "C5", "E5", "G5", 0, "G5", "E5", "A5", 0, "A5", "G5", "E5", 0, "D5", "E5",                -- wave
    "C5", "D5", "E5", "F5", "G5", "A5", "G5", "A5", "C6", "A5", "G5", "E5", "C6", "G5", "C6", "C6",    -- fast
  }
  local bass = { "C4", "C4", "A4", "A4", "F4", "F4", "G4", "G4", "C4", "C4", "A4", "E4", "C4", "E4", "G4", "C4" }
  local d, step = {}, math.floor(0.2 * RATE)
  for i, n in ipairs(lead) do
    local f, fb = N[n], N[bass[math.floor((i - 1) / 4) + 1]] / 2
    local o = (i - 1) * step
    for k = 1, step do
      local t = k / RATE
      local v = 0.16 * math.exp(-5 * (((i - 1) % 2) * 0.2 + t)) * math.sin(2 * math.pi * fb * (((i - 1) % 2) * 0.2 + t))
      if f then
        local w = math.sin(2 * math.pi * f * t)
        v = v + 0.2 * math.min(1, k / 150) * math.exp(-7 * t) * (w + 0.4 * (w > 0 and 1 or -1))
      end
      d[o + k] = v
    end
  end
  for k = 1, math.floor(0.6 * RATE) do                   -- the last chord rings out
    local t = k / RATE
    d[#d + 1] = 0.2 * math.exp(-5 * t) * (math.sin(2 * math.pi * 523.3 * t) + math.sin(2 * math.pi * 659.3 * t) + math.sin(2 * math.pi * 784 * t)) / 2
  end
  SFX.dance = SND.add(SND.wav(d, RATE))
  -- the Glitch Cube's blink: a downward burst of stepped noise
  local g, seed, held = {}, 12345, 0
  for i = 1, math.floor(0.28 * RATE) do
    if i % 40 == 1 then seed = (seed * 1103515245 + 12345) % 2147483648; held = (seed / 2147483648) * 2 - 1 end
    local t = i / RATE
    local sq = (math.floor(t * (1400 - 3600 * t)) % 2 == 0) and 1 or -1
    g[i] = 0.28 * math.exp(-6 * t) * (0.6 * held + 0.4 * sq)
  end
  SFX.glitch = SND.add(SND.wav(g, RATE))
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
      s:say("This room didn't exist until the mod loader built it from the house's own tiles.")
      s:say("The door you came through was added to your house the same way.")
      s:say("None of the game's files ship with the mod: the maps are made from your copy of the game at startup.")
      s:say("Like my dress? It's my usual one, recoloured by the mod.")
      s:say("Bit over there is new. The mod drew every pixel of him!")
    elseif c == 2 then
      s:say("Everyone here shows off a different part of the game: the merchant's shop, the inn, the warp, the music, the arena.")
      s:say("And Bit, by the bookshelf, is a brand-new character with his own sprite and animations.")
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
  { "Glitch Cubes (a new monster)", { CUBE_CODE, CUBE_CODE }, 8 },
}
local arena = { wave = nil, slots = nil, cleared = 0, cubes = {}, pending = {}, typed = 0 }
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
-- ── custom sprites + the new characters (mod.game.sprites, api 1.9) ─────────────────────────────────────────────
-- Banks are made once per session (they live in the engine's sprite system, across rooms); looks and clips are put
-- on the characters every time their room loads (new actors each time).
local SPR, ACT = mod.game.sprites, mod.game.actors
local look = { banks = {}, room = nil }
local function read_file(name)
  local dir = mod.dir:match("[\\/]$") and mod.dir or mod.dir .. "\\"
  local f, err = io.open(dir .. name, "rb")
  if not f then mod.log("testroom: " .. tostring(err)) return nil end
  local b = f:read("*a")
  f:close()
  return b
end
local function by_handle(h) for _, a in ipairs(ACT.list() or {}) do if a.handle == h then return a end end end
local function bank(key, make)
  if look.banks[key] == nil then
    local b, err = make()
    look.banks[key] = b or false
    if not b then mod.log("testroom: no " .. key .. " sprite: " .. tostring(err)) end
  end
  return look.banks[key] or nil
end
-- the Tester's dress, rose instead of blue: her own sheet (the user's data) with a palette edit
local function guide_bank(src)
  return bank("guide", function()
    local img, err = SPR.sheet(src)
    if not img then return nil, err end
    for i = 1, 255 do
      local r, g, b = img.pal[i][1], img.pal[i][2], img.pal[i][3]
      if b > r + 20 and b >= g then img.pal[i] = { b, math.floor(g * 0.7), math.floor(r * 0.8) } end
    end
    return SPR.new_bank { like = src, image = img }
  end)
end
-- a sheet the mod ships (original art): `like` = the stock bank whose cell grid / mirror offset it follows
local function bmp_bank(key, file, like)
  return bank(key, function()
    local b = read_file(file)
    if not b then return nil, file .. " missing" end
    local img, err = SPR.bmp(b)
    if not img then return nil, err end
    return SPR.new_bank { like = like, image = img }
  end)
end
local function body_of(p) return mod.mem.read_u32(p + 0x40) end
local function place(p, x, y)                          -- body top-left, centi-px
  local b = body_of(p)
  mod.mem.write_i32(b + 4, x)
  if y then mod.mem.write_i32(b + 8, y) end
end
local function face(p, dir) mod.mem.write_u32(body_of(p) + 0x2c, dir > 0 and 1 or 3) end

-- Bit: bit.bmp = 8 x 4 cells of 80 x 96 like the townsfolk sheets (rows 2-3 mirrored: the bank's offset 16)
local bit = { mode = "patrol" }
local BITC
local function bit_clips()
  BITC = BITC or {
    idle = SPR.clip { frames = { 0, 1, 2, 3 }, dur = 20 },
    wave = SPR.clip { frames = { 4, 5, 6, 7, 6, 5 }, dur = 7 },
    walk = SPR.clip { frames = { 8, 9, 10, 11, 12, 13, 14, 15 }, dur = 6 },
    dance = SPR.clip { frames = { 4, 5, 6, 7, 6, 5, 8, 10, 12, 14, 0, 2 }, dur = 5 },
    fast = SPR.clip { frames = { 4, 6, 8, 12, 5, 7, 10, 14 }, dur = 3 },
    slide = SPR.clip { frames = { 8, 9, 10, 11, 12, 13, 14, 15 }, dur = 4 },
    pose = SPR.clip { frames = { 6, 7 }, dur = 12 },
  }
  return BITC
end
-- The dance: DANCE_MS of choreography on the wall clock (the frame rate differs between machines), in step with
-- the tune's 0.2 s eighth notes: sway + spin, a moonwalk each way (walking clip, sliding backwards), a fast spin, a
-- pose.  Each part = a clip + where he stands (around the spot the dance began) + which way he faces.
local DANCE_MS = 13200
local function bit_dance(p)
  local c = bit_clips()
  local t = os.clock() - bit.t0
  local beat = math.floor(t / 0.2)
  local part, x, dir
  if t < 3.2 then                                        -- sway, turning every two beats
    part, x, dir = c.dance, 1600 * math.sin(t * math.pi / 0.8), (math.floor(beat / 4) % 2 == 0) and 1 or -1
  elseif t < 6.4 then                                    -- moonwalk: out to the right facing left, back facing right
    local u = (t - 3.2) / 1.6
    part = c.slide
    if u < 1 then x, dir = 4800 * u, -1 else x, dir = 4800 * (2 - u), 1 end
  elseif t < 9.6 then                                    -- the wave, with a hop to the side on every beat
    part, x, dir = c.wave, (beat % 2 == 0) and -1200 or 1200, (beat % 4 < 2) and 1 or -1
  elseif t < 12.4 then                                   -- the fast part: spin on every beat
    part, x, dir = c.fast, 800 * math.sin(t * math.pi / 0.4), (beat % 2 == 0) and 1 or -1
  else                                                   -- ta-da
    part, x, dir = c.pose, 0, bit.dir0
  end
  if bit.part ~= part then bit.part = part; SPR.set_clips(p, { stand = part }); SPR.play(p, part) end
  place(p, math.floor(bit.x0 + x))
  if bit.face ~= dir then bit.face = dir; face(p, dir) end
end
local function bit_tick()
  local p = bit.ptr
  if not p then return end
  if bit.mode ~= "patrol" then return end
  local c = bit_clips()
  if bit.wait > 0 then
    bit.wait = bit.wait - 1
    if bit.wait == 0 then SPR.set_clips(p, { stand = c.walk }); SPR.play(p, c.walk); face(p, bit.dir) end
    return
  end
  local x = mod.mem.read_i32(body_of(p) + 4) + bit.dir * 60
  place(p, x)
  if (bit.dir > 0 and x >= bit.home + 7200) or (bit.dir < 0 and x <= bit.home - 6400) then
    bit.dir = -bit.dir
    bit.wait = 150 + math.random(0, 150)
    SPR.set_clips(p, { stand = c.idle }); SPR.play(p, c.idle)
  end
end
local function hall_tick()
  local m = mod.game.map.get()
  if not m or m.area ~= HALL then look.room, bit.ptr = nil, nil return end
  local g = by_handle(H.GUIDE)
  if g and look.room ~= g.ptr then                       -- the hall (re)loaded: new actors
    look.room = g.ptr
    local gb = guide_bank(mod.mem.read_u16(g.ptr + 0x48))
    if gb then SPR.set_look(g, gb) end
    local b = by_handle(H.BIT)                             -- his look / clips / name came with his type (BIT_CODE)
    if b then bit.ptr, bit.home, bit.dir, bit.wait, bit.mode = b.ptr, b.x, 1, 120, "patrol" end
  end
  if bit.ptr and bit.mode == "dance" then bit_dance(bit.ptr) end   -- during the talk event: per frame, on the clock
end

S.on_talk(H.BIT, function(s)
  local p, c = bit.ptr, bit_clips()
  bit.mode = "talk"
  if p then SPR.set_clips(p, { stand = c.wave }); SPR.play(p, c.wave) end
  s:sound(SFX.beep)
  s:say("Beep boop! Hello! I'm Bit.")
  s:say("The game has never seen me before: the mod painted my pixels and taught me how to move.")
  if p then SPR.set_clips(p, { stand = c.idle }) end
  while true do
    local k = s:choose({ "Show me a dance!", "How were you made?", "Bye, Bit!" })
    if k == 1 then
      s:say("Music, please!")
      if p then
        bit.x0, bit.dir0 = mod.mem.read_i32(body_of(p) + 4), mod.mem.read_u32(body_of(p) + 0x2c) == 1 and 1 or -1
        bit.t0, bit.part, bit.face, bit.mode = os.clock(), nil, nil, "dance"
      end
      s:sound(SFX.dance)
      s:wait(DANCE_MS)
      bit.mode = "talk"
      if p then
        bit.took = os.clock() - bit.t0
        place(p, bit.x0); face(p, bit.dir0)
        SPR.set_clips(p, { stand = c.idle }); SPR.play(p, c.idle)
      end
      s:say("Ta-da! Each of those moves is a clip the mod built: which cells to show, and for how long.")
    elseif k == 2 then
      s:say("My sprite sheet is a plain 8-bit BMP that ships with the mod: sixteen poses, then the same ones facing left.")
      s:say("The loader turns it into one of the game's own sprite banks, and I borrow a townsperson's body to stand in.")
      s:say("My walk is a little Lua script. Left, right, rest, repeat. Riveting stuff.")
    else
      break
    end
  end
  s:sound(SFX.beep)
  s:say("Bye! Beep!")
  bit.mode, bit.wait = "patrol", 60
  if p then SPR.set_clips(p, { stand = c.idle }); SPR.play(p, c.idle) end
end, { name = "Bit" })

-- The Glitch Cube: a slime underneath (its body, hops and attacks: retail's AI), wearing cube.bmp — the slime
-- sheet's pose layout (4 x 12 cells of 80 x 80, mirror offset 24) in original art.  Lua adds the rest:
--   * every few seconds it blinks: vanishes and reappears right behind the leader (sooner when hurt)
--   * killed, a full-size cube splits into two smaller ones (gen 1: less HP, they don't split again)
-- Both are character TYPES of their own (actors.define): the code picks the slime underneath, the type brings the
-- sheet, the name, the HP and the Lua behaviours — spawned like any other code.
local function cube_bank(p) return bmp_bank("cube", "cube.bmp", mod.mem.read_u16(p + 0x48)) end
local function cube_tick(a)
  local cu = arena.cubes[a.ptr]
  if not cu then cu = { cd = 200 + math.random(0, 140) }; arena.cubes[a.ptr] = cu end
  cu.cd = cu.cd - 1
  if cu.cd > 0 then return end
  local leader
  for _, o in ipairs(ACT.list() or {}) do if o.leader then leader = o end end
  local hp, max = ACT.hp(a)
  local hurt = hp * 2 < max
  if leader and (hurt or math.abs((a.x + a.w / 2) - (leader.x + leader.w / 2)) > 8000) then
    local behind = leader.facing == 3 and 1 or -1         -- the side the leader has its back to
    place(a.ptr, math.floor(leader.x + leader.w / 2 + behind * 5600 - a.w / 2), math.floor(leader.y + leader.h - a.h))
    face(a.ptr, -behind)                                   -- facing the leader's back
    SND.play(SFX.glitch)
  end
  cu.cd = (hurt and 110 or 260) + math.random(0, 60)
end
local function define_types()
  assert(ACT.define { code = CUBE_CODE, base = 51010, name = "Glitch Cube", hp = 60, bank = cube_bank, on_tick = cube_tick,
    on_death = function(a)                                 -- the split, 40 frames on, where it fell
      arena.cubes[a.ptr], arena.typed = nil, arena.typed - 1
      arena.pending[#arena.pending + 1] = { at = 40, x = a.x + a.w / 2, y = a.y + a.h }
    end })
  assert(ACT.define { code = CUBELET_CODE, base = 51010, name = "Glitch Bit", hp = 24, bank = cube_bank, on_tick = cube_tick,
    on_death = function(a) arena.cubes[a.ptr], arena.typed = nil, arena.typed - 1 end })
  assert(ACT.define { code = BIT_CODE, base = 50240, name = "Bit",
    bank = function(p) return bmp_bank("bit", "bit.bmp", mod.mem.read_u16(p + 0x48)) end,
    clips = { stand = bit_clips().idle, walk = bit_clips().walk, run = bit_clips().walk } })
end
local function cubes_tick()
  for i = #arena.pending, 1, -1 do                       -- the split: two Glitch Bits where the cube fell
    local pd = arena.pending[i]
    pd.at = pd.at - 1
    if pd.at <= 0 then
      table.remove(arena.pending, i)
      SND.play(SFX.glitch)
      for k = 0, 1 do
        local sl = ACT.spawn(CUBELET_CODE, { x = math.floor(pd.x + (k == 0 and -2400 or 2400)), y = math.floor(pd.y), facing = k == 0 and 3 or 1 })
        if sl then arena.typed = arena.typed + 1 end
        if sl and arena.slots then arena.slots[#arena.slots + 1] = sl end
      end
    end
  end
end

local function arena_tick()
  local m = mod.game.map.get()
  if not m or m.area ~= ARENA then
    if arena.slots then arena.slots = nil end           -- left mid-fight: the wave is gone with the room
    arena.cubes, arena.pending, arena.typed = {}, {}, 0
    return
  end
  if mod.game.map.event() then return end
  if arena.wave and not arena.slots then                -- just arrived: the wave comes in from the left
    arena.slots = {}
    for i, code in ipairs(arena.wave[2]) do
      local slot = mod.game.actors.spawn(code, { x = (120 + 90 * i) * 100, y = 54400, facing = 1 })
      if slot then
        arena.slots[#arena.slots + 1] = slot
        if ACT.defined(code) then arena.typed = arena.typed + 1 end
      end
    end
    return
  end
  cubes_tick()
  if #arena.pending > 0 or arena.typed > 0 then return end   -- a type's death (and its split) is reported on the
                                                             -- game's tick, a beat after its slot empties
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
  local MAPS = mod.game.maps
  local hall, e2 = build_hall()
  local ar, e3 = build_arena()
  if not hall or not ar then return mod.log("testroom: " .. tostring(e2 or e3)) end
  assert(MAPS.edit(HOUSE_MAP, edit_house, "testroom"))
  assert(MAPS.define(HALL_MAP, hall, "testroom"))
  assert(MAPS.define(ARENA_MAP, ar, "testroom"))
  local house = MAPS.bytes(HOUSE_MAP)
  assert(mod.game.map.add_room { key = HALL, like = TEMPLATE, map = HALL_MAP })
  assert(mod.game.map.add_room { key = ARENA, like = TEMPLATE, map = ARENA_MAP, town = false })   -- hits do damage
  assert(mod.game.map.set_exit(HOUSE, DOOR_ZONE, HALL, 2))   -- house door → the hall's ground-floor door
  assert(mod.game.map.set_exit(HALL, 2, HOUSE, DOOR_ZONE))   -- hall doors → back through the new house door
  assert(mod.game.map.set_exit(HALL, 3, HOUSE, DOOR_ZONE))
  assert(mod.game.map.set_exit(ARENA, 2, HALL, 2))           -- arena doors → the hall
  assert(mod.game.map.set_exit(ARENA, 3, HALL, 2))
  make_sounds()
  define_types()
  mod.on_frame(hall_tick)                                -- looks: as soon as a room is up, events included
  S.on_tick(function() bit_tick() arena_tick() end)      -- what moves or counts: the game's own 60 Hz tick
  mod.log(("testroom: house %d B, hall %d B (DATA %d), arena %d B (DATA %d)"):format(#house, #hall, HALL_MAP, #ar, ARENA_MAP))
end

_G.testroom = { Map = Map, read_map = read_map, talks = function(h) return talks[h or H.GUIDE] or 0 end, arena = arena,
                ROOM = HALL, HALL = HALL, ARENA = ARENA, HOUSE = HOUSE, H = H, SFX = SFX, NPC_HANDLE = H.GUIDE,
                look = look, bit = bit, dir = mod.dir }
install()
