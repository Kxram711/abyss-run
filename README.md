# Abyss Run — LIGHTS OUT

Roblox co-op horror extraction-lite (squads of 2–4 descend floor-seeded levels of
the Warden Facility, sharing one Lumen pool). Design authority: the team GDD at
`/home/team/shared/gdd-lights-out.md` — structural rules (§4 systems, §7 slice
scope) are build spec; `(v1 target)` numbers are tuning starting points.

This repo currently contains the **scaffold only** — Knit runtime, service/
controller seams, and a placeholder scene. No gameplay mechanics yet.

## Project structure (Rojo)

```
default.project.json          Rojo project definition (DataModel mapping)
src/
  ReplicatedStorage/
    Packages/                 Vendored Knit 1.7.0 runtime + deps (official
                              wally bundle: Knit, Comm, Promise, Option, Signal)
  ServerScriptService/
    init.server.lua           Server entrypoint: registers services, Knit.Start()
    Services/
      LumenService            Shared squad Lumen pool, drain/regen/Darkness (§4.2)
      FloorService            Seeded floor generation, room stitching (§4.3)
      ArtifactService         Artifacts, rarity math, reward formula (§4.4)
      ExtractionService       Extract-or-push, elevator warm-up, banking (§4.7)
      RunService              Run state machine, squad, run seed (§2/§3)
      EconomyService          Filaments bank, unlocks, persistence (§4.6)
  StarterPlayer/
    StarterPlayerScripts/
      init.client.lua         Client entrypoint: registers controllers, Knit.Start()
      Controllers/
        LumenController       Lumen HUD + lumen↔world mapping binding (later)
        RunHudController      In-run HUD seams (later)
  Workspace/
    PlaceholderRoom.model.json  Dark room: spawn, dim point light, primitives
```

## Setup

1. Install the **Rojo plugin** in Roblox Studio (Rojo → Plugins).
2. Install the Rojo CLI (`aftman install` or via GitHub releases).
3. From this repo root run `rojo serve`, then in Studio open **Rojo → Connect**.
   The plugin will apply `default.project.json` and sync live.
   (Alternatively open `default.project.json` directly from the Rojo plugin menu.)
4. Edit `src/` — every save syncs to Studio. Play in Studio to test the scene.

## Conventions

- Luau, `--!strict` where practical.
- Client/server split: services in `ServerScriptService`, controllers in
  `StarterPlayer/StarterPlayerScripts`, shared code in `ReplicatedStorage`.
- Knit: services/controllers register via `Knit.CreateService` /
  `Knit.CreateController`; the entrypoint scripts `require` each module before
  `Knit.Start()`. Keep client-visible surface explicit on the `Client` table.

## Vendored packages

`src/ReplicatedStorage/Packages` is the official Knit 1.7.0 runtime (Sleitnick,
MIT) installed via wally and checked in for zero-setup builds: Knit 1.7.0 +
Comm 1.0.1 + Promise 4.0.0 + Option 1.0.5 + Signal 2.0.3. Do not hand-edit
vendored files; re-install via wally and re-copy if an upgrade is needed.
