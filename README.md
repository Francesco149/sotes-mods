# sotes-mods

Francesco149's mods for *Fortune Summoners*, packaged for the
[**SotES Mod Loader**](../sotes-mod-loader). This repo is a **mod source**: it contains
a [`registry.json`](registry.json) the loader's launcher reads to install + update these
mods package-manager style. It ships as the loader's **default source**.

Adding this repo as a source in the launcher means you trust it to list honest files +
hashes; the launcher then verifies every downloaded file against the pinned `sha256`
(see [`../sotes-mod-loader/docs/REGISTRY.md`](../sotes-mod-loader/docs/REGISTRY.md)).

## Mods

| id | name | what |
|---|---|---|
| `dashboard` | Loader Dashboard | The **stock loader UI**: every built-in `mod.game.*` module with an enable/disable toggle (a crash valve), persisted, + live roster stats. Recommended default. |
| `autoload` | Auto-Load Save | Launch straight into a save (config: `slot`). Orchestrates the loader's `mod.game.save` op. |
| `ennse_voice` | Japanese Voice Patch (EN-SE) | English text + Japanese dialogue voices. You supply `sotesx_s.dll` from your own JP copy. |
| `trainer` | Trainer | God mode / heal / gold / teleport to the cursor (F7) / warp to any room / give any item, every edition — over the loader's sandbox ops (api 1.2). Panels in the loader UI; `_G.trainer` for agents. Unreleased (0.1.0). |
| `testroom` | Test Room | Proof of concept for custom content (loader api 1.10): a new door in Arche's house leads to the Mod Hall, a new room built from stock tiles where NPCs drive the game's own systems from Lua (shop, inn, books, warps, synthesized sounds), plus custom sprites — a recoloured NPC, Bit (a new character type under its own code, placed by the map: own sprite sheet + animations + a 13-second dance to his own tune) and the Glitch Cube (a new monster type: own sheet + Lua behaviours). The custom sprites live in sprite banks past the game's own. Maps are built at load from your own game data; the only shipped art is the mod's own (`bit.bmp`, `cube.bmp`, drawn by `art/make_art.py`). Unreleased (0.4.0). |

## Status

**WIP.** `autoload` and `dashboard` have loader-based releases (`autoload-1.0.0`,
`dashboard-1.0.0`); `ennse_voice` is still being **ported** from `../OpenSummoners/tools/ennse_voice`; `trainer`
(the v2 rewrite of `../OpenSummoners/tools/sotes_trainer`) is in `mods/trainer` — both keep
`registry.json` `versions[]` empty until released.

## Releases

Each mod version is published as a **GitHub release** on this repo, tagged `<id>-<version>`
(e.g. `autoload-1.0.0`), with the mod's files (`init.lua`, `mod.toml`, …) as the release
assets. `registry.json` points each version's `files[]` at those assets and pins their
`sha256`, so the launcher verifies every download against the hash it trusts.

This repo is both the **source** and the **registry**, but they're independent: a download
`url` can point anywhere, so another mod dev may keep a repo as a **registry only** and host
the mod source + files elsewhere (any GitHub release or CDN). You trust the registry you add;
the pinned hashes guarantee integrity regardless of who hosts the bytes.

## Layout

```
registry.json     the mod source manifest (the launcher reads this)
mods\<id>\         each mod's source (init.lua + assets), when ported
```
