import 'dart:math';
import 'dart:typed_data';

import 'geo.dart';
import 'polygon.dart';

/// A fine occupancy grid (default 4 m) over the district, used to keep
/// trees off buildings and roads.
class Mask {
  Mask(this.terrain, {this.cell = 4})
    : cols = ((terrain.maxX - terrain.minX) / cell).ceil() + 1,
      rows = ((terrain.maxZ - terrain.minZ) / cell).ceil() + 1 {
    bits = Uint8List(cols * rows);
  }

  final GridTerrain terrain;
  final double cell;
  final int cols, rows;
  late final Uint8List bits;

  (int, int) _ij(double x, double z) => (
    ((x - terrain.minX) / cell).floor().clamp(0, cols - 1),
    ((z - terrain.minZ) / cell).floor().clamp(0, rows - 1),
  );

  bool at(double x, double z) {
    final (i, j) = _ij(x, z);
    return bits[j * cols + i] != 0;
  }

  void markRing(List<P2> ring, {double pad = 1.5}) {
    var minX = double.infinity, maxX = -double.infinity;
    var minZ = double.infinity, maxZ = -double.infinity;
    for (final (x, z) in ring) {
      minX = min(minX, x);
      maxX = max(maxX, x);
      minZ = min(minZ, z);
      maxZ = max(maxZ, z);
    }
    final (i0, j0) = _ij(minX - pad, minZ - pad);
    final (i1, j1) = _ij(maxX + pad, maxZ + pad);
    for (var j = j0; j <= j1; j++) {
      for (var i = i0; i <= i1; i++) {
        final x = terrain.minX + (i + 0.5) * cell,
            z = terrain.minZ + (j + 0.5) * cell;
        if (pointInRing((x, z), ring) ||
            pointInRing((x + pad, z), ring) ||
            pointInRing((x - pad, z), ring) ||
            pointInRing((x, z + pad), ring) ||
            pointInRing((x, z - pad), ring)) {
          bits[j * cols + i] = 1;
        }
      }
    }
  }

  void markDisc(double x, double z, double r) {
    final (i0, j0) = _ij(x - r, z - r);
    final (i1, j1) = _ij(x + r, z + r);
    for (var j = j0; j <= j1; j++) {
      for (var i = i0; i <= i1; i++) {
        final cx = terrain.minX + (i + 0.5) * cell,
            cz = terrain.minZ + (j + 0.5) * cell;
        if ((cx - x) * (cx - x) + (cz - z) * (cz - z) <= r * r) {
          bits[j * cols + i] = 1;
        }
      }
    }
  }
}

/// Ground cover read from OpenStreetMap area tags.
enum Cover { park, wood, grass, residential, commercial, paved, construction }

Cover? coverFor(Map<String, dynamic> tags) {
  final landuse = tags['landuse'],
      leisure = tags['leisure'],
      natural = tags['natural'];
  if (leisure == 'park' || leisure == 'garden') return Cover.park;
  if (landuse == 'forest' || natural == 'wood' || natural == 'scrub') {
    return Cover.wood;
  }
  if (landuse == 'grass' ||
      landuse == 'meadow' ||
      landuse == 'recreation_ground' ||
      natural == 'grassland' ||
      leisure == 'pitch' ||
      leisure == 'playground') {
    return Cover.grass;
  }
  if (landuse == 'residential') return Cover.residential;
  if (landuse == 'commercial' || landuse == 'retail') return Cover.commercial;
  if (tags['amenity'] == 'parking' || tags['place'] == 'square') {
    return Cover.paved;
  }
  if (landuse == 'construction') return Cover.construction;
  return null;
}

(int, int, int) coverColor(Cover c) => switch (c) {
  Cover.park => (104, 150, 76),
  Cover.wood => (70, 118, 56),
  Cover.grass => (128, 168, 90),
  Cover.residential => (186, 178, 160),
  Cover.commercial => (176, 172, 168),
  Cover.paved => (190, 184, 174),
  Cover.construction => (176, 150, 116),
};

/// Small deterministic random generator, so builds are reproducible.
class Rng {
  Rng(int seed) : _s = seed & 0x7fffffff;
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 0x7fffffff;
  }
}
