// Downloads OpenStreetMap features and elevation tiles for one district into
// tool/chongqing/cache/<district>/. Run from the project root:
//
//   fvm dart run tool/chongqing/fetch.dart yuzhong_tip
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'districts.dart';

const _userAgent = 'flutter_scene_practice/1.0 (chongqing miniature build)';
const _overpass = 'https://overpass-api.de/api/interpreter';
const terrainZoom = 15;

/// Elevation tiles are fetched for the district plus this margin (degrees),
/// so geometry that pokes past the edge (bridges, the cableway) has ground.
const terrainMarginDeg = 0.006;

Future<void> main(List<String> args) async {
  final name = args.isEmpty ? 'yuzhong_tip' : args.first;
  final d = districtOrExit(args);
  final dir = Directory('tool/chongqing/cache/$name')
    ..createSync(recursive: true);

  final bbox = '${d.south},${d.west},${d.north},${d.east}';
  final query =
      '''
[out:json][timeout:120];
(
  way["building"]($bbox);
  relation["building"]["type"="multipolygon"]($bbox);
  way["highway"]($bbox);
  way["railway"="monorail"]($bbox);
  way["aerialway"]($bbox);
  way["landuse"]($bbox);
  relation["landuse"]["type"="multipolygon"]($bbox);
  way["leisure"~"park|garden|pitch|playground"]($bbox);
  relation["leisure"~"park|garden"]["type"="multipolygon"]($bbox);
  way["natural"~"wood|scrub|grassland|heath|bare_rock|cliff"]($bbox);
  relation["natural"~"wood|scrub"]["type"="multipolygon"]($bbox);
  way["amenity"="parking"]($bbox);
  way["place"="square"]($bbox);
  node["natural"="tree"]($bbox);
  way["waterway"="river"]($bbox);
  node["railway"~"station|halt"]($bbox);
);
out geom;
''';
  stdout.writeln('Fetching OpenStreetMap features for ${d.title}...');
  final osm = await http.post(
    Uri.parse(_overpass),
    headers: {'User-Agent': _userAgent},
    body: {'data': query},
  );
  if (osm.statusCode != 200 || !osm.body.startsWith('{')) {
    stderr.writeln(
      'Overpass failed (${osm.statusCode}): '
      '${osm.body.substring(0, min(200, osm.body.length))}',
    );
    exitCode = 1;
    return;
  }
  File('${dir.path}/osm.json').writeAsStringSync(osm.body);
  stdout.writeln('  saved ${(osm.bodyBytes.length / 1024).round()} KB');

  final tiles = terrainTiles(d);
  stdout.writeln('Fetching ${tiles.length} elevation tiles (z$terrainZoom)...');
  final tileDir = Directory('${dir.path}/terrain')..createSync();
  for (final (x, y) in tiles) {
    final file = File('${tileDir.path}/${terrainZoom}_${x}_$y.png');
    if (file.existsSync()) continue;
    final res = await http.get(
      Uri.parse(
        'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/'
        '$terrainZoom/$x/$y.png',
      ),
      headers: {'User-Agent': _userAgent},
    );
    if (res.statusCode != 200) {
      stderr.writeln('Tile $x,$y failed (${res.statusCode})');
      exitCode = 1;
      return;
    }
    file.writeAsBytesSync(res.bodyBytes);
  }
  stdout.writeln('Done. Next: fvm dart run tool/chongqing/build.dart $name');
}

/// Web-mercator tile indices covering the district plus margin.
List<(int, int)> terrainTiles(District d) {
  final (x0, y0) = _tileOf(
    d.north + terrainMarginDeg,
    d.west - terrainMarginDeg,
  );
  final (x1, y1) = _tileOf(
    d.south - terrainMarginDeg,
    d.east + terrainMarginDeg,
  );
  return [
    for (var x = x0; x <= x1; x++)
      for (var y = y0; y <= y1; y++) (x, y),
  ];
}

(int, int) _tileOf(double lat, double lon) {
  final n = 1 << terrainZoom;
  final x = ((lon + 180) / 360 * n).floor();
  final r = lat * pi / 180;
  final y = ((1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * n).floor();
  return (x, y);
}
