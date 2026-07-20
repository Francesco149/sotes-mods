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
| `sotes_trainer` | EN-SE Trainer | Teleport / god / map graph / warps / dialogue-skip + a Dear ImGui UI. |

## Status

**WIP.** `autoload` has its first loader-based release (`autoload-1.0.0`). `dashboard` is
source-ready (`mods/dashboard/`) and `ennse_voice` + `sotes_trainer` are still being
**ported** from their originals in `../OpenSummoners/tools/{ennse_voice,sotes_trainer}`, so
their `registry.json` `versions[]` stay empty until released.

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
