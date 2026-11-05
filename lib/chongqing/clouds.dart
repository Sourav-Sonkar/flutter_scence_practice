import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Cloud textures baked by tool/chongqing/clouds.dart (natively, since
/// flutter_scene's Dart noise overflows on the web). Each wraps seamlessly
/// around the horizon. White pixels with the cloud density in alpha; colour
/// and coverage are applied when drawing.
class CloudTextures {
  CloudTextures._(this.puffy, this.layered);

  /// Fair-weather cumulus: clumpy, with gaps.
  final ui.Image puffy;

  /// Stratus / overcast: wide and even.
  final ui.Image layered;

  static Future<CloudTextures> load() async {
    Future<ui.Image> one(String name) async {
      final data = await rootBundle.load('assets/chongqing/$name');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      return (await codec.getNextFrame()).image;
    }

    return CloudTextures._(
      await one('clouds_puffy.png'),
      await one('clouds_layered.png'),
    );
  }
}

/// How the clouds look right now.
class CloudStyle {
  const CloudStyle({
    required this.coverage,
    required this.overcast,
    required this.lit,
    required this.shade,
  });

  /// 0 = clear blue, 1 = full cover.
  final double coverage;

  /// 0 = puffy cumulus, 1 = flat layered overcast.
  final double overcast;

  /// Colour of sunlit cloud tops and of the shaded undersides.
  final Color lit, shade;
}

/// Draws the cloud bands into a sky. The band is laid around the horizon
/// by the camera's heading, so clouds stay fixed in the world as the camera
/// orbits, and drifts slowly with the wind.
void paintClouds(
  Canvas canvas,
  Size size, {
  required CloudTextures tex,
  required CloudStyle style,
  required double horizonY,
  required double heading, // camera yaw, radians
  required double fovY, // radians
  required double time,
}) {
  if (style.coverage <= 0.01) return;
  final pxPerRad = size.height / fovY;
  final ringWidth = 2 * pi * pxPerRad;

  // Alpha remap A' = k*A + b: steeper and lower = fewer, crisper clouds.
  ColorFilter coverageFilter(double coverage, Color c, double opacity) {
    final k = 2.2 + 2.5 * (1 - coverage);
    final b = -255 * (1.15 - coverage * 1.05) * (k / 3);
    return ColorFilter.matrix([
      0, 0, 0, 0, c.r * 255, //
      0, 0, 0, 0, c.g * 255,
      0, 0, 0, 0, c.b * 255,
      0, 0, 0, k * opacity, b * opacity,
    ]);
  }

  void band(
    ui.Image img,
    double lowDeg,
    double highDeg,
    double drift,
    double coverage,
    double scale,
  ) {
    final top = horizonY - highDeg * pi / 180 * pxPerRad;
    final bottom = horizonY - lowDeg * pi / 180 * pxPerRad;
    if (bottom < 0 || top > size.height) return;
    final w = ringWidth * scale;
    final offset = (-(heading / (2 * pi)) * w + time * drift) % w;
    final src = Rect.fromLTWH(
      0,
      0,
      img.width.toDouble(),
      img.height.toDouble(),
    );
    for (var x = offset - w; x < size.width; x += w) {
      final dst = Rect.fromLTRB(x, top, x + w, bottom);
      // Shaded underside, nudged down, then the sunlit body over it.
      canvas.drawImageRect(
        img,
        src,
        dst.shift(const Offset(0, 4)),
        Paint()
          ..filterQuality = FilterQuality.low
          ..colorFilter = coverageFilter(coverage, style.shade, 0.95),
      );
      canvas.drawImageRect(
        img,
        src,
        dst,
        Paint()
          ..filterQuality = FilterQuality.low
          ..colorFilter = coverageFilter(coverage * 0.9, style.lit, 0.9),
      );
    }
  }

  final puffyCover = style.coverage * (1 - style.overcast);
  final flatCover = style.coverage * style.overcast;
  // High thin layer, then low puffy clouds nearer the horizon in front.
  if (flatCover > 0.01 || puffyCover > 0.01) {
    band(tex.layered, 6, 55, 3, max(flatCover, puffyCover * 0.35), 1.0);
  }
  if (puffyCover > 0.01) band(tex.puffy, 1.5, 18, 6, puffyCover, 0.8);
  if (flatCover > 0.01) band(tex.layered, 0.5, 14, 4, flatCover, 0.7);
}
