# Chongqing Miniature (flutter_scene) — district 1: Yuzhong tip

## Context
After the worm swarm, the user wants a new experience: a miniature, tilt-shift style
Chongqing built from **real map data**, one small district at a time, with a way to
navigate the city. Branch `feature/chongqing-miniature` is already created from `main`
(no commits yet). It will get its own web folder on gh-pages like `worm-swarm/`.

### Data checked (read-only research)
District 1 bbox: lat 29.552–29.568, lon 106.570–106.590 (Chaotianmen / Jiefangbei tip,
~1.6 × 1.9 km).
| OpenStreetMap feature | Count |
| --- | --- |
| Buildings | 501 (only 86 have height or floor count) |
| Road segments | 694 (footway 213, steps 109, primary/secondary/tertiary 173) |
| Bridges / tunnels | 71 / 130 |
| Monorail (Line 2) / subway | 5 / 18 ways |
| Yangtze River Cableway | 2 ways + 2 stations |
| River outlines | 2 |
Elevation: AWS Terrarium tiles (`elevation-tiles-prod/terrarium/15/…`) work, ~4.8 m/px at
z15, peaks ~308 m; a few bad river pixels (-3281 m) must be clamped to river level (~170 m).

## Approach
Generate everything from data in code. No 3D artists, no runtime network.

### 1. Offline data pipeline — `tool/chongqing/` (Dart CLI)
- `fetch.dart <district>`: downloads OSM (Overpass, with User-Agent) and Terrarium tiles for
  the district bbox into `tool/chongqing/cache/` (gitignored). Districts are defined in
  `tool/chongqing/districts.dart` (name + bbox) so later districts are one entry each.
- `build.dart <district>`: converts cache → `assets/chongqing/<district>.bin` + `.json`.
  - Projection: equirectangular metres around the district centre (accurate at this size).
  - Terrain: height grid from Terrarium, clamped to river level, mesh with vertex colors.
  - Buildings: footprint polygons → walls + ear-clipped roof, base at the lowest terrain
    point under the footprint. Height order: `height` tag → `building:levels × 3.2 m` →
    hand-filled `landmarks.dart` table for named towers → heuristic from footprint area and
    building type. Per-vertex color varies by type; wall UVs drive a window-band pattern.
  - Roads/steps: ribbons draped on terrain, width by `highway` class (or `lanes`), steps darker.
  - Bridges: ribbon held at the straight line between its ends, plus piers to the ground.
    Tunnels are skipped.
  - Monorail Line 2: raised beam along the track plus pillars; Cableway: sagging cable
    between stations plus a cabin path.
  - Water: river outlines as a flat plane at river level.
  - Output is pre-triangulated Float32 arrays per layer (terrain, buildings, roads, water,
    transit) so the app only uploads buffers.
- Generated assets are committed (small) so builds need no network. OSM attribution
  ("© OpenStreetMap contributors", ODbL) is shown in the app and README.
- Dev deps: `http`, `image`.

### 2. Runtime — `lib/chongqing/`
- `city_data.dart`: loads `<district>.bin/.json` via `rootBundle`, builds
  `MeshGeometry.fromArrays` per layer (one draw per layer).
- `city_view.dart`: imperative `Scene` + `SceneView`, same pattern as
  `lib/worms/worm_swarm_view.dart` (Low/High presets, FPS overlay — reuse that code by
  moving the shared bits into `lib/shared/` only if both branches need them; this branch
  starts from main, so copy the small overlay rather than cross-branch coupling).
- Look: warm daytime sun with shadows, fog, and depth of field for the tilt-shift miniature
  effect (High preset); Low drops DoF/AO/SSR. Water uses screen-space reflections on High.
- `main.dart` home → `CityView`.

### 3. Navigation (two modes, toggle button)
- **Diorama view (default):** `OrbitCameraController` + `CameraControls` widget (drag to
  rotate, pinch/scroll to zoom, two-finger/right-drag to pan), clamped to the district,
  with tilt-shift DoF focused on the orbit target. Tap a named landmark to glide there.
- **Ride view:** camera rides Monorail Line 2 along the real track (`CatmullRomPath` from
  the OSM way), with drag-to-look.

## Decisions (confirmed with user)
- Navigation: Diorama orbit + Monorail Line 2 ride for now.
- Detail: everything generated from map data; no hand-made models (keeps download and
  load time small).

## Future scope (not in this phase)
- Cableway ride over the Yangtze.
- Street walk: third-person character on streets and steps, with joystick.
- Free-fly drone camera.
- Hand-made `.glb` models for a few landmarks (Hongyadong, Raffles City) if more detail is
  wanted later.
- Night mode: emissive windows + bloom, day-to-night blend.
- More districts (Jiefangbei west, Hongyadong riverside, Nan'an across the river), loaded
  as separate assets.

## Files
- New: `tool/chongqing/{districts,fetch,build,landmarks}.dart`, `assets/chongqing/*`,
  `lib/chongqing/{city_data,city_view,navigation}.dart`, `test/city_build_test.dart`,
  `plans/chongqing-miniature.md`, `.github/workflows/deploy-web.yml` (SITE_DIR=chongqing).
- Edit: `lib/main.dart`, `pubspec.yaml` (assets + dev deps), `.gitignore` (tool cache).

## Verification
1. Unit tests on the build step: projection round-trip, ear-clipping of a concave footprint,
   height fallback order, bridge stays above terrain.
2. `fvm dart run tool/chongqing/fetch.dart yuzhong_tip && … build.dart yuzhong_tip`.
3. Run on iOS simulator + Android phone (profile) + web; screenshot from diorama and ride
   views; compare against a satellite view of Chaotianmen for layout sanity.
4. FPS overlay holds 60 on Low on the Motorola.

---

## Implementation notes (district 1 built, 2026-11-05)

### How to rebuild a district
```sh
fvm dart run tool/chongqing/fetch.dart yuzhong_tip   # downloads into tool/chongqing/cache/
fvm dart run tool/chongqing/build.dart yuzhong_tip   # writes assets/chongqing/yuzhong_tip.{bin,json}
```
Add a new district by adding one entry to `tool/chongqing/districts.dart`.

### What the first build contains
| Layer | Vertices | Triangles |
| --- | --- | --- |
| Terrain (8 m grid) | 53,946 | 106,964 |
| Buildings (480) | about 24,000 | about 13,500 |
| Roads, steps, bridges | 40,416 | 39,234 |
| Structures (piers, cableway) | about 6,000 | about 3,300 |
Asset size: 3.7 MB. Runs at 60 FPS on the iOS simulator on High.

### Changes from the plan
- **Ride is the Yangtze River Cableway, not Line 2.** In this district every piece of
  Monorail Line 2 is tagged as a tunnel. Line 2 runs elevated from about Liziba
  (lon 106.518) to lon 106.566, just west of this district. The ride system is generic:
  the build exports every ride path, so building a "Jialing riverside" district
  (lat 29.548-29.572, lon 106.515-106.570) adds the Line 2 ride, including Liziba,
  with no app changes.
- **Window pattern not done yet.** Buildings use per-building colours only.
- **Triangle winding.** flutter_scene's front face here is the opposite of the usual
  right-handed convention; `MeshLayer.triangle` handles it, and a unit test guards it.
- **River level** is the 25th percentile of ground height minus 1 m (160.7 m here),
  because the elevation data is noisy over water.
- Geometry is clipped to the district box; 12 buildings and parts of long roads outside
  it are dropped.

## Second round (2026-11-05): making it feel alive

- **Windows**: generated textures (residential punched windows, glass curtain walls) with
  matching night-light textures.
- **Miniature look**: painted-model colour grade, gradient sky, warm low sun, tilt-shift
  depth of field, high camera angle.
- **Shapes and rooftops**: podium + tower for big buildings; water tanks, AC units, stair
  huts, rooftop gardens, helipads and masts.
- **Greenery**: OSM land cover, green steep slopes, and Chongqing's common trees: huangge
  (*Ficus virens*, the city tree), camphor, Chinese banyan, ginkgo, plus bougainvillea along
  bridges. OSM has almost no mapped trees here, so most are placed by rules.
- **Life**: moving cars (a quarter are yellow taxis) and river boats.
- **Time and weather**: Day / Sunset / Night and Clear / Fog / Rain. Night lights windows,
  street lamps and bridges with bloom.
- **Detail by distance**: rooftop clutter shows within 650 m of the camera, trees within
  2.4 km (1.3 km on Low), cars only when zoomed in.
- **Web first**: three presets. Laptops in a browser start on Medium (about 52 FPS by day in
  Chrome on an M5 MacBook, about 33 FPS at night), native iOS/macOS on High, phones on Low.
  The web renderer does not draw the procedural skybox, so a Flutter gradient behind the
  3D view provides the sky. A WebAssembly build was slower (single-threaded without
  cross-origin isolation, which GitHub Pages cannot provide), so the JS build is used.

## Next
- **District 2, Jialing riverside** (lat 29.548–29.572, lon 106.515–106.570): People's
  Square and the Great Hall, Liziba, and the elevated Line 2 monorail ride. Needs the app
  to load several districts side by side.
