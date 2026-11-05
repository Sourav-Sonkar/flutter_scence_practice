# Worm Swarm Creature (flutter_scene)

## Context
The YouTube Short (@neenerdev, "THIS ENEMY IS TERRIFYING") shows ~100–200 red worms that act as one
creature: they chase a target, pile on top of each other into a writhing mass, climb up onto a table
and spill/drip back down over its edges. Goal: rebuild that effect in this Flutter project with
`flutter_scene` 0.22.2, on the new branch `feature/worm-swarm` (already created, nothing committed).

The current app (`lib/main.dart` → `CakeDemo` in `lib/declarative_screen.dart`) is a declarative
demo. A swarm is a per-frame physics simulation, so per the flutter_scene-idioms skill it must be
**imperative**: own a `Scene`, drive it from `SceneView(onTick:)`.

## Approach in one paragraph
Each worm is a chain of 12 points simulated with **Verlet integration** (position + previous
position, no explicit velocity). Distance constraints keep the chain at fixed length, a softer
"skip-one" constraint keeps it from folding sharply. The head steers toward the target; every body
point that is touching something "crawls" toward the point ahead of it and grips walls, so the
whole worm can climb. Points collide with each other through a spatial hash grid, which is what
makes them pile into one mass. Rendering is **one `InstancedMesh` of capsules** (one capsule per
segment, ~1,760 instances) updated every frame → one draw call for the entire swarm.

## Files

### 0. `plans/worm-swarm.md` (new, first step)
Copy this plan into a `plans/` folder at the project root so it lives with the repo for later
reference, and commit it with the feature.

### 1. `lib/worms/worm_sim.dart` (new, pure Dart, no flutter_scene import)
`WormSwarmSim` class, unit-testable without a GPU.
- **State:** flat `Float32List`s for `pos`, `prev`, per-point contact flag + contact normal.
  Defaults: 160 worms × 12 points, segment length 0.055 (worm ≈ 0.6 m), radius 0.032 tapering to
  ~0.015 at the tail.
- **`step(dt)`**: fixed substeps of 1/120 s (capped at 4 per frame so a slow frame can't explode).
  Each substep:
  1. Integrate: `vel = (pos - prev) * damping`, extra friction when in contact, add gravity.
  2. Forces:
     - Head: steer toward its goal = `target + per-worm orbiting offset` (radius ≈ 0.35) so heads
       surround the target instead of all hitting one point → clump shape. Plus a sideways sine
       wiggle for the slither look.
     - Body points in contact: crawl toward the previous point; on a vertical wall, cancel gravity
       (grip) so worms can climb.
     - Head on a wall with goal above it: extra upward climb force.
  3. Constraints (3 iterations): segment distance, skip-one bend distance.
  4. Worm-vs-worm collisions via a uniform hash grid (cell = 2× max radius), skipping
     neighbours on the same worm. Contact with another worm also counts as "supported", so worms
     crawl over each other.
  5. World collisions: ground plane `y = 0`, the solid bench box (push out on least-penetration
     axis, record normal), and an arena boundary.
- **Target:** `setTargetGoal(Vector3)`; the actual target eases toward the goal at a capped speed
  so the swarm can keep up and stretch into a stream when it moves fast.
- **Autopilot:** when there's been no touch for ~3 s, the goal follows a slow Lissajous path that
  crosses onto and off the bench, so the climb/spill behaviour demos itself.

### 2. `lib/worms/worm_swarm_view.dart` (new, flutter_scene + Flutter)
`WormSwarmView` StatefulWidget.
- `Scene.initializeStaticResources()` in `initState`, then build:
  - Ground: `PlaneGeometry` with a grey PBR material + grid lines as one more `InstancedMesh` of
    thin `CuboidGeometry` strips (gives motion reference like the video's tiled floor; no texture
    assets needed).
  - Bench: `CuboidGeometry` (≈1.6 × 0.55 × 1.0) matching the sim's collision box exactly.
  - Worms: `InstancedMesh(CapsuleGeometry(radius 0.032, height = segment length),
    PhysicallyBasedMaterial red, roughness ~0.3)`; per-instance color varies brightness per worm.
  - Target: small emissive sphere (cyan) so it glows under bloom.
  - `scene.directionalLight = DirectionalLight(castsShadow: true, …)` and an
    `EnvironmentSettings` based on the looks skill "showcase" preset (ACES, ambient occlusion so
    the pile reads as a mass, light bloom for the target).
- `onTick(elapsed, dt)`: `sim.step(dt)` then `updateInstanceTransforms` — for each segment build a
  matrix: translate to midpoint, rotate local +Y onto the segment direction, scale XZ by taper and
  Y by stretch. Writes straight into the existing `Matrix4`s (no allocation per frame).
- Input: `GestureDetector` pan/tap → `camera.screenPointToRay` → intersect bench top first, then
  ground → `sim.setTargetGoal`. Fixed `PerspectiveCamera` looking down at the arena.
- Small FPS overlay (smoothed `dt`, refreshed ~4×/s via `ValueNotifier`), like the video.

### 3. `lib/main.dart` (edit)
Home becomes `WormSwarmView()`. `CakeDemo` and `FirstScene` stay untouched in the codebase.

### 4. `test/worm_sim_test.dart` (new)
Pure-Dart tests on `WormSwarmSim` (small worm count, many steps):
- segment lengths stay within ~10% of rest length;
- no point ends below the ground or inside the bench;
- average head distance to target shrinks after the target moves;
- a target on the bench top eventually gets worms onto the bench (climbing works).

## Decisions taken (tell me if you want otherwise)
- **Solid bench instead of a table with legs.** Worms climb its walls and spill off its edges.
  A table with thin legs makes the climbing logic much harder (worms get stuck under the top);
  it can be a follow-up.
- **Capsule chains, not smooth deforming tubes.** Overlapping capsules read as smooth worms and
  cost one draw call. Per-worm `TubeGeometry` rebuilt each frame would be 160 draws plus heavy CPU.
- **Spheres/worms are not real physics-engine bodies.** flutter_scene ships a physics barrel, but
  1,920 rigid bodies with joints is far heavier than a custom Verlet chain, and the look comes
  from the steering rules anyway.
- Numbers (160 worms, 12 points, forces) are starting values; tuning happens while watching it run.

## Verification
1. `flutter analyze` clean; `flutter test test/worm_sim_test.dart` passes.
2. Run on macOS: `fvm flutter run -d macos --enable-flutter-gpu` (project pins FVM `master`).
3. Visual check with the flutter_scene-verification-loop skill (screenshots): worms render red and
   lit, not black/see-through; swarm follows dragged target; worms pile into a mass, climb the
   bench, drape and fall off edges.
4. Profile mode (`--profile`) FPS check; if UI thread is over budget, lower worm count or
   collision iterations first.
5. Commit on `feature/worm-swarm` once it looks right.

---

## How it works in flutter_scene
- **Worms are dots on a string.** Each worm is 16 points. Each point stores its position
  and its previous position (Verlet integration). Velocity is the difference, so there is
  no rotation and no rigid-body solver. This is the Short's "dots and string" trick.
- **String.** After moving, each pair of neighbouring points is pushed back to the rest
  length, and points two apart are kept from getting too close so the worm can't fold.
- **Crawl AI.** Each head steers to its own slot around the target, with a sideways sine
  wiggle. Body points touching anything crawl toward the point ahead, and grip walls so
  the worm can climb. The Short uses "every dot crawls to the player", which is the same idea.
- **Worm against worm.** Points go into a spatial grid of cells about one worm-thickness
  wide. Each point checks only nearby cells, which is the Short's grid trick. Touching
  another worm counts as support, so worms climb over each other and the pile grows.
- **World collision.** The floor and the block are simple shapes, checked directly. That
  is the cheap version of the Short's distance field, and it is exact for boxes.
- **Rendering.** All 2,400 capsules are one `InstancedMesh`. Every frame the app writes
  one matrix per capsule (position at the segment's middle, rotation along it, scale for
  taper) with `updateInstanceTransforms`, and flutter_scene draws them in one draw call.
  The scene uses flutter_scene's own `DirectionalLight` shadows and `EnvironmentSettings`
  post-processing, and runs inside `SceneView` with `onTick`.

## Performance (Android follow-up, 2026-11-05)
### Measurements
| Where | Before | After |
| --- | --- | --- |
| Android emulator, software GPU (SwiftShader) | about 1 FPS real (counter wrongly said 20) | not fixable in app code |
| Android emulator, host GPU (`-gpu host`) | 60 FPS spread out, 20 to 40 FPS in a dense pile (debug) | about 36 FPS dense pile in debug |
| Motorola Edge 70 Pro, profile, low preset | 49 FPS, GPU about 16 ms with a dense pile on screen | 60 FPS, physics about 5 ms, UI about 8 ms, GPU about 2 ms |
| Physics only, native code on Mac, dense pile | 3.24 ms per frame | 1.16 ms per frame |

### Why iOS was smooth and Android was not
1. The emulator was drawing in software. Its GPU mode was "auto" and it picked
   SwiftShader, so all rendering ran on the CPU. iOS Simulator draws with the Mac's real
   GPU through Metal. Fix for testing: Android Studio > Device Manager > Pixel 9 > Edit >
   Graphics: Hardware, or launch with `emulator -avd Pixel_9 -gpu host`.
2. The FPS counter lied. It clamped frame time to 0.05 s before counting, so it could
   never show below 20. The physics used the same clamp, so worms moved in slow motion.
3. Physics cost grows when worms pile up, and the old fixed-step loop ran up to 4 catch-up
   steps after a slow frame, which made the next frame slower too.
4. Debug mode on any device runs unoptimised code. Real numbers need `--profile`.

### Changes made
- `lib/worms/worm_sim.dart`
  - One physics step per frame, sized to the real frame time (clamped 1/240 to 1/30 s),
    using time-corrected Verlet so speed is the same at any frame rate. No catch-up steps.
  - Spatial grid rebuilt with a counting sort, so neighbours sit together in memory, and
    each nearby pair is visited once (own cell plus 13 "forward" neighbour cells).
  - Chain lengths re-solved after collisions so segments do not stretch.
- `lib/worms/worm_swarm_view.dart`
  - Overlay shows real FPS plus physics, UI-thread and GPU milliseconds.
  - Quality presets with a corner button. Low (default on Android and web) turns off
    ambient occlusion, bloom and the worms' clearcoat, uses one shadow cascade, FXAA and
    60% render resolution. High (default on iOS/macOS) keeps the full look.
  - Capsules use fewer triangles (8 radial segments, 2 cap rings).
- Camera framing adapts to the aspect ratio. Portrait views pull back at most 2x, then
  pan sideways to follow the target; landscape keeps the original fixed view.

### How to measure
- Use a real device in profile mode: `fvm flutter run --profile --enable-flutter-gpu`.
- The overlay shows FPS plus physics (`sim`), UI-thread (`ui`) and GPU (`gpu`) milliseconds.
- On the emulator, make sure Graphics is set to Hardware, or launch it with `-gpu host`.
