import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// A named place the diorama camera can jump to.
class Landmark {
  Landmark(this.name, this.top, this.ground, this.height);
  final String name;
  final vm.Vector3 top;
  final double ground;
  final double height;
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
    this.traffic,
    this.boatLanes,
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
  final Map<String, MeshGeometry> layers;
  final List<Landmark> landmarks;
  final List<RidePath> rides;
  final List<Detail> details;
  final List<RidePath> traffic; // drivable road centre lines
  final List<RidePath> boatLanes;

  vm.Vector2 get center => bounds.center;

  /// Loads several districts and merges them into one city. Districts are
  /// built around the same origin (tool/chongqing/districts.dart), so their
  /// geometry already lines up. Layers are keyed "district/layer".
  static Future<CityData> loadAll(String title, List<String> districts) async {
    final parts = await Future.wait(districts.map(load));
    if (parts.length == 1) return parts.first;
    final bounds = vm.Aabb2.copy(parts.first.bounds);
    for (final p in parts.skip(1)) {
      bounds.hull(p.bounds);
    }
    return CityData._(
      [for (final p in parts) ...p.traffic],
      [for (final p in parts) ...p.boatLanes],
      [for (final p in parts) ...p.details],
      title,
      parts.first.attribution,
      bounds,
      parts.first.riverLevel,
      {
        for (var i = 0; i < parts.length; i++)
          for (final e in parts[i].layers.entries)
            '${districts[i]}/${e.key}': e.value,
      },
      [for (final p in parts) ...p.landmarks],
      [for (final p in parts) ...p.rides],
    );
  }

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

    final layers = <String, MeshGeometry>{};
    for (final l in (meta['layers'] as List).cast<Map<String, dynamic>>()) {
      final n = l['vertexCount'] as int;
      final srgb = bytes.buffer.asUint8List(l['colors'] as int, n * 4);
      final colors = Float32List(n * 4);
      for (var i = 0; i < n * 4; i++) {
        // Stored as sRGB bytes; the shader wants linear.
        colors[i] = i % 4 == 3 ? 1.0 : pow(srgb[i] / 255, 2.2).toDouble();
      }
      final grid = l['grid'] as Map<String, dynamic>?;
      if (grid != null) {
        layers[l['name'] as String] = _gridMesh(
          grid,
          bytes,
          l['heights'] as int,
          colors,
        );
        continue;
      }
      final indexOffset = l['indices'] as int;
      final indexCount = l['indexCount'] as int;
      layers[l['name'] as String] = MeshGeometry.fromArrays(
        positions: bytes.buffer.asFloat32List(l['positions'] as int, n * 3),
        texCoords: l['uvs'] == null
            ? null
            : bytes.buffer.asFloat32List(l['uvs'] as int, n * 2),
        colors: colors,
        indices: (l['indexBits'] ?? 32) == 16
            ? bytes.buffer.asUint16List(indexOffset, indexCount)
            : bytes.buffer.asUint32List(indexOffset, indexCount),
      );
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
    return CityData._(
      paths('traffic', 'road'),
      paths('boatLanes', 'river'),
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
