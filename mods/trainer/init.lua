-- trainer — cheats + sandbox over the loader's mod.game ops (api 1.4), every edition.
--
-- Nothing here pokes the game by hand: god / heal = roster.set, teleport = coordinates.set, warp =
-- map.warp (the warp item's own request), items = items.give (the game's own room_item_add), gold =
-- items.set_gold, dialogue skip = dialogue.skip (the game's own held-TAB skip), spawn / despawn = actors.spawn /
-- remove (the game's own summon_spawn / char_unload; codes limited to what the edition's char_init takes).  UI callbacks and on_frame run on the engine thread, where those writes are allowed.

local ui, game, cfg = mod.ui, mod.game, mod.config
local ffi = require('ffi')
ffi.cdef [[ short __stdcall GetAsyncKeyState(int vKey); ]]
local user32 = ffi.load('user32')

local function party() local ok, p = pcall(game.roster.members); return ok and p or {} end
local function leader() for _, m in ipairs(party()) do if m.active then return m end end end
local msg, msg_t = "", 0
local function say(s) msg, msg_t = s, mod.frame and mod.frame() or 0; mod.log("trainer: " .. s) end

-- ── per-frame: god mode + the teleport key ────────────────────────────────────────────────────────
local key_was = false
local function teleport_to_cursor()
  local m, ld = game.mouse.get(), leader()
  if not (m and m.over and m.world_x and ld) then return say("teleport: cursor not over the game / no party") end
  -- the body box: put its feet under the cursor (box top-left = x, y; w +0xc, h +0x10)
  local body = mod.mem.read_u32(ld.actor + game.roster.layout.ent_body) or 0
  local w, h = mod.mem.read_i32(body + 0xc) or 0, mod.mem.read_i32(body + 0x10) or 0
  local ok, why = game.coordinates.set(nil, m.world_x - math.floor(w / 2), m.world_y - h)
  say(ok and ("teleported to %d, %d"):format(m.world_x, m.world_y) or ("teleport: " .. tostring(why)))
end
mod.on_frame(function()
  local skip = cfg.get("skip_dialogue") and true or false
  if skip ~= select(1, game.dialogue.get()) then game.dialogue.skip(skip) end
  if cfg.get("god") then
    for _, m in ipairs(party()) do
      if m.hp < m.hp_max or m.mp < m.mp_max then game.roster.set(m.code, { hp = m.hp_max, mp = m.mp_max }) end
    end
  end
  local down = bit.band(user32.GetAsyncKeyState(cfg.get("teleport_key") or 118), 0x8000) ~= 0
  if down and not key_was then teleport_to_cursor() end
  key_was = down
end)

-- ── panel: cheats ─────────────────────────────────────────────────────────────────────────────────
ui.panel("Trainer", function()
  local mp = game.map.get()
  if not mp then ui.text_disabled("no scene — load a save"); return end
  ui.text(("room %d (map %d)%s"):format(mp.area, mp.map or -1, game.map.event() and "   [event running]" or ""))
  local god, ch = ui.checkbox("God mode (HP / MP stay full)", cfg.get("god"))
  if ch then cfg.set("god", god) end
  local sk, ch2 = ui.checkbox("Skip dialogue (holds TAB during events)", cfg.get("skip_dialogue"))
  if ch2 then cfg.set("skip_dialogue", sk) end
  if ui.button("Heal party") then
    for _, m in ipairs(party()) do game.roster.set(m.code, { hp = m.hp_max, mp = m.mp_max }) end
    say("party healed")
  end
  local cp, cap = game.items.gold()
  ui.text(("gold %d CP (cap %d)"):format(cp or 0, cap or 0))
  for _, d in ipairs({ 100, 1000, 10000 }) do
    if ui.small_button("+" .. d) then game.items.set_gold(cp + d) end
    ui.same_line()
  end
  if ui.small_button("max") then game.items.set_gold(cap) end
  ui.text_disabled(("F7 (key %d): teleport the controlled member to the cursor"):format(cfg.get("teleport_key") or 118))
  if msg ~= "" then ui.text_wrapped(msg) end
end)

-- ── panel: warp — the current room's exits, then any room by map ──────────────────────────────────
local maps, rooms_by_map, map_i = nil, {}, 1
local function index_rooms()
  local rs = game.map.rooms()
  if not rs then return end
  maps, rooms_by_map = {}, {}
  for _, r in ipairs(rs) do
    if r.loadable and r.key ~= 999999 then
      if not rooms_by_map[r.map] then rooms_by_map[r.map] = {}; maps[#maps + 1] = r.map end
      table.insert(rooms_by_map[r.map], r.key)
    end
  end
  table.sort(maps)
  for _, l in pairs(rooms_by_map) do table.sort(l) end
end
local function warp(key)
  local ok, why = game.map.warp(key, 0, cfg.get("force_warp"))
  say(ok and ("warp → %d"):format(key) or tostring(why))
end
local map_labels   -- combo_search labels for maps[] (built once)
ui.panel("Warp", function()
  local mp = game.map.get()
  if not mp then ui.text_disabled("no scene"); return end
  if not maps then index_rooms() end
  if not maps then return end
  local f, ch = ui.checkbox("Force (anywhere, instant)", cfg.get("force_warp"))
  if ch then cfg.set("force_warp", f) end
  local st, key = game.map.warp_status()
  if st ~= "idle" then ui.text(("%s → %d"):format(st, key)) end
  ui.text("exits of " .. mp.area .. ":")
  local here = game.map.room(mp.area)
  for _, x in ipairs(here and here.exits or {}) do
    if ui.small_button(("%d##x%d"):format(x.to, x.gate)) then warp(x.to) end
    ui.same_line()
  end
  ui.spacing()
  ui.separator()
  map_labels = map_labels or (function()
    local t = {}
    for i, m in ipairs(maps) do t[i] = ("map %d  (%d rooms)"):format(m, #rooms_by_map[m]) end
    return t
  end)()
  map_i = select(1, ui.combo_search("map", map_labels, map_i))
  local m = maps[map_i] or maps[1]
  ui.text(("map %d: %d rooms"):format(m, #rooms_by_map[m]))
  for i, k in ipairs(rooms_by_map[m]) do
    if ui.small_button(tostring(k)) then warp(k) end
    if i % 6 ~= 0 then ui.same_line() end
  end
end, true)

-- ── panel: items ──────────────────────────────────────────────────────────────────────────────────
local cat, cat_labels, item_i, count = nil, nil, 1, 1
ui.panel("Items", function()
  if not game.map.get() then ui.text_disabled("no scene"); return end
  cat = cat or game.items.catalog()
  if not (cat and #cat > 0) then ui.text_disabled("no item catalog on this build"); return end
  if not cat_labels then
    cat_labels = {}
    for i, it in ipairs(cat) do cat_labels[i] = ("%d  %s"):format(it.id, it.name) end
  end
  item_i = select(1, ui.combo_search("item", cat_labels, item_i))
  local it = cat[item_i] or cat[1]
  count = select(1, ui.slider_int("count (0 = default)", count, 0, 99))
  if ui.button("Give") then
    local idx, why = game.items.give(it.id, count)
    say(idx and ("gave %s (slot %d)"):format(it.name, idx) or tostring(why))
  end
  ui.text_disabled(("inventory: %d records"):format(#(game.items.list() or {})))
end, true)

-- ── panel: spawn — any character code the edition's char_init takes, placed ahead of the leader ──────
local acat, acat_labels, act_i, ahead = nil, nil, 1, 60
local function spawn(code, dx)
  local slot, why = game.actors.spawn(code, { dx = (dx or ahead) * 100 })
  say(slot and ("spawned %d (slot %d)"):format(code, slot) or tostring(why))
  return slot, why
end
ui.panel("Spawn", function()
  if not game.map.get() then ui.text_disabled("no scene"); return end
  acat = acat or game.actors.catalog()
  if not (acat and #acat > 0) then ui.text_disabled("no character codes for this build"); return end
  if not acat_labels then
    -- ImGui text is UTF-8 (no CJK glyphs): ense-jp's names are Shift-JIS, so the English column there
    acat_labels = {}
    for i, c in ipairs(acat) do
      local nm = (mod.edition == "ense-jp" and c.en) or c.name or c.en
      acat_labels[i] = ("%d  %s"):format(c.code, nm or "(no name: townsperson / prop)")
    end
  end
  act_i = select(1, ui.combo_search("character", acat_labels, act_i))
  local c = acat[act_i] or acat[1]
  ahead = select(1, ui.slider_int("ahead of the leader (px)", ahead, -320, 320))
  if ui.button("Spawn") then spawn(c.code) end
  ui.separator()
  local live, n = game.actors.list() or {}, 0
  for _, a in ipairs(live) do
    if a.spawned then
      n = n + 1
      if ui.small_button(("remove##%d"):format(a.slot)) then game.actors.remove(a.slot) end
      ui.same_line()
      ui.text(("slot %d: %d"):format(a.slot, a.code))
    end
  end
  ui.text_disabled(("%d characters in the room, %d spawned here"):format(#live, n))
end, true)

-- ── the agent API: _G.trainer (the dev server's `lua`, other mods) — same actions as the panels ──────
_G.trainer = {
  god = function(on) if on ~= nil then cfg.set("god", on and true or false) end return cfg.get("god") end,
  skip_dialogue = function(on) if on ~= nil then cfg.set("skip_dialogue", on and true or false) end return cfg.get("skip_dialogue") end,
  force_warp = function(on) if on ~= nil then cfg.set("force_warp", on and true or false) end return cfg.get("force_warp") end,
  heal = function() for _, m in ipairs(party()) do game.roster.set(m.code, { hp = m.hp_max, mp = m.mp_max }) end return true end,
  warp = function(key, gate) return game.map.warp(key, gate or 0, cfg.get("force_warp")) end,
  teleport_cursor = teleport_to_cursor,
  give = function(id, n) return game.items.give(id, n or 0) end,
  spawn = function(code, dx) return spawn(code, dx) end,   -- dx in px ahead of the leader (default: the panel's)
  despawn = function(slot) return game.actors.remove(slot) end,
  last = function() return msg end,
}

mod.log("trainer: armed (F8 / F10 for the panels; F7 teleports to the cursor)")
