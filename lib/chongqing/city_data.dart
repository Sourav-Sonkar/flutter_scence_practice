import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// A named place the diorama camera can jump to.
class Landmark {
  Landmark(this.name, this.top, this.ground, this.height, {this.place = false});
  final String name;
  final vm.Vector3 top;
  final double ground;
  final double height;

  /// A famous place (a square, street, park, complex) rather than one
  /// building: its chip shows no height.
  final bool place;
}

/// A path the camera can ride (cableway, monorail), sampled in metres.
class RidePath {
  RidePath(this.name, this.kind, this.points) {
    lengths.add(0);
    for (var k = 1; k < points.length; k++) {
      lengths.add(lengths.last + (points[k] - points[k - 1]).length);
    }
  }

  final String name;
  final String kind;
  final List<vm.Vector3> points;
  final List<double> lengths = [];

  double get length => lengths.last;

  /// Position and unit forward direction at distance [s] along the path.
  (vm.Vector3, vm.Vector3) sample(double s) {
    s = s.clamp(0.0, length);
    var k = 1;
    while (k < lengths.length - 1 && lengths[k] < s) {
      k++;
    }
    final a = points[k - 1], b = points[k];
    final seg = lengths[k] - lengths[k - 1];
    final t = seg <= 0 ? 0.0 : (s - lengths[k - 1]) / seg;
    return (a + (b - a) * t, (b - a).normalized());
  }
}

/// A rooftop item to instance: type name, position, size and Y rotation.
class Detail {
  Detail(this.type, this.position, this.size, this.rotation);
  final String type;
  final vm.Vector3 position;
  final vm.Vector3 size;
  final double rotation;
}

/// One district built by tool/chongqing/build.dart.
class CityData {
  CityData._(
    this.walk,
    this.traffic,
    this.boatLanes,
    this.walkways,
    this.pavements,
    this.details,
    this.title,
    this.attribution,
    this.bounds,
    this.riverLevel,
    this.layers,
    this.landmarks,
    this.rides,
  );

  final String title;
  final String attribution;
  final vm.Aabb2 bounds; // x, z in metres
  final double riverLevel;

  /// Geometry tiles: [kind] is the layer type (terrain, buildings, towers,
  /// roads, structures), [bounds] the tile's box.
  final List<({String kind, MeshGeometry geometry, vm.Aabb3 bounds})> layers;
  final List<Landmark> landmarks;
  final List<RidePath> rides;
  final List<Detail> details;
  final List<RidePath> traffic; // drivable road centre lines
  final List<RidePath> boatLanes;
  final List<RidePath> walkways; // footpaths, pedestrian streets, stairs
  final List<RidePath> pavements; // along ordinary streets

  /// Ground, walls and bridge decks for the walker.
  final WalkData walk;

  vm.Vector2 get center => bounds.center;

  /// Rebuilds a terrain grid (heights + colours only in the file) into a
  /// mesh, with the same two-triangles-per-cell pattern the build tool
  /// drapes roads and buildings on.
  static MeshGeometry _gridMesh(
    Map<String, dynamic> grid,
    Uint8List bytes,
    int heightsOffset,
    Float32List colors,
  ) {
    final cols = grid['cols'] as int, rows = grid['rows'] as int;
    final minX = (grid['minX'] as num).toDouble(),
        minZ = (grid['minZ'] as num).toDouble();
    final sx = (grid['stepX'] as num).toDouble(),
        sz = (grid['stepZ'] as num).toDouble();
    final h = bytes.buffer.asFloat32List(heightsOffset, cols * rows);
    final positions = Float32List(cols * rows * 3);
    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < cols; i++) {
        final v = j * cols + i;
        positions[v * 3] = minX + i * sx;
        positions[v * 3 + 1] = h[v];
        positions[v * 3 + 2] = minZ + j * sz;
      }
    }
    final indices = Uint32List((cols - 1) * (rows - 1) * 6);
    var k = 0;
    for (var j = 0; j < rows - 1; j++) {
      for (var i = 0; i < cols - 1; i++) {
        final a = j * cols + i, b = a + 1, c = a + cols, d = c + 1;
        // Same winding the build tool emits for upward-facing triangles.
        indices[k++] = a;
        indices[k++] = b;
        indices[k++] = d;
        indices[k++] = a;
        indices[k++] = d;
        indices[k++] = c;
      }
    }
    return MeshGeometry.fromArrays(
      positions: positions,
      colors: colors,
      indices: indices,
    );
  }

  static Future<CityData> load(String district) async {
    final meta = jsonDecode(
      await rootBundle.loadString('assets/chongqing/$district.json'),
    ) as Map<String, dynamic>;
    final raw = await rootBundle.load('assets/chongqing/$district.bin');
    // Copy so typed views start at an aligned offset.
    final bytes = Uint8List.fromList(
      raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
    );

    final layers = <({String kind, MeshGeometry geometry, vm.Aabb3 bounds})>[];
    final walkGrids = <TerrainGrid>[];
    for (final l in (meta['layers'] as List).cast<Map<String, dynamic>>()) {
      final n = l['vertexCount'] as int;
      final srgb = bytes.buffer.asUint8List(l['colors'] as int, n * 4);
      final colors = Float32List(n * 4);
      for (var i = 0; i < n * 4; i++) {
        // Stored as sRGB bytes; the shader wants linear. Alpha is linear
        // (opaque everywhere except the lamp light pools, which fade out).
        colors[i] = i % 4 == 3
            ? srgb[i] / 255
            : pow(srgb[i] / 255, 2.2).toDouble();
      }
      final grid = l['grid'] as Map<String, dynamic>?;
      final b = (l['bounds'] as List?)?.cast<num>();
      final box = b == null
          ? vm.Aabb3()
          : vm.Aabb3.minMax(
              vm.Vector3(b[0].toDouble(), b[1].toDouble(), b[2].toDouble()),
              vm.Vector3(b[3].toDouble(), b[4].toDouble(), b[5].toDouble()),
            );
      if (grid != null) {
        walkGrids.add(TerrainGrid.fromJson(grid, bytes, l['heights'] as int));
        layers.add((
          kind: l['name'] as String,
          geometry: _gridMesh(grid, bytes, l['heights'] as int, colors),
          bounds: box,
        ));
        continue;
      }
      final indexOffset = l['indices'] as int;
      final indexCount = l['indexCount'] as int;
      final geometry = MeshGeometry.fromArrays(
        positions: bytes.buffer.asFloat32List(l['positions'] as int, n * 3),
        texCoords: l['uvs'] == null
            ? null
            : bytes.buffer.asFloat32List(l['uvs'] as int, n * 2),
        colors: colors,
        indices: (l['indexBits'] ?? 32) == 16
            ? bytes.buffer.asUint16List(indexOffset, indexCount)
            : bytes.buffer.asUint32List(indexOffset, indexCount),
      );
      layers.add((kind: l['name'] as String, geometry: geometry, bounds: box));
    }

    final b = meta['bounds'] as Map<String, dynamic>;
    vm.Vector3 v3(List p) => vm.Vector3(
      (p[0] as num).toDouble(),
      (p[1] as num).toDouble(),
      (p[2] as num).toDouble(),
    );
    final types = (meta['detailTypes'] as List? ?? const []).cast<String>();
    final dm = meta['details'] as Map<String, dynamic>?;
    final details = <Detail>[];
    if (dm != null) {
      final f = bytes.buffer.asFloat32List(
        dm['offset'] as int,
        (dm['count'] as int) * 8,
      );
      for (var k = 0; k < f.length; k += 8) {
        details.add(
          Detail(
            types[f[k].round()],
            vm.Vector3(f[k + 1], f[k + 2], f[k + 3]),
            vm.Vector3(f[k + 4], f[k + 5], f[k + 6]),
            f[k + 7],
          ),
        );
      }
    }
    List<RidePath> paths(String key, String kind) => [
      for (final line in (meta[key] as List? ?? const []))
        RidePath(kind, kind, [for (final p in line as List) v3(p as List)]),
    ];
    final walkJson = meta['walk'] as Map<String, dynamic>?;
    Float32List floats(String key) {
      final m = walkJson?[key] as Map<String, dynamic>?;
      if (m == null) return Float32List(0);
      return bytes.buffer.asFloat32List(m['offset'] as int, m['floats'] as int);
    }

    final walk = WalkData(
      walkGrids,
      floats('walls'),
      floats('decks'),
      (meta['riverLevel'] as num).toDouble(),
    );
    return CityData._(
      walk,
      paths('traffic', 'road'),
      paths('boatLanes', 'river'),
      paths('walkways', 'walk'),
      paths('pavements', 'walk'),
      details,
      meta['title'] as String,
      meta['attribution'] as String,
      vm.Aabb2.minMax(
        vm.Vector2(
          (b['minX'] as num).toDouble(),
          (b['minZ'] as num).toDouble(),
        ),
        vm.Vector2(
          (b['maxX'] as num).toDouble(),
          (b['maxZ'] as num).toDouble(),
        ),
      ),
      (meta['riverLevel'] as num).toDouble(),
      layers,
      [
        for (final l
            in (meta['landmarks'] as List).cast<Map<String, dynamic>>())
          Landmark(
            l['name'] as String,
            vm.Vector3(
              (l['x'] as num).toDouble(),
              (l['y'] as num).toDouble(),
              (l['z'] as num).toDouble(),
            ),
            (l['ground'] as num).toDouble(),
            (l['height'] as num).toDouble(),
          ),
      ],
      [
        for (final r in (meta['rides'] as List).cast<Map<String, dynamic>>())
          RidePath(r['name'] as String, r['kind'] as String, [
            for (final p in r['points'] as List) v3(p as List),
          ]),
      ],
    );
  }
}

/// What the app knows about every district before loading any of them
/// (assets/chongqing/index.json, written by tool/chongqing/build.dart):
/// bounds for streaming, landmarks for the shortcut chips.
class CityIndex {
  CityIndex._(
    this.title,
    this.districts,
    this.bounds,
    this.riverLevel,
    this.landmarks,
  );

  final String title;

  /// District name to its x/z bounds.
  final Map<String, vm.Aabb2> districts;
  final vm.Aabb2 bounds;
  final double riverLevel;
  final List<Landmark> landmarks;

  vm.Vector2 get center => bounds.center;

  static Future<CityIndex> load(String title) async {
    final json = jsonDecode(
      await rootBundle.loadString('assets/chongqing/index.json'),
    ) as Map<String, dynamic>;
    final ds = (json['districts'] as Map).cast<String, dynamic>();
    final districts = <String, vm.Aabb2>{};
    final landmarks = <Landmark>[];
    double d(Object? v) => (v as num).toDouble();
    final featured = <Landmark>[], towers = <(double, Landmark)>[];
    final places = <(int, Landmark)>[];
    for (final name in ds.keys) {
      final b = ds[name]['bounds'] as Map<String, dynamic>;
      districts[name] = vm.Aabb2.minMax(
        vm.Vector2(d(b['minX']), d(b['minZ'])),
        vm.Vector2(d(b['maxX']), d(b['maxZ'])),
      );
      for (final l
          in (ds[name]['landmarks'] as List).cast<Map<String, dynamic>>()) {
        final lm = Landmark(
          l['name'] as String,
          vm.Vector3(d(l['x']), d(l['y']), d(l['z'])),
          d(l['ground']),
          d(l['height']),
          place: l['place'] == true,
        );
        if (l['place'] == true) {
          places.add(((l['rank'] as num).toInt(), lm));
        } else if (l['featured'] == true) {
          featured.add(lm);
        } else {
          towers.add((lm.height, lm));
        }
      }
    }
    // Famous places first, then other featured sights, then the tallest
    // named towers.
    places.sort((a, b) => a.$1.compareTo(b.$1));
    towers.sort((a, b) => b.$1.compareTo(a.$1));
    landmarks
      ..addAll(places.map((p) => p.$2))
      ..addAll(featured)
      ..addAll(towers.take(8).map((t) => t.$2));
    final bounds = vm.Aabb2.copy(districts.values.first);
    for (final b in districts.values.skip(1)) {
      bounds.hull(b);
    }
    return CityIndex._(
      title,
      districts,
      bounds,
      d(json['riverLevel']),
      landmarks,
    );
  }
}

/// One terrain tile's height grid (same layout the build tool drapes roads
/// and buildings on, so the walker stands exactly on the rendered ground).
class TerrainGrid {
  TerrainGrid(
    this.minX,
    this.minZ,
    this.stepX,
    this.stepZ,
    this.cols,
    this.rows,
    this.heights,
  );

  factory TerrainGrid.fromJson(
    Map<String, dynamic> g,
    Uint8List bytes,
    int offset,
  ) {
    final cols = g['cols'] as int, rows = g['rows'] as int;
    return TerrainGrid(
      (g['minX'] as num).toDouble(),
      (g['minZ'] as num).toDouble(),
      (g['stepX'] as num).toDouble(),
      (g['stepZ'] as num).toDouble(),
      cols,
      rows,
      bytes.buffer.asFloat32List(offset, cols * rows),
    );
  }

  final double minX, minZ, stepX, stepZ;
  final int cols, rows;
  final Float32List heights;

  double get maxX => minX + (cols - 1) * stepX;
  double get maxZ => minZ + (rows - 1) * stepZ;

  bool contains(double x, double z) =>
      x >= minX && x <= maxX && z >= minZ && z <= maxZ;

  /// Height on the same two-triangles-per-cell surface the mesh uses.
  double heightAt(double x, double z) {
    final fx = ((x - minX) / stepX).clamp(0.0, cols - 1.000001);
    final fz = ((z - minZ) / stepZ).clamp(0.0, rows - 1.000001);
    final i = fx.floor(), j = fz.floor();
    final u = fx - i, v = fz - j;
    double h(int a, int b) => heights[b * cols + a];
    final h00 = h(i, j),
        h10 = h(i + 1, j),
        h01 = h(i, j + 1),
        h11 = h(i + 1, j + 1);
    return u >= v
        ? h00 + (h10 - h00) * u + (h11 - h10) * v
        : h00 + (h11 - h01) * u + (h01 - h00) * v;
  }
}

/// Raw walking data for one district: terrain grids, building footprints
/// (`[n, top, x, z, ...]`) and bridge decks (`[n, half, x, y, z, ...]`).
class WalkData {
  WalkData(this.grids, this.walls, this.decks, this.riverLevel);
  final List<TerrainGrid> grids;
  final Float32List walls, decks;
  final double riverLevel;
}
