import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';

/// Window textures generated in code, so no image assets are needed.
///
/// One texture repeat covers 8 bays by 8 floors (see MeshLayer.facadeTileU/V
/// in the build tool). Walls are white so the per-building vertex colour
/// shows through; the first pixels of every bay are a solid pillar, which
/// roofs sample for a plain colour.
///
/// Each style comes with a matching emissive texture: black everywhere
/// except the windows that are lit at night.
class FacadeTextures {
  FacadeTextures._(this.color, this.lights);

  final Texture2D color;

  /// Night lights at increasing shares of lit windows. Each window has its
  /// own switch-on point, so every level contains the windows of the levels
  /// below it and swapping levels reads as lights coming on or going out.
  final List<Texture2D> lights;

  /// Shares of windows lit at each level: dusk, late night, evening peak.
  static const List<double> levels = [0.18, 0.3, 0.46];

  /// Warm interior colours in sRGB, roughly 2700 K to 4000 K, plus the odd
  /// cool TV glow. Real cities at night are mostly warm.
  static (int, int, int) _warm(Random rnd) {
    final r = rnd.nextDouble();
    if (r < 0.06) return (170, 190, 240); // TV
    if (r < 0.4) return (255, 166, 86); // 2700 K
    if (r < 0.75) return (255, 182, 110); // 3000 K
    if (r < 0.92) return (255, 198, 140); // 3500 K
    return (255, 214, 168); // 4000 K
  }

  static Uint8List _scaled((int, int, int) c, double k) => Uint8List.fromList([
    (c.$1 * k).round(),
    (c.$2 * k).round(),
    (c.$3 * k).round(),
  ]);

  static List<Texture2D> _levelTextures(
    List<(int, int, int, int, (int, int, int), double, double)> windows,
  ) {
    return [
      for (final share in levels)
        () {
          final px = _blank(0);
          for (final (x0, y0, x1, y1, c, threshold, dim) in windows) {
            if (threshold >= share) continue;
            final v = _scaled(c, dim);
            _rect(px, x0, y0, x1, y1, (v[0], v[1], v[2]));
          }
          return Texture2D.fromPixels(px, _size, _size);
        }(),
    ];
  }

  static const int _size = 256;
  static const int _cell = _size ~/ 8; // one bay by one floor

  static Uint8List _blank(int value) {
    final px = Uint8List(_size * _size * 4)
      ..fillRange(0, _size * _size * 4, value);
    for (var i = 3; i < px.length; i += 4) {
      px[i] = 255;
    }
    return px;
  }

  static void _rect(
    Uint8List px,
    int x0,
    int y0,
    int x1,
    int y1,
    (int, int, int) c,
  ) {
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final i = (y * _size + x) * 4;
        px[i] = c.$1;
        px[i + 1] = c.$2;
        px[i + 2] = c.$3;
      }
    }
  }

  /// Punched windows with variation: curtains, open windows, AC units.
  /// At night about half the homes have warm lights on.
  static FacadeTextures residential() {
    final px = _blank(255);
    final rnd = Random(7);
    final windows = <(int, int, int, int, (int, int, int), double, double)>[];
    for (var fy = 0; fy < 8; fy++) {
      for (var bx = 0; bx < 8; bx++) {
        final x = bx * _cell, y = fy * _cell;
        _rect(px, x, y + _cell - 2, x + _cell, y + _cell, (214, 210, 204));
        final roll = rnd.nextDouble();
        final pane = roll < 0.12
            ? (236, 214, 150)
            : roll < 0.22
            ? (120, 140, 150)
            : (
                58 + rnd.nextInt(18),
                74 + rnd.nextInt(18),
                92 + rnd.nextInt(18),
              );
        _rect(px, x + 8, y + 7, x + _cell - 6, y + _cell - 9, pane);
        _rect(px, x + 18, y + 7, x + 20, y + _cell - 9, (230, 230, 228));
        if (rnd.nextDouble() < 0.35) {
          _rect(px, x + 10, y + _cell - 8, x + 18, y + _cell - 4, (
            236,
            238,
            240,
          ));
        }
        // Curtains dim many lit windows.
        windows.add((
          x + 8,
          y + 7,
          x + _cell - 6,
          y + _cell - 9,
          _warm(rnd),
          rnd.nextDouble(),
          0.45 + rnd.nextDouble() * 0.55,
        ));
      }
    }
    return FacadeTextures._(
      Texture2D.fromPixels(px, _size, _size),
      _levelTextures(windows),
    );
  }

  /// Curtain-wall glass: a fine mullion grid with slightly varying panes.
  /// At night whole office floors glow in cool white.
  static FacadeTextures glass() {
    final px = _blank(255);
    final rnd = Random(11);
    final windows = <(int, int, int, int, (int, int, int), double, double)>[];
    for (var fy = 0; fy < 8; fy++) {
      // Offices light whole floors in neutral-warm white, not blue.
      final floorThreshold = rnd.nextDouble();
      final floorColor = rnd.nextDouble() < 0.7
          ? (255, 214, 172)
          : (255, 230, 204);
      for (var bx = 0; bx < 8; bx++) {
        final shade = 150 + rnd.nextInt(40);
        windows.add((
          bx * _cell + 2,
          fy * _cell,
          (bx + 1) * _cell,
          (fy + 1) * _cell - 5,
          floorColor,
          rnd.nextDouble() < 0.85 ? floorThreshold : 1.0,
          0.4 + rnd.nextDouble() * 0.3,
        ));
        for (var y = fy * _cell; y < (fy + 1) * _cell; y++) {
          for (var x = bx * _cell; x < (bx + 1) * _cell; x++) {
            final lx = x - bx * _cell, ly = y - fy * _cell;
            final i = (y * _size + x) * 4;
            if (lx < 2) continue; // mullion (and roof sample)
            if (ly >= _cell - 5) {
              px[i] = 210;
              px[i + 1] = 214;
              px[i + 2] = 218;
              continue;
            }
            final g = (shade + (ly * 0.6)).round().clamp(0, 255);
            px[i] = g - 20;
            px[i + 1] = g - 6;
            px[i + 2] = min(255, g + 10);
          }
        }
      }
    }
    return FacadeTextures._(
      Texture2D.fromPixels(px, _size, _size),
      _levelTextures(windows),
    );
  }
}
