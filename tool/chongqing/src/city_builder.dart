import 'dart:math';

import 'geo.dart';
import 'mesh_layer.dart';
import 'polygon.dart';
import '../landmarks.dart';

typedef Rgb = (int, int, int);
typedef V3 = (double, double, double);

/// Result of building one district.
/// A path the camera can ride along, in local metres.
typedef Ride = ({String name, String kind, List<V3> points});

class CityBuild {
  CityBuild(this.layers, this.rides, this.landmarks, this.stats);
  final List<MeshLayer> layers;
  final List<Ride> rides;
  final List<Map<String, Object>> landmarks;
  final Map<String, int> stats;
}

/// Where a building's height came from, in fallback order.
enum HeightSource { tag, levels, landmark, estimate }

/// Height in metres for a building's tags, plus where it came from.
/// [area] is the footprint in m², [hash] a stable 0..1 value per building.
(double, HeightSource) buildingHeight(
  Map<String, dynamic> tags,
  double area,
  double hash,
) {
  final h = _metres(tags['height']);
  if (h != null && h > 2) return (h, HeightSource.tag);
  final levels = double.tryParse('${tags['building:levels'] ?? ''}');
  if (levels != null && levels > 0) {
    return (levels * 3.2 + 1.5, HeightSource.levels);
  }
  final known = landmarkHeight(tags);
  if (known != null) return (known, HeightSource.landmark);
  final type = '${tags['building']}';
  const small = {
    'house',
    'detached',
    'hut',
    'shed',
    'garage',
    'garages',
    'roof',
    'kiosk',
    'toilets',
    'service',
    'cabin',
    'gatehouse',
    'shrine',
    'temple',
  };
  if (small.contains(type)) return (4 + hash * 4, HeightSource.estimate);
  // Yuzhong is mostly mid- and high-rise; bigger footprints read taller.
  if (area < 120) return (8 + hash * 7, HeightSource.estimate);
  if (area < 400) return (15 + hash * 30, HeightSource.estimate);
  if (area < 1500) return (40 + hash * 70, HeightSource.estimate);
  return (50 + hash * 90, HeightSource.estimate);
}

double? _metres(Object? v) {
  if (v == null) return null;
  final m = RegExp(r'[-\d.]+').firstMatch('$v');
  return m == null ? null : double.tryParse(m.group(0)!);
}

double _hash01(int id) {
  var x = id * 0x9E3779B1 & 0xFFFFFFFF;
  x ^= x >> 15;
  x = x * 0x85EBCA77 & 0xFFFFFFFF;
  x ^= x >> 13;
  return (x & 0xFFFFFF) / 0x1000000;
}

/// Road half-widths (m) and colours by highway class; null means skip.
(double, Rgb, double)? roadStyle(Map<String, dynamic> tags) {
  final hw = '${tags['highway']}';
  const asphalt = (54, 56, 62);
  const paving = (168, 160, 148);
  const stairs = (128, 112, 98);
  return switch (hw) {
    'motorway' || 'trunk' => (7.0, asphalt, 0.9),
    'primary' => (6.0, asphalt, 0.9),
    'secondary' => (5.0, asphalt, 0.85),
    'tertiary' => (4.0, asphalt, 0.8),
    'motorway_link' ||
    'trunk_link' ||
    'primary_link' ||
    'secondary_link' ||
    'tertiary_link' => (3.5, asphalt, 0.8),
    'residential' || 'unclassified' || 'living_street' => (3.0, asphalt, 0.7),
    'service' => (2.5, asphalt, 0.65),
    'pedestrian' => (2.5, paving, 0.6),
    'footway' || 'path' || 'cycleway' => (1.2, paving, 0.5),
    'steps' => (1.4, stairs, 0.55),
    _ => null,
  };
}

bool _underground(Map<String, dynamic> tags) {
  final layer = int.tryParse('${tags['layer'] ?? 0}') ?? 0;
  return tags['tunnel'] != null && tags['tunnel'] != 'no' ||
      tags['covered'] == 'yes' ||
      tags['indoor'] == 'yes' ||
      tags['highway'] == 'corridor' ||
      layer < 0;
}

bool _elevated(Map<String, dynamic> tags) {
  final b = tags['bridge'];
  return b != null && b != 'no';
}

class CityBuilder {
  CityBuilder(this.proj, this.terrain, this.riverLevel);

  final LocalProjection proj;
  final GridTerrain terrain;
  final double riverLevel;
  final Map<String, int> stats = {};

  void _count(String k) => stats[k] = (stats[k] ?? 0) + 1;

  bool _inside(double x, double z) =>
      x >= terrain.minX && x <= terrain.maxX && z >= terrain.minZ && z <= terrain.maxZ;

  /// Splits a resampled line into the runs that lie inside the district.
  List<List<int>> _insideRuns(List<P2> pts) {
    final runs = <List<int>>[];
    List<int>? cur;
    for (var k = 0; k < pts.length; k++) {
      if (_inside(pts[k].$1, pts[k].$2)) {
        (cur ??= []).add(k);
      } else if (cur != null) {
        if (cur.length > 1) runs.add(cur);
        cur = null;
      }
    }
    if (cur != null && cur.length > 1) runs.add(cur);
    return runs;
  }

  CityBuild build(List<Map<String, dynamic>> elements) {
    final ground = _terrainLayer();
    final buildings = MeshLayer('buildings');
    final roads = MeshLayer('roads');
    final structures = MeshLayer('structures'); // bridges, piers, rail, cable
    final landmarks = <Map<String, Object>>[];
    final monorail = <List<V3>>[];
    final rides = <Ride>[];

    for (final e in elements) {
      final tags = (e['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
      final id = (e['id'] as num).toInt();
      if (tags.containsKey('building')) {
        for (final ring in _rings(e)) {
          final lm = _building(buildings, ring, tags, id);
          if (lm != null) landmarks.add(lm);
        }
      } else if (tags.containsKey('highway') && e['type'] == 'way') {
        _road(roads, structures, _line(e), tags);
      } else if (tags['railway'] == 'monorail' && e['type'] == 'way') {
        if (_underground(tags)) {
          _count('monorail tunnel pieces skipped');
          continue;
        }
        final track = _monorail(structures, _line(e));
        if (track.length > 1) monorail.add(track);
      } else if (tags['aerialway'] == 'cable_car' && e['type'] == 'way') {
        final path = _cableway(structures, _line(e));
        if (path.isNotEmpty && !rides.any((r) => r.kind == 'cableway')) {
          final name = tags['name:en'] ?? tags['name'] ?? 'Cableway';
          rides.add((name: '$name', kind: 'cableway', points: path));
        }
      }
    }
    landmarks.sort(
      (a, b) => (b['height'] as num).compareTo(a['height'] as num),
    );
    final runs = _chain(monorail);
    if (runs.isNotEmpty) {
      rides.insert(0, (
        name: 'Monorail Line 2',
        kind: 'monorail',
        points: runs.first,
      ));
    }
    return CityBuild(
      [ground, buildings, roads, structures],
      rides,
      landmarks.take(12).toList(),
      stats,
    );
  }

  // ---- terrain ----

  MeshLayer _terrainLayer() {
    final layer = MeshLayer('terrain');
    for (var j = 0; j < terrain.rows; j++) {
      for (var i = 0; i < terrain.cols; i++) {
        final h = terrain.vertex(i, j);
        layer.vertex(
          terrain.minX + i * terrain.spacing,
          h,
          terrain.minZ + j * terrain.spacing,
          _groundColor(h),
        );
      }
    }
    for (var j = 0; j < terrain.rows - 1; j++) {
      for (var i = 0; i < terrain.cols - 1; i++) {
        final a = j * terrain.cols + i, b = a + 1;
        final c = a + terrain.cols, d = c + 1;
        // Same (i,j)-(i+1,j+1) diagonal as GridTerrain.heightAt.
        layer.triangle(a, b, d, (0, 1, 0));
        layer.triangle(a, d, c, (0, 1, 0));
      }
    }
    return layer;
  }

  Rgb _groundColor(double h) {
    final above = h - riverLevel;
    if (above < 1) return (92, 84, 70); // riverbed under water
    if (above < 8) return (150, 138, 112); // muddy bank
    final t = ((above - 8) / 140).clamp(0.0, 1.0);
    // Urban ground: warm grey lower down, a little greener up the hill.
    return (
      (150 - 30 * t).round(),
      (146 - 12 * t).round(),
      (134 - 30 * t).round(),
    );
  }

  // ---- buildings ----

  List<List<P2>> _rings(Map<String, dynamic> e) {
    if (e['type'] == 'way') return [_ringFromGeom(e['geometry'])];
    final out = <List<P2>>[];
    for (final m in (e['members'] as List? ?? const [])) {
      if (m['role'] != 'outer' || m['geometry'] == null) continue;
      final g = m['geometry'] as List;
      final first = g.first, last = g.last;
      if (first['lat'] == last['lat'] && first['lon'] == last['lon']) {
        out.add(_ringFromGeom(g));
      } else {
        _count('relation outers skipped (split across ways)');
      }
    }
    return out;
  }

  List<P2> _ringFromGeom(Object? geom) => cleanRing([
    for (final p in (geom as List? ?? const []))
      proj.toLocal((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble()),
  ]);

  List<P2> _line(Map<String, dynamic> e) => [
    for (final p in (e['geometry'] as List? ?? const []))
      proj.toLocal((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble()),
  ];

  Map<String, Object>? _building(
    MeshLayer out,
    List<P2> ring,
    Map<String, dynamic> tags,
    int id,
  ) {
    if (ring.length < 3) return null;
    final area = signedArea2(ring).abs() / 2;
    if (area < 4) return null;
    final hash = _hash01(id);
    final (height, source) = buildingHeight(tags, area, hash);
    _count('buildings (height from ${source.name})');

    // Sit on the lowest ground under the footprint, so on slopes the uphill
    // side is buried, the way Chongqing's hillside towers are.
    var base = double.infinity, cx = 0.0, cz = 0.0;
    for (final (x, z) in ring) {
      base = min(base, terrain.heightAt(x, z));
      cx += x;
      cz += z;
    }
    cx /= ring.length;
    cz /= ring.length;
    if (!_inside(cx, cz)) {
      _count('buildings outside district (skipped)');
      return null;
    }
    base = max(base, riverLevel) - 0.5;
    final top = base + 0.5 + height;

    final (wall, roof) = _buildingColors(tags, hash, height);
    out.prism(ring, base, top, wall, roof, triangulate(ring));

    final name = tags['name:en'] ?? tags['name'];
    if (name == null || height < 60) return null;
    return {
      'name': '$name',
      'x': cx,
      'y': top,
      'z': cz,
      'ground': base + 0.5,
      'height': height.round(),
    };
  }

  (Rgb, Rgb) _buildingColors(Map<String, dynamic> tags, double hash, double h) {
    final type = '${tags['building']}';
    final glass =
        h > 90 ||
        const {'commercial', 'office', 'hotel', 'retail'}.contains(type);
    final palette = glass
        ? const [
            (150, 170, 186),
            (126, 148, 166),
            (176, 186, 192),
            (110, 128, 140),
          ]
        : const [
            (214, 204, 186),
            (196, 186, 170),
            (226, 220, 208),
            (184, 170, 156),
            (200, 196, 190),
          ];
    final base = palette[(hash * palette.length).floor() % palette.length];
    final roof = (
      (base.$1 * 0.78).round(),
      (base.$2 * 0.78).round(),
      (base.$3 * 0.78).round(),
    );
    return (base, roof);
  }

  // ---- roads and bridges ----

  /// Resamples a polyline every [step] metres.
  List<P2> _resample(List<P2> line, double step) {
    final out = <P2>[];
    for (var k = 0; k < line.length - 1; k++) {
      final (x0, z0) = line[k];
      final (x1, z1) = line[k + 1];
      final len = sqrt(pow(x1 - x0, 2) + pow(z1 - z0, 2));
      final n = max(1, (len / step).ceil());
      for (var s = 0; s < n; s++) {
        final t = s / n;
        out.add((x0 + (x1 - x0) * t, z0 + (z1 - z0) * t));
      }
    }
    if (line.isNotEmpty) out.add(line.last);
    return out;
  }

  void _road(
    MeshLayer roads,
    MeshLayer structures,
    List<P2> line,
    Map<String, dynamic> tags,
  ) {
    if (line.length < 2) return;
    if (_underground(tags)) {
      _count('road pieces underground (skipped)');
      return;
    }
    final style = roadStyle(tags);
    if (style == null) return;
    final (half, color, lift) = style;
    final pts = _resample(line, 4);
    final heights = List<double>.generate(
      pts.length,
      (k) => terrain.heightAt(pts[k].$1, pts[k].$2) + lift,
    );

    if (_elevated(tags)) {
      _count('bridges');
      // Deck runs straight between its ends but never dips into the ground.
      final h0 = heights.first, h1 = heights.last;
      for (var k = 0; k < pts.length; k++) {
        final t = k / (pts.length - 1);
        final ground = terrain.heightAt(pts[k].$1, pts[k].$2);
        heights[k] = max(h0 + (h1 - h0) * t, max(ground, riverLevel) + 1.5);
      }
      _piers(structures, pts, heights, half);
    } else {
      _count('roads');
      for (var k = 0; k < pts.length; k++) {
        heights[k] = max(heights[k], riverLevel + lift);
      }
    }
    for (final run in _insideRuns(pts)) {
      _ribbon(roads, [for (final k in run) pts[k]], [for (final k in run) heights[k]],
          half, color);
    }
  }

  void _ribbon(
    MeshLayer out,
    List<P2> pts,
    List<double> heights,
    double half,
    Rgb rgb,
  ) {
    int? prevL, prevR;
    for (var k = 0; k < pts.length; k++) {
      final a = pts[max(0, k - 1)], b = pts[min(pts.length - 1, k + 1)];
      var dx = b.$1 - a.$1, dz = b.$2 - a.$2;
      final len = sqrt(dx * dx + dz * dz);
      if (len < 1e-6) continue;
      dx /= len;
      dz /= len;
      final (x, z) = pts[k];
      final l = out.vertex(x - dz * half, heights[k], z + dx * half, rgb);
      final r = out.vertex(x + dz * half, heights[k], z - dx * half, rgb);
      if (prevL != null) out.quad(prevL, prevR!, r, l, (0, 1, 0));
      prevL = l;
      prevR = r;
    }
  }

  void _piers(MeshLayer out, List<P2> pts, List<double> deck, double half) {
    const concrete = (176, 174, 168);
    var since = 0.0;
    for (var k = 1; k < pts.length; k++) {
      since += sqrt(
        pow(pts[k].$1 - pts[k - 1].$1, 2) + pow(pts[k].$2 - pts[k - 1].$2, 2),
      );
      if (since < 30) continue;
      since = 0;
      final (x, z) = pts[k];
      if (!_inside(x, z)) continue;
      final ground = max(terrain.heightAt(x, z), riverLevel - 4);
      if (deck[k] - ground < 4) continue;
      final dx = pts[k].$1 - pts[k - 1].$1, dz = pts[k].$2 - pts[k - 1].$2;
      final len = sqrt(dx * dx + dz * dz);
      out.box(
        x,
        z,
        ground,
        deck[k] - 0.4,
        2.0,
        half * 1.4,
        dx / len,
        dz / len,
        concrete,
      );
      _count('piers');
    }
  }

  // ---- monorail ----

  List<V3> _monorail(MeshLayer out, List<P2> line) {
    if (line.length < 2) return const [];
    _count('monorail pieces');
    final pts = _resample(line, 4);
    // Ride ~8 m above the ground, smoothed so the beam doesn't follow every
    // bump, and never closer than 5 m.
    final raw = [
      for (final (x, z) in pts) max(terrain.heightAt(x, z), riverLevel) + 8,
    ];
    final heights = List<double>.generate(raw.length, (k) {
      var s = 0.0, n = 0;
      for (var m = max(0, k - 8); m <= min(raw.length - 1, k + 8); m++) {
        s += raw[m];
        n++;
      }
      final ground = max(terrain.heightAt(pts[k].$1, pts[k].$2), riverLevel);
      return max(s / n, ground + 5);
    });
    const beam = (196, 198, 200);
    // Beam: a 1.6 m wide, 2 m deep box swept along the track.
    _ribbon(out, pts, heights, 0.8, beam);
    _ribbon(out, pts, [for (final h in heights) h - 2], 0.8, beam);
    for (var side = -1; side <= 1; side += 2) {
      int? prevTop, prevBottom;
      for (var k = 0; k < pts.length; k++) {
        final a = pts[max(0, k - 1)], b = pts[min(pts.length - 1, k + 1)];
        var dx = b.$1 - a.$1, dz = b.$2 - a.$2;
        final len = sqrt(dx * dx + dz * dz);
        dx /= len;
        dz /= len;
        final x = pts[k].$1 + side * -dz * 0.8, z = pts[k].$2 + side * dx * 0.8;
        final t = out.vertex(x, heights[k], z, beam);
        final bt = out.vertex(x, heights[k] - 2, z, beam);
        if (prevTop != null) {
          out.quad(prevBottom!, bt, t, prevTop, (side * -dz, 0, side * dx));
        }
        prevTop = t;
        prevBottom = bt;
      }
    }
    _piers(out, pts, [for (final h in heights) h - 2], 0.8);
    return [
      for (var k = 0; k < pts.length; k++) (pts[k].$1, heights[k], pts[k].$2),
    ];
  }

  /// Joins track pieces that share end points into longer runs, longest first.
  List<List<V3>> _chain(List<List<V3>> pieces) {
    final left = [...pieces];
    final runs = <List<V3>>[];
    bool near(V3 a, V3 b) => pow(a.$1 - b.$1, 2) + pow(a.$3 - b.$3, 2) < 4;
    while (left.isNotEmpty) {
      final run = [...left.removeAt(0)];
      var grew = true;
      while (grew) {
        grew = false;
        for (var i = 0; i < left.length; i++) {
          final p = left[i];
          if (near(run.last, p.first)) {
            run.addAll(p.skip(1));
          } else if (near(run.last, p.last)) {
            run.addAll(p.reversed.skip(1));
          } else if (near(run.first, p.last)) {
            run.insertAll(0, p.take(p.length - 1));
          } else if (near(run.first, p.first)) {
            run.insertAll(0, p.reversed.take(p.length - 1));
          } else {
            continue;
          }
          left.removeAt(i);
          grew = true;
          break;
        }
      }
      runs.add(run);
    }
    double length(List<V3> r) {
      var s = 0.0;
      for (var k = 1; k < r.length; k++) {
        s += sqrt(
          pow(r[k].$1 - r[k - 1].$1, 2) + pow(r[k].$3 - r[k - 1].$3, 2),
        );
      }
      return s;
    }

    runs.sort((a, b) => length(b).compareTo(length(a)));
    return runs;
  }

  // ---- cableway ----

  /// Draws the cableway and returns the cabin's path (centre line).
  List<V3> _cableway(MeshLayer out, List<P2> line) {
    if (line.length < 2) return const [];
    _count('cableway lines');
    final a = line.first, b = line.last;
    const steel = (70, 72, 78);
    const station = (190, 120, 90);
    double top(P2 p) => max(terrain.heightAt(p.$1, p.$2), riverLevel) + 22;
    final ha = top(a), hb = top(b);
    final dx = b.$1 - a.$1, dz = b.$2 - a.$2;
    final len = sqrt(dx * dx + dz * dz);
    for (final (p, h) in [(a, ha), (b, hb)]) {
      out.box(
        p.$1,
        p.$2,
        terrain.heightAt(p.$1, p.$2),
        h + 2,
        14,
        10,
        dx / len,
        dz / len,
        station,
      );
    }
    // Two cables with a gentle sag.
    for (final off in [-3.0, 3.0]) {
      final ox = -dz / len * off, oz = dx / len * off;
      final pts = <P2>[];
      final hs = <double>[];
      const n = 60;
      for (var k = 0; k <= n; k++) {
        final t = k / n;
        pts.add((a.$1 + dx * t + ox, a.$2 + dz * t + oz));
        hs.add(ha + (hb - ha) * t - 18 * 4 * t * (1 - t));
      }
      _ribbon(out, pts, hs, 0.25, steel);
    }
    const n = 120;
    return [
      for (var k = 0; k <= n; k++)
        (
          a.$1 + dx * k / n,
          ha + (hb - ha) * k / n - 18 * 4 * (k / n) * (1 - k / n) - 4,
          a.$2 + dz * k / n,
        ),
    ];
  }
}
