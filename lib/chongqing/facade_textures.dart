import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';

/// Window textures generated in code, so no image assets are needed.
///
/// One texture repeat covers 8 bays by 8 floors (see MeshLayer.facadeTileU/V
/// in the build tool). Walls are white so the per-building vertex colour
/// shows through; the first pixels of every bay are a solid pillar, which
/// roofs sample for a plain colour.
class FacadeTextures {
  static const int _size = 256;
  static const int _cell = _size ~/ 8; // one bay by one floor

  /// Punched windows with variation: curtains, lit rooms, AC units.
  static Texture2D residential() {
    final px = Uint8List(_size * _size * 4)
      ..fillRange(0, _size * _size * 4, 255);
    final rnd = Random(7);
    void rect(int x0, int y0, int x1, int y1, int r, int g, int b) {
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = (y * _size + x) * 4;
          px[i] = r;
          px[i + 1] = g;
          px[i + 2] = b;
        }
      }
    }

    for (var fy = 0; fy < 8; fy++) {
      for (var bx = 0; bx < 8; bx++) {
        final x = bx * _cell, y = fy * _cell;
        // Floor slab line.
        rect(x, y + _cell - 2, x + _cell, y + _cell, 214, 210, 204);
        final roll = rnd.nextDouble();
        final (r, g, b) = roll < 0.12
            ? (236, 214, 150) // warm, curtains drawn
            : roll < 0.22
            ? (120, 140, 150) // open window
            : (
                58 + rnd.nextInt(18),
                74 + rnd.nextInt(18),
                92 + rnd.nextInt(18),
              );
        rect(x + 8, y + 7, x + _cell - 6, y + _cell - 9, r, g, b);
        // Window frame mullion.
        rect(x + 18, y + 7, x + 20, y + _cell - 9, 230, 230, 228);
        // A small balcony rail or AC box under some windows.
        if (rnd.nextDouble() < 0.35) {
          rect(x + 10, y + _cell - 8, x + 18, y + _cell - 4, 236, 238, 240);
        }
      }
    }
    return Texture2D.fromPixels(px, _size, _size);
  }

  /// Curtain-wall glass: a fine mullion grid with slightly varying panes.
  static Texture2D glass() {
    final px = Uint8List(_size * _size * 4)
      ..fillRange(0, _size * _size * 4, 255);
    final rnd = Random(11);
    for (var fy = 0; fy < 8; fy++) {
      for (var bx = 0; bx < 8; bx++) {
        final shade = 150 + rnd.nextInt(40);
        for (var y = fy * _cell; y < (fy + 1) * _cell; y++) {
          for (var x = bx * _cell; x < (bx + 1) * _cell; x++) {
            final lx = x - bx * _cell, ly = y - fy * _cell;
            final i = (y * _size + x) * 4;
            if (lx < 2) continue; // vertical mullion (and roof sample)
            if (ly >= _cell - 5) {
              // Spandrel band between floors.
              px[i] = 210;
              px[i + 1] = 214;
              px[i + 2] = 218;
              continue;
            }
            // Faint vertical gradient reads as sky reflection.
            final g = (shade + (ly * 0.6)).round().clamp(0, 255);
            px[i] = g - 20;
            px[i + 1] = g - 6;
            px[i + 2] = g + 10 > 255 ? 255 : g + 10;
          }
        }
      }
    }
    return Texture2D.fromPixels(px, _size, _size);
  }
}
