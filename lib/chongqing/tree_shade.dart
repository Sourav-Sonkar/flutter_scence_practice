import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';

/// Soft shadows under trees and shrubs: one dark oval per plant, draped on
/// the terrain, fading to nothing at its rim and drawn blended so it darkens
/// whatever ground is below. Each oval is pushed and stretched away from the
/// sun, longer as the sun gets lower, like the tree's real shadow.
///
/// Real tree shadows cost a re-draw of every tree per shadow cascade, so
/// they are only on at High quality; this costs about one draw per visible
/// tile in every style. Built at load from the tree details and the terrain,
/// so it adds nothing to the download.
class TreeShade {
  /// Adds the shade of [data]'s plants under [parent].
  TreeShade(CityData data, Node parent) : _data = data {
    final byTile = <(int, int), List<Detail>>{};
    for (final d in data.details) {
      if (!_types.contains(d.type)) continue;
      final key = (
        (d.position.x / _tileSize).floor(),
        (d.position.z / _tileSize).floor(),
      );
      byTile.putIfAbsent(key, () => []).add(d);
    }
    for (final trees in byTile.values) {
      final tile = _Tile(trees);
      _write(tile, _offset);
      parent.add(tile.node..mesh = Mesh(tile.geometry(), material));
      _tiles.add(tile);
    }
  }

  static const _types = {
    'treeHuangge',
    'treeCamphor',
    'treeBanyan',
    'treeGinkgo',
    'shrub',
  };

  /// Split so off-screen tiles are frustum culled.
  static const double _tileSize = 400;

  /// Soft and small on screen, so six sides read as round.
  static const int _segments = 6;

  /// The longest shadow, in canopy radii, so a low sun can't stretch them
  /// across the street.
  static const double _maxReach = 2.5;

  /// Shared by every district; [CityView] sets its colour and strength
  /// from the time of day and the weather.
  static final UnlitMaterial material = UnlitMaterial()
    ..alphaMode = AlphaMode.blend;

  final CityData _data;
  final List<_Tile> _tiles = [];

  /// Shadow offset on the ground per metre of height, away from the sun.
  vm.Vector2 _offset = vm.Vector2.zero();

  /// Follows the sun: when it has moved enough to notice, re-places the
  /// shadows, one tile per call so there is never a hitch.
  void update(vm.Vector3 sun) {
    // Below the horizon the shade only lingers as a soft blot (it fades out
    // anyway); a very low sun is capped so shadows stay readable.
    final target = sun.y <= 0
        ? vm.Vector2.zero()
        : vm.Vector2(-sun.x, -sun.z) / max(sun.y, 0.2);
    if ((target - _offset).length > 0.08) {
      _offset = target;
      for (final t in _tiles) {
        t.dirty = true;
      }
    }
    for (final t in _tiles) {
      if (!t.dirty) continue;
      _write(t, _offset);
      // A fresh mesh for the tile; this only happens when the sun has
      // visibly moved, one tile per frame.
      t.node.mesh = Mesh(t.geometry(), material);
      t.dirty = false;
      return;
    }
  }

  double? _terrainAt(double x, double z) {
    for (final g in _data.walk.grids) {
      if (g.contains(x, z)) return g.heightAt(x, z);
    }
    return null;
  }

  void _write(_Tile tile, vm.Vector2 offset) {
    final dirLen = offset.length;
    final dir = dirLen < 1e-6 ? vm.Vector2(1, 0) : offset / dirLen;
    final positions = tile.positions;
    var v = 0;
    for (final tree in tile.trees) {
      final p = tree.position;
      final radius = tree.size.x * 0.55;
      // The canopy's middle casts the shadow.
      final reach = min(tree.size.y * 0.6 * dirLen, radius * _maxReach);
      final cx = p.x + dir.x * reach * 0.5;
      final centreZ = p.z + dir.y * reach * 0.5;
      final along = radius + reach * 0.5; // stretched away from the sun
      final ground = _terrainAt(p.x, p.z);
      // Plants on a bridge deck stand well above the terrain: stay flat.
      final onDeck = ground == null || p.y > ground + 1;
      void vertex(double x, double z) {
        final g = onDeck ? null : _terrainAt(x, z);
        positions[v * 3] = x;
        positions[v * 3 + 1] = g == null
            ? p.y + 0.1
            : max(g, _data.walk.riverLevel) + 0.25;
        positions[v * 3 + 2] = z;
        v++;
      }

      vertex(cx, centreZ);
      for (var s = 0; s < _segments; s++) {
        final t = s / _segments * 2 * pi;
        final a = cos(t) * along, b = sin(t) * radius;
        // a along the shadow direction, b across it.
        vertex(cx + dir.x * a - dir.y * b, centreZ + dir.y * a + dir.x * b);
      }
    }
  }
}

class _Tile {
  _Tile(this.trees)
    : positions = Float32List(trees.length * (TreeShade._segments + 1) * 3),
      colors = Float32List(trees.length * (TreeShade._segments + 1) * 4),
      indices = Uint32List(trees.length * TreeShade._segments * 3) {
    const n = TreeShade._segments;
    var k = 0;
    final lo = vm.Vector3.all(double.infinity);
    final hi = vm.Vector3.all(-double.infinity);
    for (var i = 0; i < trees.length; i++) {
      final centre = i * (n + 1);
      // Dark in the middle, clear at the rim; white so the material colours it.
      for (var j = 0; j <= n; j++) {
        final c = (centre + j) * 4;
        colors[c] = colors[c + 1] = colors[c + 2] = 1;
        colors[c + 3] = j == 0 ? 1 : 0;
      }
      // Wound like the terrain grid so the ovals face up (translucent
      // meshes are always back-face culled).
      for (var s = 0; s < n; s++) {
        indices[k++] = centre;
        indices[k++] = centre + 1 + s;
        indices[k++] = centre + 1 + (s + 1) % n;
      }
      final p = trees[i].position;
      final r = trees[i].size.x * (1 + TreeShade._maxReach) + 2;
      lo
        ..x = min(lo.x, p.x - r)
        ..y = min(lo.y, p.y - 30)
        ..z = min(lo.z, p.z - r);
      hi
        ..x = max(hi.x, p.x + r)
        ..y = max(hi.y, p.y + 5)
        ..z = max(hi.z, p.z + r);
    }
    // Wide enough for every shadow the sun can cast, so moving them never
    // gets them culled.
    bounds = vm.Aabb3.minMax(lo, hi);
  }

  final List<Detail> trees;
  final Float32List positions, colors;
  final Uint32List indices;
  late final vm.Aabb3 bounds;
  final Node node = Node(name: 'tree shade')..castsShadows = false;
  bool dirty = false;

  MeshGeometry geometry() => MeshGeometry.fromArrays(
    positions: positions,
    colors: colors,
    indices: indices,
    bounds: bounds,
  );
}
