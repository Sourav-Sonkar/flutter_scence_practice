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
  final Texture2D lights;

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
    final px = _blank(255), lit = _blank(0);
    final rnd = Random(7);
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
        final on = rnd.nextDouble();
        if (on < 0.55) {
          final glow = on < 0.08
              ? (190, 210, 255) // a TV's cool light
              : (255, 176 + rnd.nextInt(40), 96 + rnd.nextInt(40));
          _rect(lit, x + 8, y + 7, x + _cell - 6, y + _cell - 9, glow);
        }
      }
    }
    return FacadeTextures._(
      Texture2D.fromPixels(px, _size, _size),
      Texture2D.fromPixels(lit, _size, _size),
    );
  }

  /// Curtain-wall glass: a fine mullion grid with slightly varying panes.
  /// At night whole office floors glow in cool white.
  static FacadeTextures glass() {
    final px = _blank(255), lit = _blank(0);
    final rnd = Random(11);
    for (var fy = 0; fy < 8; fy++) {
      final floorOn = rnd.nextDouble() < 0.55;
      for (var bx = 0; bx < 8; bx++) {
        final shade = 150 + rnd.nextInt(40);
        final paneOn = floorOn && rnd.nextDouble() < 0.85;
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
            if (paneOn) {
              lit[i] = 200;
              lit[i + 1] = 222;
              lit[i + 2] = 255;
            }
          }
        }
      }
    }
    return FacadeTextures._(
      Texture2D.fromPixels(px, _size, _size),
      Texture2D.fromPixels(lit, _size, _size),
    );
  }
}
