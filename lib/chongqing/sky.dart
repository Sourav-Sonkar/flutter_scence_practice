import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:vector_math/vector_math.dart' as vm;

import 'clouds.dart';

/// Where the sun is over Chongqing (29.56° N, 106.58° E, UTC+8) at a local
/// clock time, using the standard solar declination / hour-angle formulas.
/// Returns the unit direction *towards* the sun: +x east, +y up, +z south.
vm.Vector3 sunDirection(double hour, {int dayOfYear = 309}) {
  const lat = 29.56 * pi / 180, lon = 106.58;
  final g = 2 * pi / 365 * (dayOfYear - 1 + (hour - 12) / 24);
  final decl =
      0.006918 -
      0.399912 * cos(g) +
      0.070257 * sin(g) -
      0.006758 * cos(2 * g) +
      0.000907 * sin(2 * g);
  final eqTimeMin =
      229.18 *
      (0.000075 +
          0.001868 * cos(g) -
          0.032077 * sin(g) -
          0.014615 * cos(2 * g) -
          0.040849 * sin(2 * g));
  final solarHour = hour + (4 * (lon - 120) + eqTimeMin) / 60;
  final ha = (solarHour - 12) * 15 * pi / 180;
  final sinEl = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(ha);
  final el = asin(sinEl.clamp(-1.0, 1.0));
  // Azimuth measured clockwise from north.
  final az = atan2(sin(ha), cos(ha) * sin(lat) - tan(decl) * cos(lat)) + pi;
  return vm.Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el));
}

double _smooth(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

vm.Vector3 _lerp(vm.Vector3 a, vm.Vector3 b, double t) => a + (b - a) * t;

/// Picks between colour keys by sun elevation (degrees), blending smoothly.
vm.Vector3 _byElevation(double e, List<(double, vm.Vector3)> keys) {
  if (e >= keys.first.$1) return keys.first.$2;
  for (var i = 0; i < keys.length - 1; i++) {
    final (e0, c0) = keys[i];
    final (e1, c1) = keys[i + 1];
    if (e <= e0 && e >= e1) return _lerp(c1, c0, _smooth(e1, e0, e));
  }
  return keys.last.$2;
}

/// Everything about the sky and light at one moment, derived from the
/// clock and the weather. Colours are linear.
class SkyState {
  SkyState(this.hour, {required bool overcast, required bool foggy}) {
    sun = sunDirection(hour);
    elevation = asin(sun.y) * 180 / pi;
    final e = elevation;

    // Day (0) .. night (1): lights come on through golden hour into dusk.
    night = _smooth(6, -8, e);
    // Stars only once it is properly dark, and only a few: light pollution.
    stars = _smooth(-6, -14, e) * (overcast ? 0.0 : 1.0);

    zenith = _byElevation(e, [
      (25, vm.Vector3(0.14, 0.34, 0.74)),
      (8, vm.Vector3(0.2, 0.36, 0.68)),
      (0, vm.Vector3(0.2, 0.25, 0.5)),
      (-5, vm.Vector3(0.06, 0.1, 0.26)), // blue hour
      (-12, vm.Vector3(0.006, 0.011, 0.034)), // deep navy, not black
    ]);
    horizon = _byElevation(e, [
      (25, vm.Vector3(0.72, 0.83, 0.94)),
      (8, vm.Vector3(0.95, 0.78, 0.55)), // golden hour
      (0, vm.Vector3(1.0, 0.5, 0.26)), // sunset
      (-5, vm.Vector3(0.32, 0.26, 0.4)),
      (-12, vm.Vector3(0.03, 0.035, 0.07)),
    ]);
    // City light pollution warms the low sky at night.
    final pollution = vm.Vector3(0.075, 0.042, 0.03) * night;
    cityGlow = pollution;
    horizon = horizon + pollution;

    // Sunlight: warm and weak near the horizon, white at height.
    sunColor = _byElevation(e, [
      (30, vm.Vector3(1.0, 0.94, 0.84)),
      (10, vm.Vector3(1.0, 0.8, 0.6)),
      (1, vm.Vector3(1.0, 0.5, 0.28)),
      (-2, vm.Vector3(1.0, 0.4, 0.2)),
    ]);
    // Strong right down to the horizon (golden hour is bright), fading out
    // only as the disc sets.
    sunIntensity = 4.2 * _smooth(-2, 9, e);
    // Moon: roughly opposite the sun, cool and dim; it takes over the
    // shadow-casting light at night.
    moon = vm.Vector3(
      -sun.x * 0.7 + 0.2,
      max(0.35, -sun.y * 0.9 + 0.15),
      -sun.z * 0.7 - 0.3,
    )..normalize();
    moonIntensity = 0.32 * night;

    // Golden hour: the low sun should colour everything, so the neutral
    // sky light fades as the sun drops, and the grade warms.
    golden = _smooth(16, 4, e) * (1 - night);
    exposure = 1.05 + 0.35 * night;
    environment = 0.06 + 0.69 * _smooth(-4, 22, e);
    fog = _lerp(horizon, zenith, 0.25);

    // Clouds: a few fair-weather ones on clear days, a flat pale layer in
    // fog, a full dark deck in rain.
    final raining = overcast && !foggy;
    cloudCover = raining ? 1.0 : (foggy ? 0.6 : 0.34);
    cloudOvercast = overcast ? 1.0 : 0.0;
    // Lit by the sun by day (gold at sunset), by the city's orange glow at
    // night; undersides darker and cooler.
    final dayLit = _lerp(vm.Vector3(1.0, 0.98, 0.95), sunColor * 1.1, golden);
    final nightLit = vm.Vector3(0.06, 0.045, 0.04);
    cloudLit = _lerp(dayLit, nightLit, night);
    cloudShade = _lerp(
      _lerp(vm.Vector3(0.62, 0.66, 0.74), sunColor * 0.55, golden * 0.6),
      vm.Vector3(0.025, 0.026, 0.04),
      night,
    );
    if (raining) {
      // Rain clouds are thick and dark, with a little lighter texture.
      cloudLit = cloudLit * 0.42;
      cloudShade = cloudShade * 0.26;
    }

    if (overcast) {
      final grey = _lerp(
        vm.Vector3(0.62, 0.65, 0.68),
        vm.Vector3(0.05, 0.055, 0.07),
        night,
      );
      zenith = _lerp(zenith, grey, 0.65);
      horizon = _lerp(horizon, grey + pollution * 0.6, 0.7);
      fog = _lerp(fog, grey, 0.75);
      sunIntensity *= foggy ? 0.35 : 0.45;
    }
  }

  final double hour;
  late final vm.Vector3 sun;
  late final double elevation;
  late final double night;
  late final double golden;
  late final vm.Vector3 cityGlow;
  late final double cloudCover, cloudOvercast;
  late vm.Vector3 cloudLit, cloudShade;
  late final double stars;
  late vm.Vector3 zenith, horizon, fog;
  late final vm.Vector3 sunColor;
  late double sunIntensity;
  late final vm.Vector3 moon;
  late final double moonIntensity;
  late final double exposure;
  late final double environment;

  /// Linear colour to a display colour, roughly matching the 3D view's
  /// exposure and tone mapping so sky and scene agree.
  static Color display(vm.Vector3 linear, double exposure) {
    int c(double v) {
      final x = v * exposure;
      final mapped = x / (1 + x * 0.35); // gentle roll-off, like ACES
      return (pow(mapped.clamp(0.0, 1.0), 1 / 2.2) * 255).round();
    }

    return Color.fromARGB(255, c(linear.x), c(linear.y), c(linear.z));
  }
}

/// Paints the sky behind the 3D view: gradient, sun glow, moon and stars.
/// Sky directions are projected through the live camera, so the sun and
/// stars stay put in the world as you orbit.
class SkyPainter extends CustomPainter {
  SkyPainter({
    required this.state,
    required this.project,
    required this.time,
    required this.clouds,
    required this.forward,
    required this.fovY,
    required super.repaint,
  });

  final CloudTextures? Function() clouds;

  /// The camera's view direction, for laying clouds around the horizon.
  final vm.Vector3 Function() forward;
  final double Function() fovY;

  final SkyState Function() state;

  /// Projects a world direction (from the camera) to the screen, or null if
  /// it is behind the camera.
  final Offset? Function(vm.Vector3 direction, Size size) project;
  final double Function() time;

  static final List<(vm.Vector3, double, double)> _stars = () {
    final rnd = Random(42);
    final out = <(vm.Vector3, double, double)>[];
    while (out.length < 220) {
      final v = vm.Vector3(
        rnd.nextDouble() * 2 - 1,
        rnd.nextDouble(),
        rnd.nextDouble() * 2 - 1,
      );
      if (v.length2 > 1 || v.y < 0.18) continue;
      v.normalize();
      out.add((v, 0.3 + rnd.nextDouble() * 0.7, rnd.nextDouble() * 6.28));
    }
    return out;
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final s = state();
    final exp = s.exposure;

    // Where the horizon sits on screen depends on camera pitch: project a
    // point on the horizon straight ahead.
    var horizonY = size.height * 0.45;
    final h =
        project(vm.Vector3(0, 0.0, 1), size) ??
        project(vm.Vector3(0, 0.0, -1), size) ??
        project(vm.Vector3(1, 0.0, 0), size);
    if (h != null) horizonY = h.dy.clamp(-size.height, size.height * 2);

    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, horizonY - size.height * 0.9),
          Offset(0, horizonY + 4),
          [SkyState.display(s.zenith, exp), SkyState.display(s.horizon, exp)],
        ),
    );
    // Below the horizon (behind distant terrain) keep the horizon colour.
    if (horizonY < size.height) {
      canvas.drawRect(
        Rect.fromLTRB(0, horizonY + 3, size.width, size.height),
        Paint()..color = SkyState.display(s.horizon * 0.9, exp),
      );
    }

    // Stars, faint and twinkling.
    if (s.stars > 0.01) {
      final t = time();
      final paint = Paint();
      for (final (dir, mag, phase) in _stars) {
        final p = project(dir, size);
        if (p == null || p.dy > horizonY - 6) continue;
        final twinkle = 0.65 + 0.35 * sin(t * (1.3 + mag * 2) + phase);
        // Stars near the horizon drown in city glow.
        final height = ((horizonY - p.dy) / (size.height * 0.5)).clamp(
          0.0,
          1.0,
        );
        final a = s.stars * mag * twinkle * height * 0.85;
        if (a < 0.03) continue;
        paint.color = Color.fromRGBO(255, 248, 235, a);
        canvas.drawCircle(p, 0.6 + mag * 0.7, paint);
      }
    }

    // Moon.
    if (s.night > 0.4) {
      final p = project(s.moon, size);
      if (p != null && p.dy < horizonY) {
        final a =
            ((s.night - 0.4) / 0.6).clamp(0.0, 1.0) * (s.stars > 0 ? 1 : 0.5);
        canvas.drawCircle(
          p,
          34,
          Paint()
            ..color = Color.fromRGBO(200, 215, 255, 0.10 * a)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26),
        );
        canvas.drawCircle(
          p,
          9,
          Paint()..color = Color.fromRGBO(240, 242, 236, 0.95 * a),
        );
      }
    }

    // Sun: a soft halo plus a disc, warmer near the horizon.
    if (s.elevation > -3) {
      final p = project(s.sun, size);
      if (p != null) {
        final low = (1 - (s.elevation / 25).clamp(0.0, 1.0));
        final halo = Color.lerp(
          const Color(0xfffff1d0),
          const Color(0xffff9a4a),
          low,
        )!;
        final fade =
            ((s.elevation + 3) / 4).clamp(0.0, 1.0) *
            (1 - 0.85 * s.cloudOvercast) *
            (s.sunIntensity > 0.5 ? 1 : 0.4);
        canvas.drawCircle(
          p,
          120 + 80 * low,
          Paint()
            ..color = halo.withValues(alpha: 0.35 * fade)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 70),
        );
        canvas.drawCircle(
          p,
          13,
          Paint()
            ..color = Color.lerp(
              const Color(0xfffffdf6),
              halo,
              low * 0.6,
            )!.withValues(alpha: fade),
        );
      }
    }

    _paintClouds(canvas, size, s, horizonY);
  }

  void _paintClouds(Canvas canvas, Size size, SkyState s, double horizonY) {
    final tex = clouds();
    if (tex == null) return;
    final f = forward();
    paintClouds(
      canvas,
      size,
      tex: tex,
      style: CloudStyle(
        coverage: s.cloudCover,
        overcast: s.cloudOvercast,
        lit: SkyState.display(s.cloudLit, s.exposure),
        shade: SkyState.display(s.cloudShade, s.exposure),
      ),
      horizonY: horizonY,
      heading: atan2(f.x, -f.z),
      fovY: fovY(),
      time: time(),
    );
  }

  @override
  bool shouldRepaint(SkyPainter old) => true;
}
