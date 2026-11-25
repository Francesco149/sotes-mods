-- testroom — proof of concept for custom content (loader api 1.7):
--   * a NEW DOOR in Arche's house (210140, ground floor, left of the front door),
--   * leading to a CUSTOM ROOM (210142) — a new room record + a map built from stock tiles,
--   * with a custom NPC (talk script: see below).
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

local HOUSE, HOUSE_MAP = 210140, 1025          -- Arche's house (DATA 1025, 34×20)
local TEMPLATE, TEMPLATE_MAP = 210141, 1026    -- the back room (DATA 1026, 20×20): kind / tileset / BGM of a house room
local ROOM, ROOM_MAP = 210142, 4001            -- ours: an unused room id + an unused DATA id
local DOOR_ZONE = 4                            -- the house's new zone (retail uses 1..3 there)
local NPC_HANDLE = 990001                      -- ≥ 1000: absolute (not remapped per room); no dramatist row → default look

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
  local out = { self.head:sub(1, 0x60), p32(#self.objs), self.head:sub(0x65, 0x68) }
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
local function clone(o)
  local c = { rec = {unpack(o.rec)}, A = {unpack(o.A)}, B = {unpack(o.B)}, C = o.C, D = o.D }
  return c
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

-- ── the test room ─────────────────────────────────────────────────────────────────────────────────────────────
-- The back room's map, minus its containers / switches (their handles drive 210141's own scripts): its walls,
-- props and both doors (zone 2 ground floor, 3 middle floor) stay; both doors lead back to the house's new door.
-- Plus one NPC on the ground floor: a townswoman model (code 50240 = Arche's mom's model; our handle has no
-- dramatist row, so the code's default look is used).
local function build_room()
  local raw = read_map(TEMPLATE_MAP)
  if not raw then return nil, "DATA " .. TEMPLATE_MAP .. " not found" end
  local house = Map.parse(read_map(HOUSE_MAP))
  local m = Map.parse(raw)
  for _, o in ipairs(m.objs) do                         -- furniture stays, inert: no talk / search handle
    if o.rec[5] >= 70000 and o.rec[5] ~= 70102 and #o.A >= 2 then o.A[2] = 0 end
  end
  local npc = clone(house:find(function(o) return o.rec[5] == 50240 end))
  npc.rec[1] = m:next_id()
  npc.rec[2], npc.rec[3] = 224, 480                    -- ground floor (feet on y 544), left of the door
  npc.A[2] = NPC_HANDLE
  npc.A[5] = 0                                         -- facing: 0 = right (≠ 0 = left)
  npc.A[7] = 9                                         -- always present, never culled near the gate
  m.objs[#m.objs + 1] = npc
  return m:serialize()
end

-- ── the NPC's talk script ──────────────────────────────────────────────────────────────────────────────────────
-- Talking (attack / V next to an NPC) runs touch_pass → event_run(mode 2) → script_engine (0x40c380 / SE 0x40a0c0),
-- a hard-coded chain of per-chapter script functions that each test the room record, the event mode (+0x14) and
-- the talked-to actor's handle (ev +0x4 → actor +0x1d8).  Ours = a typed pre-hook on script_engine that claims
-- (room, mode 2, NPC_HANDLE) and runs the beat retail's own talk scripts run (chs_49f7c0, the Arche's house
-- talks): script_begin → camera on the leader → party cast → stance → face each other → messages → script_end,
-- through the retail primitives (thiscall on the event runner; script_wait runs the frames, 6 = skipped / quit).
local ffi = require("ffi")
local P = {}
local function prim(name, sig)
  local va = mod.sym.va(name)
  if not va then error("testroom: symbol " .. name .. " unavailable on " .. tostring(mod.edition)) end
  P[name] = ffi.cast(sig, va)
end
local function bind_prims()
  prim("script_begin", "void (__thiscall *)(void *)")
  prim("script_end", "void (__thiscall *)(void *)")
  prim("script_leader", "void *(__thiscall *)(void *)")
  prim("script_party_cast", "void (__thiscall *)(void *)")
  prim("script_wait", "int (__thiscall *)(void *)")
  prim("scene_party_stance", "int (__thiscall *)(void *, int, void *)")
  prim("scene_talk_face", "int (__thiscall *)(void *, int, void *, int, int)")
  prim("scene_msg", "void (__thiscall *)(void *, uint32_t, void *, const char *, int, int, int, const char *, int, int, uint32_t)")
end

local NPC_NAME = "Tester"
local LINES = {
  "Oh! A visitor! You found the door that wasn't there yesterday.",
  "This room is a test: a map the mod loader built from the game's own tiles, behind a door it added to your house.",
  "And I'm a test too. My words come from a Lua script, through the game's own message window.",
}
local talks = 0

local function u32p(p, off) return ffi.cast("uint32_t *", ffi.cast("uint8_t *", p) + off) end
local function camera_on_leader(ev)                    -- ev +0x4c..+0x5c: pan to the leader; +0x20 = 3 (camera)
  local lead = P.script_leader(ev)
  u32p(ev, 0x4c)[0] = 0; u32p(ev, 0x5c)[0] = ffi.cast("uint32_t", lead)
  u32p(ev, 0x50)[0] = 0; u32p(ev, 0x54)[0] = 0; u32p(ev, 0x58)[0] = 800
  u32p(ev, 0x20)[0] = 3
end

local function talk(ev)
  local actor = ffi.cast("void *", u32p(ev, 0x4)[0])
  P.script_begin(ev)
  camera_on_leader(ev)
  P.script_party_cast(ev)
  if P.script_wait(ev) == 6 then return 6 end
  if P.scene_party_stance(ev, 0, ffi.cast("void *", u32p(ev, 0x8)[0])) ~= 0 then
    if P.script_wait(ev) == 6 then return 6 end
  end
  P.scene_talk_face(ev, 0, actor, 1, 1)
  if P.script_wait(ev) == 6 then return 6 end
  camera_on_leader(ev)
  if P.script_wait(ev) == 6 then return 6 end
  talks = talks + 1
  local lines = talks == 1 and LINES or { ("You've talked to me %d times now. Still here, still a test."):format(talks) }
  for _, text in ipairs(lines) do
    P.scene_msg(ev, 0, actor, text, 0, 1, 0, NPC_NAME, 0, 0, 0)
    if P.script_wait(ev) == 6 then return 6 end
  end
  P.script_end(ev)
  return 0
end

local function install_talk()
  bind_prims()
  mod.hook.typed(mod.sym.va("script_engine"), "int __thiscall(void *)", {
    pre = function(ctx)
      local ev = ctx.args[1]
      if u32p(ev, 0x14)[0] ~= 2 then return end                      -- mode 2 = talk / examine
      local m = mod.game.map.get()
      if not m or m.area ~= ROOM then return end
      local actor = u32p(ev, 0x4)[0]
      if actor == 0 or ffi.cast("int32_t *", ffi.cast("uint8_t *", actor) + 0x1d8)[0] ~= NPC_HANDLE then return end
      ctx.blocked = true
      ctx.ret = talk(ev)
    end,
  })
end

local function install()
  if read_map(ROOM_MAP) then return mod.log("testroom: DATA " .. ROOM_MAP .. " already exists in the game — refusing") end
  local house, e1 = build_house()
  local room, e2 = build_room()
  if not house or not room then return mod.log("testroom: " .. tostring(e1 or e2)) end
  mod.res.set("DATA", HOUSE_MAP, house)
  mod.res.set("DATA", ROOM_MAP, room)
  assert(mod.game.map.add_room { key = ROOM, like = TEMPLATE, map = ROOM_MAP })
  assert(mod.game.map.set_exit(HOUSE, DOOR_ZONE, ROOM, 2))   -- house door → arrive at the room's ground-floor door
  assert(mod.game.map.set_exit(ROOM, 2, HOUSE, DOOR_ZONE))   -- room doors → back through the new house door
  assert(mod.game.map.set_exit(ROOM, 3, HOUSE, DOOR_ZONE))
  install_talk()
  mod.log(("testroom: house %d B, room %d B (DATA %d), room %d ⇄ %d zone %d"):format(#house, #room, ROOM_MAP, ROOM, HOUSE, DOOR_ZONE))
end

_G.testroom = { Map = Map, read_map = read_map, talks = function() return talks end, ROOM = ROOM, HOUSE = HOUSE, NPC_HANDLE = NPC_HANDLE }
install()
