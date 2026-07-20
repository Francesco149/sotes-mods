-- dashboard — the stock loader UI.
--
-- Lists every built-in mod.game.* module with an enable/disable toggle (a CRASH VALVE: if a module
-- misbehaves, turn it OFF from the UI without touching the loader), persisted across launches, plus
-- live readouts of the modules' data (roster stats, ...).  It's a default-enabled MOD, not core, so
-- the loader stays lightweight — the dashboard is just UI over the core's mod.game registry.
--
-- The panel callbacks run on the ENGINE thread (see examples/ui_demo): the loader records their output
-- into a lock-free snapshot the UI thread replays, so they may read game state directly.

local ui, game, cfg = mod.ui, mod.game, mod.config

-- ── persisted toggles: a CSV of DISABLED module ids, stored in mod.config (oss_mods.cfg) ──────────
local function load_disabled()
  local set, csv = {}, cfg.get("disabled")
  if type(csv) == "string" then
    for id in csv:gmatch("[^,]+") do set[id:match("^%s*(.-)%s*$")] = true end
  end
  return set
end
local function save_disabled(set)
  local ids = {}
  for id, off in pairs(set) do if off then ids[#ids + 1] = id end end
  table.sort(ids)
  cfg.set("disabled", table.concat(ids, ","))
end

-- Apply the saved state at boot: a module keeps its default unless the user turned it off before.
local disabled = load_disabled()
if game and game.list then
  local n = 0
  for _, m in ipairs(game.list()) do
    if disabled[m.id] then game.disable(m.id); n = n + 1 end
  end
  if n > 0 then mod.log("dashboard: restored " .. n .. " disabled module(s) from config") end
else
  mod.log("dashboard: mod.game unavailable (not a SotES target?) — nothing to show")
end

-- ── panel: the module toggles (collapsed by default — it's a long list you rarely touch) ──────────
ui.panel("Modules", function()
  if not (game and game.list) then ui.text_disabled("mod.game unavailable on this target"); return end
  ui.text("Built-in loader modules — untick one if it misbehaves:")
  ui.separator()
  for _, m in ipairs(game.list()) do
    local on, changed = ui.checkbox(m.id, m.enabled)
    if changed then
      if on then game.enable(m.id) else game.disable(m.id) end
      disabled[m.id] = (not on) or nil          -- rebuild + persist the disabled set
      save_disabled(disabled)
      mod.log("dashboard: " .. m.id .. " -> " .. (on and "ENABLED" or "DISABLED") .. " (saved)")
    end
    if m.desc and m.desc ~= "" then ui.text_disabled("    " .. m.desc) end
  end
end, true)   -- 3rd arg = collapsed by default

-- ── panel: live roster readout (an example of surfacing a module's data) ──────────────────────────
ui.panel("Roster", function()
  if not (game and game.enabled and game.enabled("roster")) then
    ui.text_disabled("roster module is OFF — enable it under Modules"); return
  end
  local ok, party = pcall(function() return game.roster.members() end)
  if not (ok and party and #party > 0) then
    ui.text_disabled("no party loaded — load a save to see live stats"); return
  end
  ui.text(string.format("party: %d member(s)", #party))
  ui.separator()
  for _, m in ipairs(party) do
    ui.text(string.format("%s%s", m.name, m.active and "   (active)" or ""))
    ui.text_disabled(string.format("    Lv %d   (combat %d / adventurer %d)",
      m.char_level, m.combat_level, m.adventurer_level))
    ui.text_disabled(string.format("    hp %d/%d   mp %d/%d", m.hp, m.hp_max, m.mp, m.mp_max))
    -- stats as the status screen shows them: effective (with equipment) / base
    ui.text_disabled(string.format("    atk %d/%d   def %d/%d", m.attack, m.attack_base, m.defense, m.defense_base))
    ui.text_disabled(string.format("    spi %d/%d   res %d/%d", m.spirit, m.spirit_base, m.resist, m.resist_base))
    ui.text_disabled(string.format("    exp %d/%d   pos (%d, %d)", m.exp, m.exp_max, m.x, m.y))
  end
end)

mod.log("dashboard: armed — open the loader window (F8) to toggle modules")
