# odin-overgrowth-engine

A third-person melee combat engine in [Odin](https://odin-lang.org), built in the
spirit of **[Overgrowth](https://github.com/WolfireGames/overgrowth)** by Wolfire
Games — fluid locomotion, animation-driven fighters, full-body ragdolls, and
physics-rich arena combat. Clean-room implementation: no Wolfire code, no
Overgrowth assets, no third-party art is included in this repo.

Inspiration and credit:

- **Overgrowth (Wolfire Games)** — the design north star: momentum-based
  character movement, seamless animation-to-ragdoll transitions, and melee
  combat where every hit has physical weight. Overgrowth's source is
  Apache-2.0 at the link above; this project studies its ideas, not its code.
- **[Jolt Physics](https://github.com/jrouwe/JoltPhysics)** — rigid-body
  simulation behind every ragdoll, crate, and thrown sword.
- **[raylib](https://www.raylib.com)** (via Odin's `vendor` bindings) —
  windowing, rendering, audio, and input.
- **[joltc-odin](https://github.com/jrdurandt/joltc-odin)** — Odin bindings
  for Jolt (MIT). Required alongside this repo (see Build).

## What is implemented

- **Bumper-sphere locomotion** — acceleration-based movement with exponential
  bleed, slope stick/align, step tolerance, wall-block, edge walk-off.
- **Animation state machine** — idle / run / air / land / slash / kick clips,
  stride-matched run rate, one-shot jump/land clocks, cross-file clip blending
  with cross-rig retarget (rotation + bind-relative translation transfer).
- **Full-body ragdoll** — 11 Jolt bodies per fighter, swing-twist joint
  limits, kinematic-to-dynamic handoff with per-limb kicks, pinned
  animation-on-recover with cross-fade.
- **Melee combat** — slash (sword) and kick with strike windows, juggles,
  blocks, dodges, grabs, throws, disarm/pickup, HP + K.O. + respawn as next
  challenger, team scoring.
- **AI perception** — sight cones with line-of-sight, hearing via a noise
  ring, last-known tracking with forget timers, sneak that hides past 6 m.
- **Arena + terrain** — glTF terrain with baked heightfield grounding, static
  prop colliders (AABBs with Jolt twins), vault/walljump, camera with
  terrain pull-in.
- **Determinism harness** — scripted `auto` and `autoai` demo modes with
  checked-in baselines, so refactors prove zero behavior change.
- **Presentation** — HUD announcements, file-based SFX bank, footstep stride
  audio, wind music bed, pause/menu flow, gamepad support (Overgrowth layout).

## Repo contents

- `spike22/` — the engine. One Odin package (`package spike22`), 13 files:
  `main`, `fighter`, `locomotion`, `combat`, `anim`, `pose`, `ragdoll`,
  `terrain`, `arena`, `input`, `particles`, `sfx`, `math_util`.
- `docs/RIG_SPEC.txt` — the rig/asset contract. Any mesh set following it
  works with the animation, retarget, ragdoll, and IK systems.
- `spike22_baseline.txt`, `spike22_autoai_baseline.txt` — expected
  headless-demo output for the determinism check.

Deliberately NOT in this repo: game assets (meshes, textures, sounds),
screenshots, binaries, and the Overgrowth reference material used during
development.

## Requirements

- Odin nightly compiler (`odin version`), on PATH.
- Windows with MSVC `link.exe` + Windows SDK (VS 2022 Build Tools,
  `NativeDesktop` workload, works).
- `joltc-odin` cloned as a sibling: `thirdparty/joltc-odin` next to
  `spike22/` (the code imports `../thirdparty/joltc-odin`), plus its
  prebuilt `joltc.dll` / `raylib.dll` beside the exe at runtime.
- Your own assets in `assets/` (see below). Nothing ships here.

## Build

From the repo root (Odin builds a package directory):

    odin build spike22 -out:spike22/spike22.exe -collection:lib="thirdparty/joltc-odin/lib" -extra-linker-flags:"/FORCE:MULTIPLE"

(`/FORCE:MULTIPLE` is expected: `raylib.lib` embeds its own cgltf.
LNK4006/LNK4088 from it are noise; treat other errors as real.)

Run from `spike22/` so the relative `../assets/` paths resolve:

    cd spike22
    ./spike22.exe          # play
    ./spike22.exe auto     # scripted demo, must match spike22_baseline.txt
    ./spike22.exe autoai   # scripted player + live AI brains

Determinism check (after any change): diff `auto` output against
`spike22_baseline.txt` — empty diff, modulo raylib `INFO`/`WARNING` engine
lines and the `sfx: N sounds` init line, which drifts as wavs are added.

## Assets (bring your own)

The engine loads its cast from `../assets/` at runtime. Nothing in that
folder is committed (see `.gitignore`). Expected files:

- Fighters: `shki_base.glb` (+ `shki_albedo.png`), `lunk_base.glb`
  (+ `lunk_albedo.png`, `lunk_normal.png`) — base meshes.
- Clips: `shki_idle.glb`, `shki_run.glb`, `shki_jump.glb`,
  `shki_slash.glb`, `shki_death.glb` — one action per file, same rig.
- Props: `sword.glb` (+ `sword_albedo.png`, `sword_normal.png`),
  `landscape.glb` (+ `land_albedo.png`, `land_normal.png`), arena sets.
- Audio: `assets/sfx/` wavs (`swipe`, `sword_slice`, `kick`, ...,
  `ambient_wind.wav`).

Authoring rules (one shared skeleton, node order, bind pose, facing, clip
conventions) are the whole game — read `docs/RIG_SPEC.txt` before exporting
anything. Missing audio files are silent, never a crash.

## Controls

Keyboard + mouse, gamepad on pad 0 (Overgrowth layout):

    WASD / arrows ... move (double-tap = dodge)
    Space / A ....... jump
    J / left click .. slash (RT on pad)
    K / right click . kick (LT on pad)
    F ............... grab (counter/throw follow-ups)
    G ............... throw sword
    E / X ........... pick up
    C / L3 .......... sneak
    Shift / LB ...... guard
    R / Y ........... ragdoll, T / B = recover
    ESC ............. pause, Enter = confirm, T = rematch detail

## Status

Active prototype: single arena, 2v1 + ally escort scenario, systems breadth
first — feel numbers (damage, guard strength, volumes) are explicitly
deferred tuning. The remaining Overgrowth-system checklist: disarm + pickup
polish, sneak expansion, landing roll, ledge-grab climb, blood decals,
AI surrender/flee.

## License

Engine code here is original work, all rights reserved for now — no license
file yet, so default copyright applies until one lands. Third-party pieces
you supply alongside it keep their own licenses (Jolt, joltc-odin MIT,
raylib, Overgrowth Apache-2.0 for reference only).
