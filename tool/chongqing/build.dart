// Builds the 3D asset for one district from the fetch cache. Run from the
// project root after fetch.dart:
//
//   fvm dart run tool/chongqing/build.dart yuzhong_tip
//
// Writes assets/chongqing/<district>.bin (geometry) and .json (layout,
// landmarks, monorail path).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'districts.dart';
import 'fetch.dart' show terrainTiles, terrainZoom;
import 'src/city_builder.dart';
import 'src/geo.dart';
import 'src/mesh_layer.dart';

const gridSpacing = 8.0;

void main(List<String> args) {
  final name = args.isEmpty ? 'yuzhong_tip' : args.first;
  final d = districtOrExit(args);
  final cache = 'tool/chongqing/cache/$name';
  if (!File('$cache/osm.json').existsSync()) {
    stderr.writeln('No cache for $name. Run fetch.dart first.');
    exitCode = 1;
    return;
  }

  final proj = LocalProjection(d.centerLat, d.centerLon);
  final (x0, z0) = proj.toLocal(d.north, d.west);
  final (x1, z1) = proj.toLocal(d.south, d.east);

  // ---- terrain grid ----
  final sampler = _TerrariumMosaic(cache, d);
  final cols = ((x1 - x0) / gridSpacing).floor() + 1;
  final rows = ((z1 - z0) / gridSpacing).floor() + 1;
  final heights = Float64List(cols * rows);
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      final (lat, lon) = proj.toLatLon(
        x0 + i * gridSpacing,
        z0 + j * gridSpacing,
      );
      heights[j * cols + i] = sampler.elevation(lat, lon);
    }
  }
  // River surface. The elevation data is noisy over water (about 154 to
  // 165 m here) and has voids that read as -3000 m, so take the level just
  // below the 25th percentile of plausible ground: it covers the river noise
  // while staying under Chongqing's riverside roads (~185 m).
  final valid = heights.where((h) => h > 100).toList()..sort();
  final riverLevel = valid[(valid.length * 0.25).floor()] - 1;
  for (var k = 0; k < heights.length; k++) {
    if (heights[k] < riverLevel) heights[k] = riverLevel - 4;
  }
  final terrain = GridTerrain(
    minX: x0,
    minZ: z0,
    spacing: gridSpacing,
    cols: cols,
    rows: rows,
    heights: heights,
  );

  // ---- features ----
  final osm = jsonDecode(File('$cache/osm.json').readAsStringSync()) as Map;
  final elements = (osm['elements'] as List).cast<Map<String, dynamic>>();
  final city = CityBuilder(proj, terrain, riverLevel).build(elements);

  // ---- write ----
  final out = Directory('assets/chongqing')..createSync(recursive: true);
  final bytes = BytesBuilder();
  final layers = <Map<String, Object>>[];
  void pad() {
    while (bytes.length % 4 != 0) {
      bytes.addByte(0);
    }
  }

  for (final MeshLayer l in city.layers) {
    pad();
    final pos = bytes.length;
    bytes.add(l.positionsF32().buffer.asUint8List());
    final col = bytes.length;
    bytes.add(l.colorsU8());
    pad();
    final uv = bytes.length;
    if (l.hasUv) bytes.add(l.uvsF32().buffer.asUint8List());
    final idx = bytes.length;
    bytes.add(l.indicesU32().buffer.asUint8List());
    layers.add({
      'name': l.name,
      'vertexCount': l.vertexCount,
      'indexCount': l.indices.length,
      'positions': pos,
      'colors': col,
      if (l.hasUv) 'uvs': uv,
      'indices': idx,
    });
  }
  pad();
  final detailsOffset = bytes.length;
  bytes.add(
    Float32List.fromList([
      for (final d in city.details) ...[
        d.type.index.toDouble(),
        d.x,
        d.y,
        d.z,
        d.sx,
        d.sy,
        d.sz,
        d.rot,
      ],
    ]).buffer.asUint8List(),
  );
  File('${out.path}/$name.bin').writeAsBytesSync(bytes.takeBytes());

  final meta = {
    'version': 1,
    'district': name,
    'title': d.title,
    'attribution': '© OpenStreetMap contributors (ODbL); elevation: Mapzen Terrarium / AWS Open Data',
    'origin': {'lat': d.centerLat, 'lon': d.centerLon},
    'bounds': {'minX': x0, 'maxX': x1, 'minZ': z0, 'maxZ': z1},
    'riverLevel': riverLevel,
    'groundRange': [valid.first, valid.last],
    'layers': layers,
    'rides': [
      for (final r in city.rides)
        {
          'name': r.name,
          'kind': r.kind,
          'points': [
            for (final (x, y, z) in r.points) [_r(x), _r(y), _r(z)],
          ],
        },
    ],
    'landmarks': city.landmarks,
    'detailTypes': [for (final t in DetailType.values) t.name],
    // Rooftop items and plants live in the .bin as 8 floats each:
    // type, x, y, z, sx, sy, sz, rotation.
    'details': {'offset': detailsOffset, 'count': city.details.length},
    'traffic': [
      for (final line in city.traffic)
        [
          for (final (x, y, z) in line) [_r1(x), _r1(y), _r1(z)],
        ],
    ],
    'boatLanes': [
      for (final line in city.boatLanes)
        [
          for (final (x, y, z) in line) [_r1(x), _r1(y), _r1(z)],
        ],
    ],
    'stats': city.stats,
  };
  File('${out.path}/$name.json')
      .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(meta));

  final size = File('${out.path}/$name.bin').lengthSync();
  stdout.writeln('Built $name: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
  stdout.writeln(
    '  river level ${riverLevel.toStringAsFixed(1)} m, '
    'ground ${valid.first.round()}..${valid.last.round()} m',
  );
  for (final l in layers) {
    stdout.writeln(
      '  ${l['name']}: ${l['vertexCount']} vertices, '
      '${(l['indexCount'] as int) ~/ 3} triangles',
    );
  }
  city.stats.forEach((k, v) => stdout.writeln('  $k: $v'));
  stdout.writeln(
    '  rides: ${city.rides.map((r) => '${r.name} (${r.points.length} pts)').join(', ')}',
  );
  stdout.writeln(
    '  landmarks: ${city.landmarks.map((l) => '${l['name']} ${l['height']}m').join(', ')}',
  );
}

double _r(double v) => (v * 100).roundToDouble() / 100;
double _r1(double v) => (v * 10).roundToDouble() / 10;

/// Elevation from cached Terrarium tiles: metres = R*256 + G + B/256 - 32768.
class _TerrariumMosaic {
  _TerrariumMosaic(String cache, District d) {
    for (final (x, y) in terrainTiles(d)) {
      final f = File('$cache/terrain/${terrainZoom}_${x}_$y.png');
      _tiles[(x, y)] = img.decodePng(f.readAsBytesSync())!;
    }
  }

  final Map<(int, int), img.Image> _tiles = {};

  double _pixel(int gx, int gy) {
    final t = _tiles[(gx ~/ 256, gy ~/ 256)];
    if (t == null) return -32768;
    final p = t.getPixel(gx % 256, gy % 256);
    return p.r * 256 + p.g + p.b / 256 - 32768;
  }

  double elevation(double lat, double lon) {
    final n = (1 << terrainZoom) * 256.0;
    final r = lat * pi / 180;
    final px = (lon + 180) / 360 * n - 0.5;
    final py = (1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * n - 0.5;
    final ix = px.floor(), iy = py.floor();
    final u = px - ix, v = py - iy;
    final a = _pixel(ix, iy), b = _pixel(ix + 1, iy);
    final c = _pixel(ix, iy + 1), e = _pixel(ix + 1, iy + 1);
    return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + e * u) * v;
  }
}
