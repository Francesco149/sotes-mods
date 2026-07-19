-- autoload — load a save at boot.
--
-- The RE'd menu-drive (title -> save-picker -> confirm, attract-mode freeze) lives in the LOADER as
-- mod.game.save; this mod just orchestrates it and exposes the slot as config.  A core feature that
-- became a mod (was the built-in `autoload=1` flag).  Runs at init on the engine thread.

local slot = mod.config.get("slot")

if mod.game.save and mod.game.save.load then
  local ok = mod.game.save.load(slot)   -- drive the menus into the save (slot < 0 = newest); attract
  mod.log(ok and ("autoload: loading save slot " .. slot .. " ...")   -- is frozen during the drive,
                or "autoload: a drive is already running")            -- restored when the scene loads
else
  mod.log("autoload: mod.game.save not available (not a SotES target?) — nothing to do")
end
