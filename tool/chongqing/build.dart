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

void main(List<String> args) {
  final name = args.isEmpty ? 'yuzhong_tip' : args.first;
  final d = districtOrExit(args);
  final cache = 'tool/chongqing/cache/$name';
  if (!File('$cache/osm.json').existsSync()) {
    stderr.writeln('No cache for $name. Run fetch.dart first.');
    exitCode = 1;
    return;
  }

  final proj = LocalProjection(cityOriginLat, cityOriginLon);
  final (x0, z0) = proj.toLocal(d.north, d.west);
  final (x1, z1) = proj.toLocal(d.south, d.east);

  // ---- terrain grid ----
  final sampler = _TerrariumMosaic(cache, d);
  // Whole cells that end exactly on the district's edges, so a neighbour's
  // border vertices sit at the same places (and sample the same heights).
  final cols = ((x1 - x0) / terrainStep).round() + 1;
  final rows = ((z1 - z0) / terrainStep).round() + 1;
  final stepX = (x1 - x0) / (cols - 1), stepZ = (z1 - z0) / (rows - 1);
  final heights = Float64List(cols * rows);
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      final (lat, lon) = proj.toLatLon(x0 + i * stepX, z0 + j * stepZ);
      heights[j * cols + i] = sampler.elevation(lat, lon);
    }
  }
  // One river level for the whole city (see districts.dart).
  final valid = heights.where((h) => h > 100).toList()..sort();
  const riverLevel = cityRiverLevel;
  for (var k = 0; k < heights.length; k++) {
    if (heights[k] < riverLevel) heights[k] = riverLevel - 4;
  }
  final terrain = GridTerrain(
    minX: x0,
    minZ: z0,
    spacing: stepX,
    spacingZ: stepZ,
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

  // Every layer is split into square tiles so the app can skip tiles that
  // are off screen (frustum culling) or too far away to matter.
  for (final MeshLayer l in city.layers) {
    if (l.name == 'terrain') {
      // The terrain is a regular grid: each tile stores only its sub-grid's
      // heights and colours (sharing its edge rows with neighbours); the app
      // rebuilds positions and the fixed triangle pattern.
      final cellsX = (tileSize / stepX).round(),
          cellsZ = (tileSize / stepZ).round();
      for (var i0 = 0; i0 < cols - 1; i0 += cellsX) {
        for (var j0 = 0; j0 < rows - 1; j0 += cellsZ) {
          final i1 = min(cols - 1, i0 + cellsX),
              j1 = min(rows - 1, j0 + cellsZ);
          final tc = i1 - i0 + 1, tr = j1 - j0 + 1;
          final h = Float32List(tc * tr);
          final col = Uint8List(tc * tr * 4);
          var minY = double.infinity, maxY = -double.infinity;
          for (var j = 0; j < tr; j++) {
            for (var i = 0; i < tc; i++) {
              final v = (j0 + j) * cols + (i0 + i);
              h[j * tc + i] = l.positions[v * 3 + 1];
              minY = min(minY, h[j * tc + i]);
              maxY = max(maxY, h[j * tc + i]);
              col.setRange(
                (j * tc + i) * 4,
                (j * tc + i) * 4 + 4,
                l.colors,
                v * 4,
              );
            }
          }
          pad();
          final ho = bytes.length;
          bytes.add(h.buffer.asUint8List());
          final co = bytes.length;
          bytes.add(col);
          layers.add({
            'name': l.name,
            'grid': {
              'cols': tc,
              'rows': tr,
              'minX': x0 + i0 * stepX,
              'minZ': z0 + j0 * stepZ,
              'stepX': stepX,
              'stepZ': stepZ,
            },
            'bounds': [
              x0 + i0 * stepX,
              minY,
              z0 + j0 * stepZ,
              x0 + i1 * stepX,
              maxY,
              z0 + j1 * stepZ,
            ],
            'vertexCount': tc * tr,
            'heights': ho,
            'colors': co,
          });
        }
      }
      continue;
    }
    for (final tile in splitIntoTiles(l, x0, z0, tileSize)) {
      pad();
      final pos = bytes.length;
      bytes.add(tile.positionsF32().buffer.asUint8List());
      final col = bytes.length;
      bytes.add(tile.colorsU8());
      pad();
      final uv = bytes.length;
      if (tile.hasUv) bytes.add(tile.uvsF32().buffer.asUint8List());
      final idx = bytes.length;
      // 16-bit indices when they fit: half the index data.
      final small = tile.vertexCount <= 65535;
      bytes.add(
        small
            ? Uint16List.fromList(tile.indices).buffer.asUint8List()
            : tile.indicesU32().buffer.asUint8List(),
      );
      layers.add({
        'name': l.name,
        'bounds': tileBounds(tile),
        'vertexCount': tile.vertexCount,
        'indexCount': tile.indices.length,
        'indexBits': small ? 16 : 32,
        'positions': pos,
        'colors': col,
        if (tile.hasUv) 'uvs': uv,
        'indices': idx,
      });
    }
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
    'origin': {'lat': cityOriginLat, 'lon': cityOriginLon},
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

  // The district index lets the app know every district's bounds and
  // landmarks before loading any of them, so it can load districts only
  // when the camera comes near.
  final indexFile = File('${out.path}/index.json');
  final index = indexFile.existsSync()
      ? (jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>)
      : <String, dynamic>{'districts': <String, dynamic>{}};
  (index['districts'] as Map<String, dynamic>)[name] = {
    'title': d.title,
    'bounds': meta['bounds'],
    'riverLevel': riverLevel,
    'landmarks': city.landmarks,
    'rides': [for (final r in city.rides) r.kind],
  };
  index['riverLevel'] = riverLevel;
  indexFile.writeAsStringSync(const JsonEncoder.withIndent(' ').convert(index));

  final size = File('${out.path}/$name.bin').lengthSync();
  stdout.writeln('Built $name: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
  stdout.writeln(
    '  river level ${riverLevel.toStringAsFixed(1)} m, '
    'ground ${valid.first.round()}..${valid.last.round()} m',
  );
  for (final l in layers) {
    stdout.writeln(
      '  ${l['name']}: ${l['vertexCount']} vertices, '
      '${l['indexCount'] == null ? 'grid' : '${(l['indexCount'] as int) ~/ 3} triangles'}',
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

/// Edge length (metres) of the square tiles each layer is split into.
const double tileSize = 1200;

/// Splits a layer's triangles into square tiles by triangle centre, each
/// tile re-indexed into its own compact mesh.
List<MeshLayer> splitIntoTiles(
  MeshLayer l,
  double originX,
  double originZ,
  double size,
) {
  final buckets = <(int, int), List<int>>{};
  for (var t = 0; t < l.indices.length; t += 3) {
    var cx = 0.0, cz = 0.0;
    for (var k = 0; k < 3; k++) {
      cx += l.positions[l.indices[t + k] * 3];
      cz += l.positions[l.indices[t + k] * 3 + 2];
    }
    final key = (
      ((cx / 3 - originX) / size).floor(),
      ((cz / 3 - originZ) / size).floor(),
    );
    buckets.putIfAbsent(key, () => []).add(t);
  }
  final keys = buckets.keys.toList()
    ..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  return [
    for (final key in keys)
      () {
        final tile = MeshLayer(l.name, hasUv: l.hasUv);
        final remap = <int, int>{};
        for (final t in buckets[key]!) {
          for (var k = 0; k < 3; k++) {
            final v = l.indices[t + k];
            tile.indices.add(
              remap.putIfAbsent(v, () {
                tile.positions.addAll(l.positions.sublist(v * 3, v * 3 + 3));
                tile.colors.addAll(l.colors.sublist(v * 4, v * 4 + 4));
                if (l.hasUv) tile.uvs.addAll(l.uvs.sublist(v * 2, v * 2 + 2));
                return tile.vertexCount - 1;
              }),
            );
          }
        }
        return tile;
      }(),
  ];
}

/// [minX, minY, minZ, maxX, maxY, maxZ] of a mesh.
List<double> tileBounds(MeshLayer l) {
  final b = [
    double.infinity,
    double.infinity,
    double.infinity,
    -double.infinity,
    -double.infinity,
    -double.infinity,
  ];
  for (var v = 0; v < l.vertexCount; v++) {
    for (var k = 0; k < 3; k++) {
      b[k] = min(b[k], l.positions[v * 3 + k]);
      b[k + 3] = max(b[k + 3], l.positions[v * 3 + k]);
    }
  }
  return b;
}

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
