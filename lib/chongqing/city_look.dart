import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

enum TimeOfDayMode { day, sunset, night }

enum Weather { clear, fog, rain }

/// Low: phones. Medium: laptops in a browser. High: native desktop and iOS.
enum Quality { low, medium, high }

/// Everything that changes with time of day, weather and quality: sun,
/// sky, post-processing, lit windows, street lamps and wet roads.
class CityLook {
  CityLook({
    required this.scene,
    required this.homes,
    required this.towers,
    required this.roads,
    required this.water,
    required this.lamps,
  });

  final Scene scene;
  final PhysicallyBasedMaterial homes, towers, roads, water;
  final Node lamps;

  final GradientSkySource sky = GradientSkySource();

  /// Top and horizon colours of the current sky, for a Flutter gradient
  /// behind the 3D view. The web renderer clears to transparent and does not
  /// draw the procedural skybox, so this is what shows there.
  List<Color> backdrop = const [Color(0xff2a5fb8), Color(0xffc8dcf2)];

  static Color _display(vm.Vector3 linear, double exposure) {
    int c(double v) =>
        (math.pow((v * exposure).clamp(0.0, 1.0), 1 / 2.2) * 255).round();
    return Color.fromARGB(255, c(linear.x), c(linear.y), c(linear.z));
  }

  void apply({
    required TimeOfDayMode time,
    required Weather weather,
    required Quality quality,
  }) {
    final high = quality == Quality.high;
    final medium = quality == Quality.medium;
    scene.skybox ??= Skybox(sky);
    final fog = weather == Weather.fog, rain = weather == Weather.rain;
    final overcast = fog || rain;

    // ---- sun / moon and sky ----
    late vm.Vector3 dir, color, zenith, horizon, fogColor, sunDisk;
    late double sunIntensity, envIntensity, exposure, windows;
    switch (time) {
      case TimeOfDayMode.day:
        dir = vm.Vector3(0.62, -0.5, 0.6);
        color = vm.Vector3(1.0, 0.9, 0.76);
        sunIntensity = 4.2;
        zenith = vm.Vector3(0.16, 0.38, 0.78);
        horizon = vm.Vector3(0.78, 0.86, 0.95);
        fogColor = vm.Vector3(0.74, 0.83, 0.94);
        sunDisk = vm.Vector3(4, 3.4, 2.6);
        envIntensity = 0.75;
        exposure = 1.05;
        windows = 0;
      case TimeOfDayMode.sunset:
        dir = vm.Vector3(0.9, -0.16, 0.35);
        color = vm.Vector3(1.0, 0.58, 0.32);
        sunIntensity = 3.2;
        zenith = vm.Vector3(0.22, 0.26, 0.5);
        horizon = vm.Vector3(1.0, 0.56, 0.3);
        fogColor = vm.Vector3(0.85, 0.6, 0.45);
        sunDisk = vm.Vector3(6, 3, 1.2);
        envIntensity = 0.45;
        exposure = 1.1;
        windows = 0.9;
      case TimeOfDayMode.night:
        // Moonlight: dim, cool, still casting soft shadows.
        dir = vm.Vector3(-0.35, -0.6, -0.45);
        color = vm.Vector3(0.55, 0.66, 1.0);
        sunIntensity = 0.35;
        zenith = vm.Vector3(0.006, 0.01, 0.03);
        horizon = vm.Vector3(0.04, 0.06, 0.12);
        fogColor = vm.Vector3(0.04, 0.05, 0.09);
        sunDisk = vm.Vector3(0.6, 0.65, 0.8);
        envIntensity = 0.06;
        exposure = 1.5;
        windows = 3.2;
    }
    if (overcast) {
      sunIntensity *= time == TimeOfDayMode.night ? 0.6 : 0.4;
      final grey = time == TimeOfDayMode.night
          ? vm.Vector3(0.05, 0.055, 0.07)
          : vm.Vector3(0.62, 0.65, 0.68);
      zenith = zenith * 0.4 + grey * 0.6;
      horizon = horizon * 0.3 + grey * 0.7;
      fogColor = fogColor * 0.3 + grey * 0.7;
      sunDisk = sunDisk * 0.1;
    }
    dir.normalize();
    backdrop = [_display(zenith, exposure), _display(horizon, exposure)];
    sky
      ..zenithColor = zenith
      ..horizonColor = horizon
      ..groundColor = horizon * 0.5
      ..sunDirection = -dir
      ..sunColor = sunDisk;

    scene.directionalLight = DirectionalLight(
      direction: dir,
      color: color,
      intensity: sunIntensity,
      castsShadow: true,
      shadowMaxDistance: high ? 3000 : 1800,
      shadowCascadeCount: high ? 4 : 2,
      shadowMapResolution: high || medium ? 2048 : 1024,
      shadowDepthBias: 0.4,
      shadowNormalBias: 0.6,
    );

    // ---- lit windows, lamps, wet surfaces ----
    homes.emissiveFactor = vm.Vector4(windows, windows, windows, 1);
    // Office floors are big and bright; keep them from washing out to white.
    final office = windows * 0.5;
    towers.emissiveFactor = vm.Vector4(office, office, office, 1);
    lamps.visible = time != TimeOfDayMode.day;
    roads.roughnessFactor = rain ? 0.3 : 0.9;
    water.roughnessFactor = rain ? 0.25 : 0.06;

    final night = time == TimeOfDayMode.night;
    scene.environmentSettings = EnvironmentSettings(
      toneMapping: ToneMappingMode.aces,
      exposure: exposure,
      environmentIntensity: envIntensity,
      // A painted-model grade: richer colour, a touch warm and contrasty.
      colorGradingEnabled: true,
      saturation: overcast ? 1.05 : (night ? 1.25 : 1.35),
      contrast: 1.1,
      temperature: night ? -0.05 : 0.06,
      fogEnabled: true,
      fogMode: FogMode.exponential,
      fogColor: fogColor,
      fogDensity: fog ? 0.0009 : (rain ? 0.00035 : (night ? 0.00008 : 0.00005)),
      ambientOcclusionEnabled: high || medium,
      ambientOcclusionMethod: AmbientOcclusionMethod.groundTruth,
      ambientOcclusionRadius: 6,
      ambientOcclusionIntensity: 1.2,
      screenSpaceReflectionsEnabled: high,
      screenSpaceReflectionsMaxDistance: 600,
      // Glow is what makes Chongqing at night: keep it on even on Low.
      bloomEnabled: high || medium || time != TimeOfDayMode.day,
      bloomThreshold: night ? 0.9 : 2.2,
      bloomIntensity: night ? 0.35 : 0.12,
      // Tilt-shift: a narrow focus band at the orbit target.
      depthOfFieldEnabled: (high || medium) && !fog,
      depthOfFieldQuality: high
          ? DepthOfFieldQuality.medium
          : DepthOfFieldQuality.low,
      depthOfFieldFStop: 0.7,
      depthOfFieldBlurScale: 40,
      depthOfFieldMaxForegroundBlur: 28,
      depthOfFieldMaxBackgroundBlur: 28,
      vignetteEnabled: true,
      vignetteIntensity: night ? 0.4 : 0.3,
    );
    scene.renderScale = switch (quality) {
      Quality.high => 1.0,
      Quality.medium => 0.8,
      Quality.low => 0.75,
    };
    scene.antiAliasingMode = high
        ? AntiAliasingMode.auto
        : AntiAliasingMode.fxaa;
  }
}
