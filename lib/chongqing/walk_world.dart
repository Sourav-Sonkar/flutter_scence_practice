import 'dart:math';

import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';

/// What a person walking around the city collides with, merged from every
/// loaded district: the terrain (slopes and steps follow the heightmap),
/// bridge decks (walk on them, or underneath them), building walls (slide
/// along them) and the rivers (stop at the water's edge).
class WalkWorld {
  final List<TerrainGrid> _grids = [];
  double riverLevel = 0;

  // Building footprints and deck samples, bucketed on coarse grids so each
  // query only looks at a handful of candidates.
  static const double _wallCell = 50, _deckCell = 20;
  final Map<(int, int), List<_Wall>> _walls = {};
  final Map<(int, int), List<_DeckPoint>> _decks = {};

  /// Adds a newly loaded district.
  void add(WalkData data) {
    riverLevel = data.riverLevel;
    _grids.addAll(data.grids);

    final w = data.walls;
    for (var k = 0; k < w.length;) {
      final n = w[k].round(), top = w[k + 1];
      final pts = <(double, double)>[
        for (var p = 0; p < n; p++) (w[k + 2 + p * 2], w[k + 3 + p * 2]),
      ];
      k += 2 + n * 2;
      final wall = _Wall(pts, top);
      for (
        var cx = (wall.minX / _wallCell).floor();
        cx <= (wall.maxX / _wallCell).floor();
        cx++
      ) {
        for (
          var cz = (wall.minZ / _wallCell).floor();
          cz <= (wall.maxZ / _wallCell).floor();
          cz++
        ) {
          _walls.putIfAbsent((cx, cz), () => []).add(wall);
        }
      }
    }

    final d = data.decks;
    for (var k = 0; k < d.length;) {
      final n = d[k].round(), half = d[k + 1];
      for (var p = 0; p < n - 1; p++) {
        final a = vm.Vector3(
          d[k + 2 + p * 3],
          d[k + 3 + p * 3],
          d[k + 4 + p * 3],
        );
        final b = vm.Vector3(
          d[k + 5 + p * 3],
          d[k + 6 + p * 3],
          d[k + 7 + p * 3],
        );
        final seg = _DeckPoint(a, b, half);
        final key = (
          ((a.x + b.x) / 2 / _deckCell).floor(),
          ((a.z + b.z) / 2 / _deckCell).floor(),
        );
        _decks.putIfAbsent(key, () => []).add(seg);
      }
      k += 2 + n * 3;
    }
  }

  bool get isEmpty => _grids.isEmpty;

  /// Terrain height at (x, z), or null outside every loaded district.
  double? terrainAt(double x, double z) {
    for (final g in _grids) {
      if (g.contains(x, z)) return g.heightAt(x, z);
    }
    return null;
  }

  /// The surface a walker at height [y] stands on at (x, z): the terrain,
  /// or a bridge deck if one is underfoot and within a step's reach above.
  /// Returns null where there is no ground (outside the city).
  double? groundAt(double x, double z, double y, {double stepUp = 1.0}) {
    var h = terrainAt(x, z);
    if (h == null) return null;
    final cx = (x / _deckCell).floor(), cz = (z / _deckCell).floor();
    for (var ox = -1; ox <= 1; ox++) {
      for (var oz = -1; oz <= 1; oz++) {
        for (final seg in _decks[(cx + ox, cz + oz)] ?? const <_DeckPoint>[]) {
          final deck = seg.heightAt(x, z);
          if (deck != null && deck <= y + stepUp && deck > h!) h = deck;
        }
      }
    }
    return h;
  }

  /// Whether (x, z) at ground height [ground] is in the river.
  bool isWater(double ground) => ground < riverLevel + 0.2;

  /// Pushes a walker of [radius] at [pos] out of any building whose roof is
  /// above its head, so it slides along walls instead of passing through.
  void resolveWalls(vm.Vector3 pos, double radius) {
    final cx = (pos.x / _wallCell).floor(), cz = (pos.z / _wallCell).floor();
    for (var pass = 0; pass < 2; pass++) {
      for (final wall in _walls[(cx, cz)] ?? const <_Wall>[]) {
        if (wall.top < pos.y + 1.5) continue; // low enough to stand on
        if (pos.x < wall.minX - radius ||
            pos.x > wall.maxX + radius ||
            pos.z < wall.minZ - radius ||
            pos.z > wall.maxZ + radius) {
          continue;
        }
        wall.pushOut(pos, radius);
      }
    }
  }
}

class _Wall {
  _Wall(this.pts, this.top) {
    for (final (x, z) in pts) {
      minX = min(minX, x);
      maxX = max(maxX, x);
      minZ = min(minZ, z);
      maxZ = max(maxZ, z);
    }
  }

  final List<(double, double)> pts;
  final double top;
  double minX = double.infinity, maxX = -double.infinity;
  double minZ = double.infinity, maxZ = -double.infinity;

  bool _inside(double x, double z) {
    var inside = false;
    for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      final (xi, zi) = pts[i];
      final (xj, zj) = pts[j];
      if ((zi > z) != (zj > z) && x < (xj - xi) * (z - zi) / (zj - zi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  void pushOut(vm.Vector3 p, double r) {
    // Nearest point on the outline.
    var best = double.infinity, bx = 0.0, bz = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final (ax, az) = pts[i];
      final (cx, cz) = pts[(i + 1) % pts.length];
      final ex = cx - ax, ez = cz - az;
      final len2 = ex * ex + ez * ez;
      final t = len2 == 0
          ? 0.0
          : (((p.x - ax) * ex + (p.z - az) * ez) / len2).clamp(0.0, 1.0);
      final qx = ax + ex * t, qz = az + ez * t;
      final d2 = (p.x - qx) * (p.x - qx) + (p.z - qz) * (p.z - qz);
      if (d2 < best) {
        best = d2;
        bx = qx;
        bz = qz;
      }
    }
    final inside = _inside(p.x, p.z);
    final d = sqrt(best);
    if (!inside && d >= r) return;
    var nx = p.x - bx, nz = p.z - bz;
    final nl = sqrt(nx * nx + nz * nz);
    if (nl < 1e-6) return;
    nx /= nl;
    nz /= nl;
    if (inside) {
      nx = -nx;
      nz = -nz;
    }
    final push = inside ? d + r : r - d;
    p.x += nx * push;
    p.z += nz * push;
  }
}

/// One straight piece of a bridge deck.
class _DeckPoint {
  _DeckPoint(this.a, this.b, this.half);
  final vm.Vector3 a, b;
  final double half;

  /// Deck height at (x, z) if that point is on this piece of deck.
  double? heightAt(double x, double z) {
    final ex = b.x - a.x, ez = b.z - a.z;
    final len2 = ex * ex + ez * ez;
    if (len2 == 0) return null;
    final t = ((x - a.x) * ex + (z - a.z) * ez) / len2;
    if (t < -0.05 || t > 1.05) return null;
    final qx = a.x + ex * t, qz = a.z + ez * t;
    if ((x - qx) * (x - qx) + (z - qz) * (z - qz) > half * half) return null;
    return a.y + (b.y - a.y) * t.clamp(0.0, 1.0);
  }
}
