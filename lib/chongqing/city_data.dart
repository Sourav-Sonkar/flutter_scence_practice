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

/// One district built by tool/chongqing/build.dart.
class CityData {
  CityData._(
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

  vm.Vector2 get center => bounds.center;

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
      layers[l['name'] as String] = MeshGeometry.fromArrays(
        positions: bytes.buffer.asFloat32List(l['positions'] as int, n * 3),
        colors: colors,
        indices: bytes.buffer.asUint32List(
          l['indices'] as int,
          l['indexCount'] as int,
        ),
      );
    }

    final b = meta['bounds'] as Map<String, dynamic>;
    vm.Vector3 v3(List p) => vm.Vector3(
      (p[0] as num).toDouble(),
      (p[1] as num).toDouble(),
      (p[2] as num).toDouble(),
    );
    return CityData._(
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
