import 'dart:math';

import 'geo.dart';
import 'greenery.dart';
import 'mesh_layer.dart';
import 'polygon.dart';
import '../landmarks.dart';

typedef Rgb = (int, int, int);
typedef V3 = (double, double, double);

/// Result of building one district.
/// A path the camera can ride along, in local metres.
typedef Ride = ({String name, String kind, List<V3> points});

/// Small rooftop items placed by instancing at runtime (shown only when the
/// camera is close). Rotation is about +Y in radians.
enum DetailType {
  waterTank,
  acUnit,
  stairHut,
  plant,
  helipad,
  mast,
  // Vegetation, after Chongqing's common urban plants.
  treeHuangge, // Ficus virens, the city tree: wide, low, dark canopy
  treeCamphor, // Cinnamomum camphora: round, dense, mid green
  treeBanyan, // Ficus microcarpa: broad, glossy, dark
  treeGinkgo, // narrow, light yellow-green
  shrub,
  planter, // long, low green planter boxes along bridge railings
  streetLamp, // pole at the road edge; local +x is the arm, pointing at the road
  crown, // LED band around the top of a skyscraper, lit at night
  powerPole, // utility pole; local +x is the crossarm (across the street)
  // A sagging cable. Encoded differently from other details: position is
  // one end, size is the vector to the other end, rotation is the sag.
  wire,
}

typedef Detail = ({
  DetailType type,
  double x,
  double y,
  double z,
  double sx,
  double sy,
  double sz,
  double rot,
});

class CityBuild {
  CityBuild(
    this.layers,
    this.rides,
    this.landmarks,
    this.stats,
    this.details,
    this.traffic,
    this.boatLanes,
  );
  final List<List<V3>> traffic; // drivable road centre lines, for cars
  final List<List<V3>> boatLanes; // lanes on the rivers, for boats

  /// For walking: building footprints with their roof height (walls), and
  /// bridge decks (walkable surfaces above the terrain).
  late List<(List<P2>, double)> walls;
  late List<({List<P2> pts, List<double> heights, double half})> decks;
  final List<MeshLayer> layers;
  final List<Ride> rides;
  final List<Detail> details;
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
  // Big, low public buildings: a wide footprint here does not mean a tower.
  final low = switch (type) {
    'stadium' || 'grandstand' => 32.0,
    'museum' ||
    'civic' ||
    'public' ||
    'government' ||
    'church' ||
    'temple' => 24.0,
    'school' || 'college' || 'train_station' || 'transportation' => 18.0,
    'warehouse' || 'industrial' || 'sports_hall' => 14.0,
    _ => null,
  };
  if (low != null) return (low * (0.85 + hash * 0.3), HeightSource.estimate);
  // Historic sites are old low buildings, whatever their footprint.
  if (tags.containsKey('historic') || tags.containsKey('heritage')) {
    return (10 + hash * 6, HeightSource.estimate);
  }
  if (tags['tourism'] == 'museum' ||
      tags['leisure'] == 'stadium' ||
      tags['leisure'] == 'sports_hall') {
    return (24 * (0.85 + hash * 0.3), HeightSource.estimate);
  }
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
  // Very large footprints are usually malls or podiums, with any towers on
  // them mapped as separate buildings.
  if (area < 4000) return (30 + hash * 60, HeightSource.estimate);
  return (20 + hash * 25, HeightSource.estimate);
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
  const asphalt = (74, 76, 84);
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

  static bool _isArea(Map<String, dynamic> e, Map<String, dynamic> tags) {
    if (tags['area'] == 'yes' || tags['place'] == 'square') return true;
    final g = e['geometry'] as List? ?? const [];
    final closed =
        g.length > 3 &&
        g.first['lat'] == g.last['lat'] &&
        g.first['lon'] == g.last['lon'];
    return closed && tags['highway'] == 'pedestrian';
  }

  bool _inside(double x, double z) =>
      x >= terrain.minX &&
      x <= terrain.maxX &&
      z >= terrain.minZ &&
      z <= terrain.maxZ;

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
    // Reach one sample past each end so roads meet across district borders
    // instead of leaving a small gap.
    return [
      for (final r in runs)
        [
          if (r.first > 0) r.first - 1,
          ...r,
          if (r.last < pts.length - 1) r.last + 1,
        ],
    ];
  }

  final List<List<P2>> _buildingRings = [];
  final List<(List<P2>, double)> _walls = [];
  final List<
    ({
      List<P2> pts,
      List<double> heights,
      double half,
      bool bridge,
      String kind,
    })
  >
  _roadRuns = [];

  CityBuild build(List<Map<String, dynamic>> elements) {
    final covers = <(Cover, List<P2>)>[];
    final featured = <Map<String, Object>>[];
    final monorailLines = <List<P2>>[];
    final rivers = <List<P2>>[];
    final homes = MeshLayer('buildings', hasUv: true);
    final towers = MeshLayer('towers', hasUv: true);
    final roads = MeshLayer('roads');
    final structures = MeshLayer('structures'); // bridges, piers, rail, cable
    _structures = structures;
    final landmarks = <Map<String, Object>>[];
    final monorail = <List<V3>>[];
    final rides = <Ride>[];

    for (final e in elements) {
      final tags = (e['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
      final id = (e['id'] as num).toInt();
      if (tags.containsKey('building')) {
        for (final ring in _rings(e)) {
          final lm = _building(homes, towers, ring, tags, id);
          if (lm == null) continue;
          (_isGreatHall(tags) ? featured : landmarks).add(lm);
        }
      } else if (tags.containsKey('highway') &&
          e['type'] == 'way' &&
          _isArea(e, tags)) {
        // Plazas such as People's Square: paved ground, not a road ribbon.
        final ring = _ringFromGeom(e['geometry']);
        if (ring.length >= 3) covers.add((Cover.paved, ring));
        _count('plaza areas');
        final name = tags['name:en'] ?? tags['name'];
        if (name != null && tags['place'] == 'square' && ring.length >= 3) {
          var cx = 0.0, cz = 0.0;
          for (final (x, z) in ring) {
            cx += x;
            cz += z;
          }
          cx /= ring.length;
          cz /= ring.length;
          if (_inside(cx, cz)) {
            final g = terrain.heightAt(cx, cz);
            featured.add({
              'name': '$name',
              'x': cx,
              'y': g + 30,
              'z': cz,
              'ground': g,
              'height': 30,
            });
          }
        }
      } else if (e['type'] == 'node' && tags.containsKey('railway')) {
        // Stations become featured places: Liziba, where Line 2 runs
        // through a residential building, is the famous one.
        final (x, z) = proj.toLocal(
          (e['lat'] as num).toDouble(),
          (e['lon'] as num).toDouble(),
        );
        final name = tags['name:en'] ?? tags['name'];
        if (name != null &&
            _inside(x, z) &&
            '$name'.contains(RegExp('Liziba|李子坝'))) {
          final g = max(terrain.heightAt(x, z), riverLevel);
          featured.add({
            'name': '$name Station',
            'x': x,
            'y': g + 40,
            'z': z,
            'ground': g,
            'height': 40,
          });
        }
      } else if (tags.containsKey('highway') && e['type'] == 'way') {
        _road(roads, structures, _line(e), tags);
      } else if (tags['railway'] == 'monorail' && e['type'] == 'way') {
        if (_underground(tags)) {
          _count('monorail tunnel pieces skipped');
          continue;
        }
        // Built after all roads, so the track can clear elevated roads.
        monorailLines.add(_line(e));
      } else if (coverFor(tags) case final cover?
          when !tags.containsKey('building')) {
        for (final ring in _rings(e)) {
          if (ring.length >= 3) covers.add((cover, ring));
        }
      } else if (tags['waterway'] == 'river' && e['type'] == 'way') {
        rivers.add(_line(e));
      } else if (tags['aerialway'] == 'cable_car' && e['type'] == 'way') {
        final path = _cableway(structures, _line(e));
        if (path.isNotEmpty && !rides.any((r) => r.kind == 'cableway')) {
          final name = tags['name:en'] ?? tags['name'] ?? 'Cableway';
          rides.add((name: '$name', kind: 'cableway', points: path));
        }
      }
    }
    // Chips: famous places first, then the tallest towers with real names
    // (skip block labels such as "T3A幢", "5栋", "A座").
    final blockLabel = RegExp(r'^[A-Za-z0-9\-]+\s*[幢栋座号楼]$|^[①-⑳]');
    landmarks
      ..removeWhere(
        (l) => blockLabel.hasMatch(l['name'] as String) || l['en'] != true,
      )
      ..sort((a, b) => (b['height'] as num).compareTo(a['height'] as num));
    for (final f in featured) {
      f['featured'] = true;
    }
    landmarks.insertAll(0, featured);
    // The track is built after all roads so it can clear road bridges.
    for (final line in monorailLines) {
      final track = _monorail(structures, line);
      if (track.length > 1) monorail.add(track);
    }

    final runs = _chain(monorail);
    if (runs.isNotEmpty) {
      rides.insert(0, (
        name: 'Monorail Line 2',
        kind: 'monorail',
        points: runs.first,
      ));
    }
    // Masks keep trees off buildings, roads and the monorail corridor.
    final built = Mask(terrain);
    for (final r in _buildingRings) {
      built.markRing(r);
    }
    final paved = Mask(terrain);
    for (final r in _roadRuns) {
      for (final (x, z) in r.pts) {
        paved.markDisc(x, z, r.half + 1);
      }
    }
    for (final track in monorail) {
      for (final (x, _, z) in track) {
        // Wide enough that even a broad huangge canopy stays clear of the beam.
        paved.markDisc(x, z, 12);
      }
    }
    final ground = _terrainLayer(covers);
    _vegetation(covers, built, paved);
    _powerLines(built);
    return CityBuild(
        [ground, homes, towers, roads, structures],
        rides,
        landmarks.take(12).toList(),
        stats,
        _details,
        _trafficLines(),
        _boatLanes(rivers),
      )
      ..walls = _walls
      ..decks = [
        for (final r in _roadRuns)
          if (r.bridge) (pts: r.pts, heights: r.heights, half: r.half),
      ];
  }

  // ---- terrain ----

  MeshLayer _terrainLayer(List<(Cover, List<P2>)> covers) {
    final layer = MeshLayer('terrain');
    for (var j = 0; j < terrain.rows; j++) {
      for (var i = 0; i < terrain.cols; i++) {
        final h = terrain.vertex(i, j);
        final x = terrain.minX + i * terrain.spacing;
        final z = terrain.minZ + j * terrain.spacingZ;
        var color = _groundColor(h);
        if (h - riverLevel >= 8) {
          // Green on steep unbuilt slopes, the way Chongqing's cliffs look.
          final slope = _slope(x, z);
          if (slope > 0.3) {
            final t = ((slope - 0.3) / 0.4).clamp(0.0, 1.0);
            color = _mix(color, (82, 128, 62), t);
          }
          for (final (cover, ring) in covers) {
            if (pointInRing((x, z), ring)) {
              color = coverColor(cover);
              break;
            }
          }
        }
        layer.vertex(x, h, z, color);
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

  double _slope(double x, double z) {
    const d = 6.0;
    final gx =
        (terrain.heightAt(x + d, z) - terrain.heightAt(x - d, z)) / (2 * d);
    final gz =
        (terrain.heightAt(x, z + d) - terrain.heightAt(x, z - d)) / (2 * d);
    return sqrt(gx * gx + gz * gz);
  }

  static Rgb _mix(Rgb a, Rgb b, double t) => (
    (a.$1 + (b.$1 - a.$1) * t).round(),
    (a.$2 + (b.$2 - a.$2) * t).round(),
    (a.$3 + (b.$3 - a.$3) * t).round(),
  );

  // ---- vegetation, traffic, boats ----

  void _addPlant(
    DetailType type,
    double x,
    double y,
    double z,
    double height,
    double width,
    Rng rng,
  ) {
    _details.add((
      type: type,
      x: x,
      y: y,
      z: z,
      sx: width,
      sy: height,
      sz: width * (0.85 + rng.next() * 0.3),
      rot: rng.next() * pi,
    ));
    _count('plants ${type.name}');
  }

  void _tree(double x, double z, Rng rng, {bool park = false, double? y}) {
    final r = rng.next();
    final ground = y ?? terrain.heightAt(x, z);
    if (park && r < 0.12) {
      _addPlant(
        DetailType.shrub,
        x,
        ground,
        z,
        1.6 + rng.next(),
        2.4 + rng.next(),
        rng,
      );
    } else if (r < 0.4) {
      _addPlant(
        DetailType.treeHuangge,
        x,
        ground,
        z,
        10 + rng.next() * 6,
        10 + rng.next() * 5,
        rng,
      );
    } else if (r < 0.7) {
      _addPlant(
        DetailType.treeCamphor,
        x,
        ground,
        z,
        9 + rng.next() * 5,
        7 + rng.next() * 3,
        rng,
      );
    } else if (r < 0.85) {
      _addPlant(
        DetailType.treeBanyan,
        x,
        ground,
        z,
        8 + rng.next() * 4,
        9 + rng.next() * 3,
        rng,
      );
    } else {
      _addPlant(
        DetailType.treeGinkgo,
        x,
        ground,
        z,
        10 + rng.next() * 5,
        4 + rng.next() * 2,
        rng,
      );
    }
  }

  void _vegetation(List<(Cover, List<P2>)> covers, Mask built, Mask paved) {
    final rng = Rng(20261105);
    // Scatter on a jittered lattice: parks and woods densely, steep unbuilt
    // slopes fairly densely, other open ground sparsely.
    const step = 9.0;
    for (var z = terrain.minZ + step / 2; z < terrain.maxZ; z += step) {
      for (var x = terrain.minX + step / 2; x < terrain.maxX; x += step) {
        final px = x + (rng.next() - 0.5) * step * 0.8;
        final pz = z + (rng.next() - 0.5) * step * 0.8;
        final h = terrain.heightAt(px, pz);
        if (h - riverLevel < 6 || built.at(px, pz) || paved.at(px, pz)) {
          continue;
        }
        Cover? cover;
        for (final (c, ring) in covers) {
          if (pointInRing((px, pz), ring)) {
            cover = c;
            break;
          }
        }
        final green =
            cover == Cover.park || cover == Cover.wood || cover == Cover.grass;
        final p = switch (cover) {
          Cover.wood => 0.85,
          Cover.park => 0.6,
          Cover.grass => 0.15,
          Cover.paved || Cover.construction => 0.0,
          _ => _slope(px, pz) > 0.35 ? 0.7 : 0.08,
        };
        if (rng.next() < p) _tree(px, pz, rng, park: green);
      }
    }
    // Street trees along main roads, and planters along bridge railings.
    for (final r in _roadRuns) {
      final major = const {
        'primary',
        'secondary',
        'tertiary',
        'trunk',
      }.contains(r.kind);
      if (!major && !r.bridge) continue;
      final every = r.bridge ? 2 : 3; // samples are 4 m apart
      for (var k = 1; k < r.pts.length - 1; k += every) {
        var dx = r.pts[k + 1].$1 - r.pts[k - 1].$1,
            dz = r.pts[k + 1].$2 - r.pts[k - 1].$2;
        final len = sqrt(dx * dx + dz * dz);
        if (len < 1e-6) continue;
        dx /= len;
        dz /= len;
        for (final side in [-1.0, 1.0]) {
          if (r.bridge && k % 3 == 1) {
            // One planter per ~12 m along the railing.
            final off = r.half - 0.7;
            final x = r.pts[k].$1 - dz * off * side,
                z = r.pts[k].$2 + dx * off * side;
            _details.add((
              type: DetailType.planter,
              x: x,
              y: r.heights[k],
              z: z,
              sx: 0.9,
              sy: 0.8,
              sz: 6.0,
              rot: atan2(dx, dz), // long side along the railing
            ));
            _count('bridge planters');
          }
          if (k % 8 == 4) {
            // A street lamp standing on the road edge (or bridge deck), its
            // arm reaching over the road.
            final off = r.half + (r.bridge ? -0.3 : 1.0);
            final x = r.pts[k].$1 - dz * off * side,
                z = r.pts[k].$2 + dx * off * side;
            if (_inside(x, z) && !built.at(x, z)) {
              // Local +x after rotation must point back toward the road.
              final tx = dz * side, tz = -dx * side;
              _details.add((
                type: DetailType.streetLamp,
                x: x,
                y: r.bridge ? r.heights[k] : terrain.heightAt(x, z),
                z: z,
                sx: 1,
                sy: 1,
                sz: 1,
                rot: atan2(-tz, tx),
              ));
              _count('street lamps');
            }
          }
          if (!r.bridge && k % 3 == 1) {
            final off = r.half + 2.5;
            final x = r.pts[k].$1 - dz * off * side,
                z = r.pts[k].$2 + dx * off * side;
            if (!_inside(x, z) || built.at(x, z) || paved.at(x, z)) continue;
            if (rng.next() < 0.75) _tree(x, z, rng);
          }
        }
      }
    }
  }

  List<List<V3>> _trafficLines() => [
    for (final r in _roadRuns)
      if (const {
            'primary',
            'secondary',
            'tertiary',
            'trunk',
            'motorway',
            'primary_link',
            'secondary_link',
            'tertiary_link',
            'trunk_link',
          }.contains(r.kind) &&
          r.pts.length > 4)
        [
          for (var k = 0; k < r.pts.length; k += 3)
            (r.pts[k].$1, r.heights[k], r.pts[k].$2),
        ],
  ];

  /// Lanes on the water alongside each river's centre line, kept only where
  /// the whole lane is over water.
  List<List<V3>> _boatLanes(List<List<P2>> rivers) {
    final lanes = <List<V3>>[];
    for (final river in rivers) {
      final pts = _resample(river, 25);
      for (final off in [-110.0, -45.0, 45.0, 110.0]) {
        List<V3>? cur;
        void flush() {
          if (cur != null && cur!.length > 12) lanes.add(cur!);
          cur = null;
        }

        for (var k = 1; k < pts.length - 1; k++) {
          var dx = pts[k + 1].$1 - pts[k - 1].$1,
              dz = pts[k + 1].$2 - pts[k - 1].$2;
          final len = sqrt(dx * dx + dz * dz);
          dx /= len;
          dz /= len;
          final x = pts[k].$1 - dz * off, z = pts[k].$2 + dx * off;
          final wet = _inside(x, z) && terrain.heightAt(x, z) < riverLevel - 1;
          if (wet) {
            (cur ??= []).add((x, riverLevel + 0.6, z));
          } else {
            flush();
          }
        }
        flush();
      }
    }
    _count('boat lanes');
    stats['boat lanes'] = lanes.length;
    return lanes;
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

  final List<Detail> _details = [];
  late MeshLayer _structures;

  static bool _isGreatHall(Map<String, dynamic> tags) {
    final n = '${tags['name'] ?? ''} ${tags['name:en'] ?? ''}';
    return n.contains('人民大礼堂') || n.contains("People's Grand Hall");
  }

  /// Chongqing People's Grand Hall, generated in code: a white stone base,
  /// cream wings with teal glazed roofs, and the central red rotunda under
  /// three tiers of teal roof with a gold finial (about 65 m), modelled on
  /// the hall's well-known shape. Returns the top height.
  double _greatHall(List<P2> ring, double base) {
    const stone = (226, 222, 212), cream = (236, 228, 208);
    const red = (178, 52, 40), teal = (46, 116, 106), gold = (232, 188, 80);
    final out = _structures;
    final tris = triangulate(ring);
    out.prism(ring, base, base + 4, stone, stone, tris);
    out.prism(ring, base + 4, base + 16, cream, teal, tris);
    // The rotunda sits on the main block; its centre is the centroid of the
    // footprint's largest-area triangle fan, close enough to the hall's
    // centre on this outline.
    var cx = 0.0, cz = 0.0, total = 0.0;
    for (var t = 0; t < tris.length; t += 3) {
      final a = ring[tris[t]], b = ring[tris[t + 1]], c = ring[tris[t + 2]];
      final area = signedArea2([a, b, c]).abs() / 2;
      cx += (a.$1 + b.$1 + c.$1) / 3 * area;
      cz += (a.$2 + b.$2 + c.$2) / 3 * area;
      total += area;
    }
    cx /= total;
    cz /= total;
    final y = base + 16;
    out.frustum(cx, cz, y, y + 12, 22, 22, red);
    out.frustum(cx, cz, y + 12, y + 18, 29, 19, teal);
    out.frustum(cx, cz, y + 18, y + 24, 18, 18, red);
    out.frustum(cx, cz, y + 24, y + 29, 23, 14, teal);
    out.frustum(cx, cz, y + 29, y + 33, 13, 13, red);
    out.frustum(cx, cz, y + 33, y + 43, 17, 1.5, teal);
    out.frustum(cx, cz, y + 43, y + 49, 1.4, 0.2, gold, segments: 12);
    _count('landmark models (Great Hall)');
    return y + 49;
  }

  Map<String, Object>? _building(
    MeshLayer homes,
    MeshLayer towers,
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

    if (_isGreatHall(tags)) {
      final top = _greatHall(ring, base);
      _buildingRings.add(ring);
      _walls.add((ring, top));
      return {
        'name': '${tags['name:en'] ?? tags['name']}',
        'x': cx,
        'y': top,
        'z': cz,
        'ground': base + 0.5,
        'height': (top - base).round(),
      };
    }
    final glass = _isGlass(tags, height);
    final out = glass ? towers : homes;
    final (wall, roof) = _buildingColors(glass, hash);

    // Big, tall buildings get a podium with a slimmer tower on top, the
    // usual Chongqing shape. The tower is the footprint shrunk about its
    // centre, used only if it stays inside the footprint.
    var roofRing = ring;
    if (area > 1200 && height > 50) {
      final tower = scaleRing(ring, 0.68);
      if (tower.every((p) => pointInRing(p, ring))) {
        final podiumTop = base + 0.5 + min(18.0, height * 0.22);
        out.prism(
          ring,
          base,
          podiumTop,
          wall,
          roof,
          triangulate(ring),
          facadeGround: base + 0.5,
        );
        out.prism(
          tower,
          podiumTop,
          top,
          wall,
          roof,
          triangulate(tower),
          facadeGround: base + 0.5,
        );
        roofRing = tower;
        _count('podium + tower buildings');
      } else {
        out.prism(
          ring,
          base,
          top,
          wall,
          roof,
          triangulate(ring),
          facadeGround: base + 0.5,
        );
      }
    } else {
      out.prism(
        ring,
        base,
        top,
        wall,
        roof,
        triangulate(ring),
        facadeGround: base + 0.5,
      );
    }
    _rooftop(roofRing, top, glass, height, hash, id);
    if (height > 140) _crown(roofRing, top);
    _buildingRings.add(ring);
    _walls.add((ring, top));

    final name = tags['name:en'] ?? tags['name'];
    if (name == null || height < 60) return null;
    return {
      'name': '$name',
      'x': cx,
      'y': top,
      'z': cz,
      'ground': base + 0.5,
      'height': height.round(),
      'en': tags['name:en'] != null,
    };
  }

  bool _isGlass(Map<String, dynamic> tags, double h) =>
      h > 90 ||
      const {
        'commercial',
        'office',
        'hotel',
        'retail',
      }.contains('${tags['building']}');

  /// Wall and roof colours. Brighter and warmer than real life on purpose:
  /// a painted-model palette is a big part of the miniature look.
  (Rgb, Rgb) _buildingColors(bool glass, double hash) {
    final palette = glass
        ? const [
            (120, 168, 196), // blue glass
            (150, 186, 200), // pale teal
            (196, 204, 210), // silver
            (98, 132, 160), // deep blue
            (206, 192, 160), // champagne
          ]
        : const [
            (240, 228, 204), // cream
            (236, 200, 170), // peach
            (214, 160, 128), // terracotta
            (240, 232, 190), // pale yellow
            (232, 234, 236), // white tile
            (198, 200, 196), // grey tile
          ];
    final base = palette[(hash * 997).floor() % palette.length];
    final roof = glass
        ? (92, 98, 104)
        : const [
            (168, 160, 150),
            (150, 156, 160),
            (176, 120, 96),
          ][(hash * 31).floor() % 3];
    return (base, roof);
  }

  /// An LED band hugging the top of a tall tower. The band is the tower's
  /// footprint fitted with an oriented box (principal axes), so it follows
  /// rotated towers instead of an axis-aligned square.
  void _crown(List<P2> ring, double top) {
    var cx = 0.0, cz = 0.0;
    for (final (x, z) in ring) {
      cx += x;
      cz += z;
    }
    cx /= ring.length;
    cz /= ring.length;
    var sxx = 0.0, szz = 0.0, sxz = 0.0;
    for (final (x, z) in ring) {
      sxx += (x - cx) * (x - cx);
      szz += (z - cz) * (z - cz);
      sxz += (x - cx) * (z - cz);
    }
    final angle = 0.5 * atan2(2 * sxz, sxx - szz);
    final ux = cos(angle), uz = sin(angle);
    var minA = double.infinity, maxA = -double.infinity;
    var minB = double.infinity, maxB = -double.infinity;
    for (final (x, z) in ring) {
      final a = (x - cx) * ux + (z - cz) * uz;
      final b = -(x - cx) * uz + (z - cz) * ux;
      minA = min(minA, a);
      maxA = max(maxA, a);
      minB = min(minB, b);
      maxB = max(maxB, b);
    }
    final midA = (minA + maxA) / 2, midB = (minB + maxB) / 2;
    _details.add((
      type: DetailType.crown,
      x: cx + ux * midA - uz * midB,
      y: top - 4,
      z: cz + uz * midA + ux * midB,
      sx: maxA - minA + 0.6,
      sy: 2.5,
      sz: maxB - minB + 0.6,
      // Rotation about +Y that maps local x onto the principal axis.
      rot: -angle,
    ));
    _count('led crowns');
  }

  /// Scatters rooftop items inside [ring] at height [y].
  void _rooftop(
    List<P2> ring,
    double y,
    bool glass,
    double height,
    double hash,
    int id,
  ) {
    var seed = id * 2654435761 & 0x7fffffff;
    double rnd() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    var minX = double.infinity, maxX = -double.infinity;
    var minZ = double.infinity, maxZ = -double.infinity;
    for (final (x, z) in ring) {
      minX = min(minX, x);
      maxX = max(maxX, x);
      minZ = min(minZ, z);
      maxZ = max(maxZ, z);
    }
    final area = signedArea2(ring).abs() / 2;
    if (area < 40) return;

    bool place(
      DetailType type,
      double sx,
      double sy,
      double sz, {
      bool centre = false,
    }) {
      for (var attempt = 0; attempt < 12; attempt++) {
        final x = centre ? (minX + maxX) / 2 : minX + rnd() * (maxX - minX);
        final z = centre ? (minZ + maxZ) / 2 : minZ + rnd() * (maxZ - minZ);
        final r = max(sx, sz) * 0.75;
        if (!pointInRing((x, z), ring) ||
            !pointInRing((x + r, z), ring) ||
            !pointInRing((x - r, z), ring) ||
            !pointInRing((x, z + r), ring) ||
            !pointInRing((x, z - r), ring)) {
          if (centre) return false;
          continue;
        }
        _details.add((
          type: type,
          x: x,
          y: y,
          z: z,
          sx: sx,
          sy: sy,
          sz: sz,
          rot: rnd() * pi,
        ));
        _count('rooftop ${type.name}');
        return true;
      }
      return false;
    }

    if (glass) {
      if (height > 180 && area > 500) {
        final r = min(11.0, sqrt(area) / 4);
        if (!place(DetailType.helipad, r * 2, 0.4, r * 2, centre: true)) {
          place(
            DetailType.stairHut,
            sqrt(area) * 0.35,
            5,
            sqrt(area) * 0.35,
            centre: true,
          );
        }
      } else {
        place(
          DetailType.stairHut,
          sqrt(area) * 0.35,
          4.5,
          sqrt(area) * 0.3,
          centre: true,
        );
      }
      if (height > 200) place(DetailType.mast, 1.2, 18 + hash * 20, 1.2);
      for (var k = 0; k < 2 + (hash * 3).floor(); k++) {
        place(DetailType.acUnit, 2.4, 1.6, 1.6);
      }
    } else {
      if (area > 150) place(DetailType.stairHut, 3.2, 3, 3.2);
      for (var k = 0; k < 1 + (hash * 2).floor(); k++) {
        place(DetailType.waterTank, 2.6, 3, 2.6);
      }
      for (var k = 0; k < 2 + (hash * 4).floor(); k++) {
        place(DetailType.acUnit, 1.4, 1.0, 0.9);
      }
      // Chongqing rooftops are often gardens.
      if (hash > 0.55) {
        for (var k = 0; k < 2 + (hash * 4).floor(); k++) {
          place(DetailType.plant, 1.6, 1.6, 1.6);
        }
      }
    }
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
      final runPts = [for (final k in run) pts[k]];
      final runHeights = [for (final k in run) heights[k]];
      _ribbon(roads, runPts, runHeights, half, color);
      if (_elevated(tags)) {
        // A real deck: sides and an underside below the road surface.
        _slab(structures, runPts, runHeights, half + 0.3, 1.4, (176, 174, 168));
      }
      _roadRuns.add((
        pts: runPts,
        heights: runHeights,
        half: half,
        bridge: _elevated(tags),
        kind: '${tags['highway']}',
      ));
    }
  }

  void _ribbon(
    MeshLayer out,
    List<P2> pts,
    List<double> heights,
    double half,
    Rgb rgb, {
    bool facingUp = true,
  }) {
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
      if (prevL != null) {
        out.quad(prevL, prevR!, r, l, (0, facingUp ? 1 : -1, 0));
      }
      prevL = l;
      prevR = r;
    }
  }

  // ---- power lines ----

  /// Utility poles with sagging wires along the smaller streets, the
  /// overhead tangle that defines Chongqing's (and many hillside towns')
  /// older neighbourhoods.
  void _powerLines(Mask built) {
    const streets = {
      'residential',
      'unclassified',
      'tertiary',
      'living_street',
      'service',
      'secondary',
    };
    const spacing = 35.0, poleHeight = 9.0;
    for (final r in _roadRuns) {
      if (r.bridge || !streets.contains(r.kind) || r.pts.length < 4) continue;
      // Poles every [spacing] metres on one side of the street.
      final poles = <(V3, double, double)>[]; // top, across-x, across-z
      var since = spacing; // start with a pole
      for (var k = 1; k < r.pts.length - 1; k++) {
        since += sqrt(
          pow(r.pts[k].$1 - r.pts[k - 1].$1, 2) +
              pow(r.pts[k].$2 - r.pts[k - 1].$2, 2),
        );
        if (since < spacing) continue;
        var dx = r.pts[k + 1].$1 - r.pts[k - 1].$1,
            dz = r.pts[k + 1].$2 - r.pts[k - 1].$2;
        final len = sqrt(dx * dx + dz * dz);
        if (len < 1e-6) continue;
        dx /= len;
        dz /= len;
        final nx = -dz, nz = dx; // across the street
        final off = r.half + 1.2;
        final x = r.pts[k].$1 + nx * off, z = r.pts[k].$2 + nz * off;
        if (!_inside(x, z) || built.at(x, z)) {
          poles.add(((double.nan, 0.0, 0.0), 0, 0)); // gap: no wire across
          continue;
        }
        since = 0;
        final g = terrain.heightAt(x, z);
        _details.add((
          type: DetailType.powerPole,
          x: x,
          y: g,
          z: z,
          sx: 1,
          sy: poleHeight,
          sz: 1,
          rot: atan2(-nz, nx), // local +x along the crossarm
        ));
        poles.add(((x, g + poleHeight - 0.4, z), nx, nz));
        _count('power poles');
      }
      for (var i = 1; i < poles.length; i++) {
        final (a, ax, az) = poles[i - 1];
        final (b, bx, bz) = poles[i];
        if (a.$1.isNaN || b.$1.isNaN) continue;
        final dist = sqrt(pow(b.$1 - a.$1, 2) + pow(b.$3 - a.$3, 2));
        if (dist > spacing * 2.2) continue;
        final sag = 0.35 + dist * 0.015;
        void cable(V3 p, V3 q, double sag) => _details.add((
          type: DetailType.wire,
          x: p.$1,
          y: p.$2,
          z: p.$3,
          sx: q.$1 - p.$1,
          sy: q.$2 - p.$2,
          sz: q.$3 - p.$3,
          rot: sag,
        ));
        for (final o in [-0.85, 0.85]) {
          cable(
            (a.$1 + ax * o, a.$2, a.$3 + az * o),
            (b.$1 + bx * o, b.$2, b.$3 + bz * o),
            sag,
          );
        }
        // A lower telecom cable on the pole itself.
        cable((a.$1, a.$2 - 1.6, a.$3), (b.$1, b.$2 - 1.6, b.$3), sag * 1.3);
        _count('wire spans');
      }
    }
  }

  /// Height of the highest road bridge deck within a few metres of (x, z),
  /// or -infinity if there is none.
  double _bridgeDeckNear(double x, double z) {
    // Bridge samples bucketed on a 20 m grid, built on first use.
    final index = _bridgeIndex ??= () {
      final m = <(int, int), List<(double, double, double, double)>>{};
      for (final r in _roadRuns) {
        if (!r.bridge) continue;
        for (var k = 0; k < r.pts.length; k++) {
          final (px, pz) = r.pts[k];
          m.putIfAbsent(((px / 20).floor(), (pz / 20).floor()), () => []).add((
            px,
            pz,
            r.heights[k],
            r.half + 4,
          ));
        }
      }
      return m;
    }();
    var best = double.negativeInfinity;
    final cx = (x / 20).floor(), cz = (z / 20).floor();
    for (var ox = -1; ox <= 1; ox++) {
      for (var oz = -1; oz <= 1; oz++) {
        for (final (px, pz, h, reach)
            in index[(cx + ox, cz + oz)] ??
                const <(double, double, double, double)>[]) {
          final dx = px - x, dz = pz - z;
          if (dx * dx + dz * dz < reach * reach) best = max(best, h);
        }
      }
    }
    return best;
  }

  Map<(int, int), List<(double, double, double, double)>>? _bridgeIndex;

  /// The underside and two sides of a deck whose top surface is drawn
  /// elsewhere: bridges and the monorail beam. Without it a deck is a
  /// one-sided sheet, invisible from below (from the monorail, say).
  void _slab(
    MeshLayer out,
    List<P2> pts,
    List<double> heights,
    double half,
    double depth,
    Rgb rgb,
  ) {
    _ribbon(
      out,
      pts,
      [for (final h in heights) h - depth],
      half,
      rgb,
      facingUp: false,
    );
    for (final side in [-1.0, 1.0]) {
      int? prevTop, prevBottom;
      for (var k = 0; k < pts.length; k++) {
        final a = pts[max(0, k - 1)], b = pts[min(pts.length - 1, k + 1)];
        var dx = b.$1 - a.$1, dz = b.$2 - a.$2;
        final len = sqrt(dx * dx + dz * dz);
        if (len < 1e-6) continue;
        dx /= len;
        dz /= len;
        final x = pts[k].$1 + side * -dz * half,
            z = pts[k].$2 + side * dx * half;
        final t = out.vertex(x, heights[k], z, rgb);
        final bt = out.vertex(x, heights[k] - depth, z, rgb);
        if (prevTop != null) {
          out.quad(prevBottom!, bt, t, prevTop, (side * -dz, 0, side * dx));
        }
        prevTop = t;
        prevBottom = bt;
      }
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
    // Line 2 runs on a viaduct well above street level, and over any road
    // bridge it crosses.
    final raw = [
      for (final (x, z) in pts)
        max(
          max(terrain.heightAt(x, z), riverLevel) + 11,
          _bridgeDeckNear(x, z) + 7,
        ),
    ];
    final heights = List<double>.generate(raw.length, (k) {
      var s = 0.0, n = 0;
      for (var m = max(0, k - 8); m <= min(raw.length - 1, k + 8); m++) {
        s += raw[m];
        n++;
      }
      final ground = max(terrain.heightAt(pts[k].$1, pts[k].$2), riverLevel);
      return max(
        max(s / n, ground + 8),
        _bridgeDeckNear(pts[k].$1, pts[k].$2) + 6,
      );
    });
    const beam = (196, 198, 200);
    // Beam: a 1.6 m wide, 2 m deep box swept along the track.
    _ribbon(out, pts, heights, 0.8, beam);
    _slab(out, pts, heights, 0.8, 2, beam);
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
