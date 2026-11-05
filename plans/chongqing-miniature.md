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

## Third round (2026-11-05): day cycle and natural night

- **Day cycle**: a time slider with play/pause (one in-game hour per 10 s) and jumps to
  sunset, night and noon. The sun's position is computed for Chongqing (29.56° N,
  106.58° E, UTC+8) and the date, so it rises around 07:15 and sets around 18:05 in early
  November. Sky, sunlight colour, exposure, fog and glow blend by sun elevation through
  golden hour, blue hour and night; the moon takes over the shadow light at night.
- **Sky that works on the web**: drawn behind the 3D view (gradient, sun disc and halo,
  moon, about 220 faint twinkling stars that fade near the horizon and under cloud).
  flutter_scene's own procedural sky was being cleared by `EnvironmentSettings.applyTo`,
  which resets `scene.skybox`.
- **Natural night**: warm 2,700 to 4,000 K windows dimmed by curtains, a few cool TV glows;
  offices in soft warm white; windows switch on in stages (dusk, evening peak, late night);
  navy night sky with a faint warm horizon instead of black; sodium-orange and LED street
  lamps with a few flickering; animated LED crowns on 23 towers; car head and tail lights;
  lit river boats.
- **Smoothness**: lighting values only change when the clock moves, and colour grading only
  in visible steps (it rebuilds its lookup when touched). Chrome, Medium: about 50 FPS by
  day and 44 FPS at night, UI thread about 6 to 7 ms.
- **Open**: sunset could be more dramatic from the default camera angle (sunlit walls face
  away); the sky only shows when the camera tilts towards the horizon.

## Fourth round (2026-11-05): clouds and realistic fog

- **Clouds**: flutter_scene has no cloud feature, only a noise generator, and that noise
  overflows on the web. So `tool/chongqing/clouds.dart` bakes two seamless cloud textures
  natively (puffy cumulus, layered stratus, about 45 KB each). The sky painter draws them as
  drifting bands that stay fixed in the world as the camera orbits. Clear: scattered
  clouds. Fog: a pale layer. Rain: a full dark deck that hides sun, moon and stars. Clouds
  take the sun's colour at golden hour and the city's orange glow at night.
- **Fog**: real height fog, thickest at the river and fading with altitude (falloff
  0.014/m), so towers rise out of it, with glow toward the sun by day and a sodium-orange
  tint at night. Rain uses a lighter, higher haze.
- Chrome, Medium: about 35 to 45 FPS across clear, fog, rain and night.
- **Later**: cloud shadows on the city; a more dramatic sunset.

## Fifth round (2026-11-05): shader sky with real 3D clouds

The painted 2D clouds looked flat, barely moved and didn't match the city's colours. They
are replaced by a sky shader, `assets/chongqing/sky.fmat` (flutter_scene's `.fmat` sky
domain, compiled by the build hook):
- Gradient, sunward glow, city light pollution, sun disc, moon and stars.
- A cloud layer high above the city, traced per pixel, so clouds have true perspective
  (large overhead, thin streaks at the horizon). Wind moves it and a slower field
  reshapes it. Clouds self-shadow toward the sun, glow at the edges when facing the sun,
  and are lit from below by the city at night. Coverage: scattered when clear, pale layer
  in fog, dark deck in rain.
- It goes through the engine's exposure and tone mapping, so sky and city colours agree.
- `EnvironmentSettings.applyTo` resets `Scene.skybox`, so the sky is re-attached after
  every settings change.
- Low quality uses 3 noise octaves instead of 5. Chrome, Medium: about 37 to 50 FPS.
- LED crowns are now hollow rings (four strips), not solid glowing roofs.
- **Build note:** the build hook decides whether to rerun from the names of the files
  directly inside `assets/`. A *new* `.fmat` in a subfolder needs
  `rm -rf .dart_tool/hooks_runner/flutter_scene_practice` once; edits to an existing one
  rebuild normally.

## District 2: Jialing riverside (2026-11-05)

Box lat 29.550–29.570, lon 106.525–106.570; its east edge is exactly the Yuzhong tip's
west edge. Loaded side by side with district 1 (`CityData.loadAll`).

- **Shared frame**: every district is projected around one city origin (29.56, 106.58),
  uses one river level (160.7 m), and its terrain grid ends exactly on its edges (step
  adjusted per axis), so districts meet with no seams or water steps. Roads reach one
  sample past the border so they join.
- **Famous places**: People's Square (paved plaza), the Chongqing People's Grand Hall
  (generated model: stone base, cream wings, red rotunda, three teal roof tiers, gold
  finial, about 65 m), and Liziba Station. They lead the landmark chips; other chips are
  English-named towers only.
- **Line 2 monorail ride**: 4.3 km of elevated track with two four-car trains running in
  opposite directions. A picker in ride mode switches between Line 2 and the cableway.
  Tilt-shift blur is off while riding.
- **Heights**: low, wide public buildings (stadium, museum, civic, school, historic) get
  their own ranges; very large footprints are treated as podiums, not towers.
- **Size**: terrain stored as heights + colours only (grid rebuilt in the app) and 16-bit
  indices where possible. Yuzhong tip 4.4 to 2.4 MB, Jialing riverside 12.9 to 7.9 MB.
- **Speed (Chrome, Medium)**: about 32 to 37 FPS by day and while the day plays. Bigger
  detail tiles, no rooftop or (on Medium) tree shadows, ground and roads not casting,
  static shadow caching for the city, the sun turning in 1° steps, and reflections only
  from dusk. **Open: night views toward the horizon run at about 27 FPS** (both districts'
  full geometry plus glow). Next options: load or draw only districts near the camera,
  or a cheaper far-distance terrain.
