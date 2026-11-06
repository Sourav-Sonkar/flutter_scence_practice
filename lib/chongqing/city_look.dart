import 'dart:math';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'facade_textures.dart';
import 'sky.dart';

enum Weather { clear, fog, rain }

/// Low: phones. Medium: laptops in a browser. High: native desktop and iOS.
enum Quality { low, medium, high }

/// Turns the clock, weather and quality into the scene's lighting.
///
/// [configure] runs when weather or quality change and switches effects on
/// or off. [update] runs every frame and only moves continuous values (sun,
/// exposure, fog colour, glow, window lights), so a running day cycle stays
/// smooth instead of rebuilding the render setup each frame.
class CityLook {
  CityLook({
    required this.scene,
    required this.homes,
    required this.towers,
    required this.homeLights,
    required this.towerLights,
    required this.roads,
    required this.water,
    required this.riverLevel,
  });

  /// River surface height: river fog is thickest here.
  final double riverLevel;

  final Scene scene;
  final PhysicallyBasedMaterial homes, towers, roads, water;
  final List<Texture2D> homeLights, towerLights;

  Weather _weather = Weather.clear;

  /// The shader sky (assets/chongqing/sky.fmat), once loaded. Applying
  /// EnvironmentSettings clears Scene.skybox, so it is re-attached after.
  Skybox? skybox;

  /// The same sky baked into the scene's image-based lighting, so water and
  /// glass reflect the real sky (clouds, dusk colours, city glow) instead of
  /// the default studio map. Re-baked only when the sky visibly changes.
  SkyEnvironment? skyLighting;

  /// Whether the current preset wants the tilt-shift blur (the view turns
  /// it off while riding, where it would just smear the scenery).
  bool depthOfField = false;

  /// Whether the preset allows screen-space reflections at all; they only
  /// actually run from dusk on (by day the muddy river barely reflects).
  bool _reflections = false;
  int _lightLevel = -1;
  double _lastHour = -1;
  double _gradeSat = -1, _gradeTemp = -1, _gradeContrast = -1, _emissive = -1;
  late final DirectionalLight _light = DirectionalLight(castsShadow: true);

  /// Whether the Painted style is active (changes the colour grade).
  bool painted = false;

  void configure({required Weather weather, required Quality quality}) {
    _weather = weather;
    final high = quality == Quality.high, medium = quality == Quality.medium;
    final fog = weather == Weather.fog, rain = weather == Weather.rain;
    depthOfField = (high || medium) && !fog;
    _reflections = high || medium;

    _light
      ..castsShadow = true
      ..shadowMaxDistance = high ? 3000 : 1800
      ..shadowCascadeCount = high ? 4 : 2
      ..shadowMapResolution = high || medium ? 2048 : 1024
      ..shadowDepthBias = 0.4
      ..shadowNormalBias = 0.6;
    scene.directionalLight = _light;

    roads.roughnessFactor = rain ? 0.3 : 0.9;
    _emissive = -1; // reflections and water refresh on the next update

    scene.environmentSettings = EnvironmentSettings(
      toneMapping: ToneMappingMode.aces,
      colorGradingEnabled: true,
      contrast: 1.1,
      fogEnabled: true,
      fogMode: FogMode.exponential,
      ambientOcclusionEnabled: high || medium,
      ambientOcclusionMethod: AmbientOcclusionMethod.groundTruth,
      ambientOcclusionRadius: 6,
      ambientOcclusionIntensity: 1.2,
      // Water reflections. Physically, water seen from this high diorama
      // angle reflects only ~5-10% (Fresnel), far weaker than the low-angle
      // night photos of Chongqing, so the strength is boosted. Medium traces
      // at half resolution with fewer steps so the web keeps its frame rate.
      screenSpaceReflectionsEnabled: high || medium,
      screenSpaceReflectionsIntensity: 4.5,
      screenSpaceReflectionsMaxDistance: 2500,
      screenSpaceReflectionsThickness: 4,
      screenSpaceReflectionsStride: high ? 6 : 10,
      screenSpaceReflectionsMaxSteps: high ? 128 : 48,
      screenSpaceReflectionsBlur: 0.15,
      screenSpaceReflectionsDistanceFadeStart: 0.6,
      screenSpaceReflectionsResolutionScale: high ? 1.0 : 0.4,
      // Always on: at night the glow is what makes the city.
      bloomEnabled: true,
      bloomScatter: 0.75,
      depthOfFieldEnabled: (high || medium) && !fog,
      depthOfFieldQuality: high
          ? DepthOfFieldQuality.medium
          : DepthOfFieldQuality.low,
      depthOfFieldFStop: 0.7,
      depthOfFieldBlurScale: 40,
      depthOfFieldMaxForegroundBlur: 28,
      depthOfFieldMaxBackgroundBlur: 28,
      vignetteEnabled: true,
    );
    // EnvironmentSettings.applyTo clears both, so re-attach them.
    if (skybox != null) scene.skybox = skybox;
    if (skyLighting != null) scene.skyEnvironment = skyLighting;
    scene.renderScale = switch (quality) {
      Quality.high => 1.0,
      Quality.medium => 0.8,
      Quality.low => 0.75,
    };
    scene.antiAliasingMode = high
        ? AntiAliasingMode.auto
        : AntiAliasingMode.fxaa;
    _lightLevel = -1; // force everything to refresh on the next update
    _lastHour = -1;
    _gradeSat = -1;
    _gradeContrast = -1;
    _emissive = -1;
  }

  /// Which share of windows is lit at a clock hour: few at dusk, most in
  /// the evening, fewer after midnight, a few early risers before dawn.
  static int lightLevelFor(double hour) {
    if (hour >= 19.5 && hour < 23.5) return 2; // evening peak
    if (hour >= 23.5 || hour < 5.5) return 1; // late night
    return 0; // dusk and dawn
  }

  void update(SkyState sky, double hour) {
    // Nothing moves while the clock is paused: skip the work entirely.
    if ((hour - _lastHour).abs() < 0.002) return;
    _lastHour = hour;
    final fog = _weather == Weather.fog, rain = _weather == Weather.rain;
    final night = sky.night;

    // The sun owns the shadow light by day, the moon by night.
    final useMoon = sky.sunIntensity < sky.moonIntensity * 2.5;
    final dir = useMoon ? -sky.moon : -sky.sun;
    // The city's shadows are cached (static casters), and turning the light
    // throws the cache away, so the light only turns in 1° steps. Colour and
    // brightness still change smoothly.
    if (_light.direction.normalized().dot(dir) < cos(1 * pi / 180)) {
      _light.direction = dir;
    }
    if (useMoon) {
      _light
        ..color = vm.Vector3(0.55, 0.66, 1.0)
        ..intensity = sky.moonIntensity;
    } else {
      _light
        ..color = sky.sunColor
        ..intensity = sky.sunIntensity;
    }

    scene
      ..exposure = sky.exposure
      ..environmentIntensity = sky.environment;
    // Chongqing fog is river fog: thick down at the water and in the low
    // streets, thinning with height so the towers rise out of it. At night
    // it picks up the orange of the street lights.
    final cityGlow = vm.Vector3(0.13, 0.09, 0.065) * night;
    if (fog) {
      scene.fog
        ..color = sky.fog * 0.85 + cityGlow
        ..height = riverLevel + 5
        ..heightFalloff = 0.014
        ..density = 0.0042
        ..maxOpacity = 0.96
        ..sunInScatter = 0.9 * (1 - night)
        ..sunInScatterExponent = 6;
    } else if (rain) {
      scene.fog
        ..color = sky.fog + cityGlow * 0.6
        ..height = riverLevel + 20
        ..heightFalloff = 0.006
        ..density = 0.0006
        ..maxOpacity = 0.85
        ..sunInScatter = 0
        ..sunInScatterExponent = 8;
    } else {
      // Clear: only a light aerial haze with distance.
      scene.fog
        ..color = sky.fog + cityGlow * 0.4
        ..height = 0
        ..heightFalloff = 0
        ..density = 0.00005 + 0.00004 * night
        ..maxOpacity = 1
        ..sunInScatter = 0.35 * (1 - night)
        ..sunInScatterExponent = 10;
    }

    // Colour grading rebuilds its lookup when touched, so only change it in
    // visible steps.
    // Painted: softer contrast and a warm, slightly faded, sunny palette
    // (the materials already add saturation, so the grade stays gentle).
    // Under a high sun that softness washes the city out, so the grade
    // firms up toward midday: more contrast and colour, a touch darker.
    final high = painted && !fog && !rain
        ? ((sky.elevation - 15) / 30).clamp(0.0, 1.0)
        : 0.0;
    final sat = painted
        ? (fog || rain ? 1.0 : 1.12 - 0.1 * night + 0.12 * high)
        : (fog || rain ? 1.05 : 1.35 - 0.15 * night);
    final temp = 0.06 + 0.16 * sky.golden - 0.1 * night + (painted ? 0.05 : 0);
    final contrast = painted ? 0.94 + 0.18 * high : 1.1;
    if ((sat - _gradeSat).abs() > 0.02 ||
        (temp - _gradeTemp).abs() > 0.01 ||
        (contrast - _gradeContrast).abs() > 0.02) {
      _gradeSat = sat;
      _gradeTemp = temp;
      _gradeContrast = contrast;
      scene.postProcess.colorGrading
        ..saturation = sat
        ..temperature = temp
        ..contrast = contrast
        ..brightness = painted ? 1.06 - 0.1 * high : 1.0;
    }
    // Bloom: only the brightest lights glow, a little more so at night.
    scene.postProcess.bloom
      ..threshold = 2.2 - 1.0 * night
      ..intensity = 0.1 + 0.16 * night;
    scene.postProcess.vignette.intensity = 0.3 + 0.12 * night;

    // Windows: brightness follows darkness; which windows are lit follows
    // the clock, swapping to a level that adds or removes whole windows.
    final level = lightLevelFor(hour);
    if (level != _lightLevel) {
      _lightLevel = level;
      homes.emissiveTexture = homeLights[level];
      towers.emissiveTexture = towerLights[level];
    }
    if ((night - _emissive).abs() > 0.01) {
      _emissive = night;
      // Reflections: by day the rivers are muddy and mostly show soft sky
      // glare, so reflections stay near the physical strength and slightly
      // blurred; at night the lit city mirrors strongly in calm dark water.
      scene.screenSpaceReflections
        ..enabled = _reflections && (night > 0.25 || rain)
        ..intensity = 1.0 + 3.5 * night
        ..blur = 0.35 - 0.2 * night;
      water
        ..roughnessFactor = rain ? 0.25 : 0.1 - 0.07 * night
        ..baseColorFactor = painted
            // Painted: a clear teal river, deepening to blue at night.
            ? vm.Vector4(
                0.1 - 0.07 * night,
                0.36 - 0.27 * night,
                0.4 - 0.25 * night,
                1,
              )
            : vm.Vector4(
                0.16 - 0.11 * night, // muddy green-brown by day, dark at night
                0.17 - 0.095 * night,
                0.12 - 0.04 * night,
                1,
              );
      final w = 1.4 * night;
      homes.emissiveFactor = vm.Vector4(w, w, w, 1);
      final o = 0.5 * night;
      towers.emissiveFactor = vm.Vector4(o, o, o, 1);
    }
  }

  /// Level names for reference; matches [FacadeTextures.levels] order.
  static const levels = FacadeTextures.levels;
}
