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
| `autoload` | Auto-Load Save | Launch straight into a save (config: `slot`). Orchestrates the loader's `mod.game.save` op. |
| `ennse_voice` | Japanese Voice Patch (EN-SE) | English text + Japanese dialogue voices. You supply `sotesx_s.dll` from your own JP copy. |
| `sotes_trainer` | EN-SE Trainer | Teleport / god / map graph / warps / dialogue-skip + a Dear ImGui UI. |

## Status

The mod-loader-based versions are being **ported** from their originals in
`../OpenSummoners/tools/{ennse_voice,sotes_trainer}` (loader phases P6/P7). Until the
first release lands, `registry.json`'s `versions[]` are empty — the metadata is in place
so the launcher can be developed against a real source.

## Layout

```
registry.json     the mod source manifest (the launcher reads this)
mods\<id>\         each mod's source (init.lua + assets), when ported
```
