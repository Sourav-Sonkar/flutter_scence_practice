import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../tool/chongqing/src/city_builder.dart';
import '../tool/chongqing/src/geo.dart';
import '../tool/chongqing/src/mesh_layer.dart';
import '../tool/chongqing/src/polygon.dart';

GridTerrain _terrain(double Function(double x, double z) h) {
  const cols = 41, rows = 41, spacing = 10.0;
  final heights = Float64List(cols * rows);
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      heights[j * cols + i] = h(-200 + i * spacing, -200 + j * spacing);
    }
  }
  return GridTerrain(
      minX: -200, minZ: -200, spacing: spacing, cols: cols, rows: rows, heights: heights);
}

void main() {
  test('projection round-trips lat/lon', () {
    final p = LocalProjection(29.56, 106.58);
    final (x, z) = p.toLocal(29.565, 106.585);
    final (lat, lon) = p.toLatLon(x, z);
    expect(lat, closeTo(29.565, 1e-9));
    expect(lon, closeTo(106.585, 1e-9));
    expect(x, greaterThan(0)); // east is +x
    expect(z, lessThan(0)); // north is -z
  });

  test('ear clipping covers a concave L-shape exactly', () {
    final ring = <P2>[(0, 0), (20, 0), (20, 10), (10, 10), (10, 30), (0, 30)];
    final tris = triangulate(ring);
    expect(tris.length, (ring.length - 2) * 3);
    var area = 0.0;
    for (var t = 0; t < tris.length; t += 3) {
      area += signedArea2([ring[tris[t]], ring[tris[t + 1]], ring[tris[t + 2]]]).abs() / 2;
    }
    expect(area, closeTo(signedArea2(ring).abs() / 2, 1e-9));
  });

  test('building height falls back tag > levels > landmark > estimate', () {
    expect(buildingHeight({'height': '120 m', 'building:levels': '10'}, 500, 0.5),
        (120.0, HeightSource.tag));
    expect(buildingHeight({'building:levels': '10'}, 500, 0.5).$2, HeightSource.levels);
    expect(buildingHeight({'name:en': 'World Trade Centre Chongqing'}, 500, 0.5),
        (283.0, HeightSource.landmark));
    final est = buildingHeight({'building': 'yes'}, 2000, 0.5);
    expect(est.$2, HeightSource.estimate);
    expect(est.$1, inInclusiveRange(50, 140));
  });

  test('triangles are wound for flutter_scene front faces', () {
    // flutter_scene culls the face whose right-handed normal points at the
    // viewer, so an upward-facing quad must have a downward cross product.
    final layer = MeshLayer('t');
    final a = layer.vertex(0, 0, 0, (0, 0, 0));
    final b = layer.vertex(1, 0, 0, (0, 0, 0));
    final c = layer.vertex(0, 0, 1, (0, 0, 0));
    layer.triangle(a, b, c, (0, 1, 0));
    final p = layer.positions;
    final i = layer.indices;
    double at(int v, int k) => p[i[v] * 3 + k];
    final ux = at(1, 0) - at(0, 0), uz = at(1, 2) - at(0, 2);
    final vx = at(2, 0) - at(0, 0), vz = at(2, 2) - at(0, 2);
    final ny = uz * vx - ux * vz;
    expect(ny, lessThan(0));
  });

  test('bridges stay above the ground and the river', () {
    // A valley 30 m deep between two hills, with a river level of 100 m.
    final terrain = _terrain((x, z) => 130 - 30 * (1 - (x.abs() / 150).clamp(0, 1)));
    final city = CityBuilder(LocalProjection(29.56, 106.58), terrain, 100).build([
      {
        'type': 'way',
        'id': 1,
        'tags': {'highway': 'primary', 'bridge': 'yes'},
        'geometry': [
          {'lat': 29.56, 'lon': 106.5785},
          {'lat': 29.56, 'lon': 106.5815},
        ],
      },
    ]);
    final roads = city.layers.firstWhere((l) => l.name == 'roads');
    expect(roads.vertexCount, greaterThan(0));
    for (var v = 0; v < roads.vertexCount; v++) {
      final x = roads.positions[v * 3], y = roads.positions[v * 3 + 1];
      final z = roads.positions[v * 3 + 2];
      expect(y, greaterThan(terrain.heightAt(x, z)));
      expect(y, greaterThan(100));
    }
    expect(city.stats['bridges'], 1);
  });
}
