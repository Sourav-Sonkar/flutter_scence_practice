import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';
import 'city_look.dart';
import 'crowns.dart';
import 'detail_chunks.dart';
import 'grass.dart';
import 'movers.dart';
import 'ride_vehicles.dart';
import 'street_lamps.dart';
import 'tree_shade.dart';

/// Everything that belongs to one loaded district, under one node so the
/// whole district can be shown or hidden at once: geometry tiles, detail
/// tiles (trees, rooftops, lamp poles), lamp heads, LED crowns, traffic,
/// boats and ride vehicles.
class DistrictScene {
  DistrictScene(
    this.name,
    CityData data,
    Map<String, Material> materials, {
    GrassModels? grass,
  }) {
    root = Node(name: 'district $name');
    for (final tile in data.layers) {
      if (tile.kind == 'lamplight') continue; // drawn by the street lamps
      final node =
          Node(
              name: '$name/${tile.kind}',
              mesh: Mesh(tile.geometry, materials[tile.kind]!),
            )
            // Ground and roads are flat or gentle: casting shadows from them
            // barely shows but costs a full re-draw per shadow cascade.
            ..castsShadows = tile.kind != 'terrain' && tile.kind != 'roads'
            // The city never moves, so its shadow maps can be cached and only
            // redrawn when the sun does.
            ..shadowStatic = true;
      // Tiles are frustum culled by the engine (off-screen tiles are
      // skipped); roads and small structures are also dropped far away.
      if (tile.kind == 'roads' || tile.kind == 'structures') {
        _farHidden.add((node, tile.bounds));
      }
      _tiles.add((node, tile.kind, tile.geometry));
      root.add(node);
    }

    vegetation = DetailChunks(
      data.details.where((d) => _plants.contains(d.type)).toList(),
      tileSize: 600,
      showWithin: 2400,
    );
    rooftops = DetailChunks(
      data.details
          .where((d) => !_plants.contains(d.type) && d.type != 'crown')
          .toList(),
      tileSize: 400,
      castsShadows: false, // too small to matter, costly per cascade
    );
    crowns = LedCrowns(data.details.where((d) => d.type == 'crown').toList());
    lamps = StreetLamps(
      data.details.where((d) => d.type == 'streetLamp').toList(),
      [
        for (final tile in data.layers)
          if (tile.kind == 'lamplight') tile.geometry,
      ],
    );
    treeShade = TreeShade(data, root);
    if (grass != null) {
      this.grass = GrassField(data, grass);
      root.add(this.grass!.root);
    }
    movers = Movers(data);
    final ridesNode = Node(name: '$name rides');
    for (final ride in data.rides) {
      rides.add(RideVehicles(ride, ridesNode));
    }
    root
      ..add(vegetation.root)
      ..add(rooftops.root)
      ..add(crowns.root)
      ..add(lamps.root)
      ..add(movers.root)
      ..add(ridesNode);
  }

  /// Details shown at long range: trees carry the green look, and lamp
  /// poles must reach as far as their glowing heads.
  static const _plants = {
    'treeHuangge',
    'treeCamphor',
    'treeBanyan',
    'treeGinkgo',
    'shrub',
    'planter',
    'streetLamp',
    'powerPole',
    'wire',
  };

  /// Beyond this distance roads and small structures (piers, rails) are a
  /// pixel wide at most, so they are not drawn.
  static const double farDistance = 2500;

  final String name;
  late final Node root;
  late final DetailChunks vegetation, rooftops;
  late final LedCrowns crowns;
  late final StreetLamps lamps;
  late final Movers movers;
  GrassField? grass;
  late final TreeShade treeShade;
  final List<RideVehicles> rides = [];
  final List<(Node, vm.Aabb3)> _farHidden = [];
  final List<(Node, String, Geometry)> _tiles = [];

  /// Re-skins every geometry tile with [materials] (realistic or painted),
  /// keyed by layer kind.
  void setMaterials(Map<String, Material> materials) {
    for (final (node, kind, geometry) in _tiles) {
      node.mesh = Mesh(geometry, materials[kind]!);
    }
  }

  /// Switches trees, rooftop details and lamp poles between realistic and
  /// painted materials.
  void setPaintedDetails(bool painted, Material Function(Material) paintedFor) {
    vegetation.setPainted(painted, paintedFor);
    rooftops.setPainted(painted, paintedFor);
  }

  bool get visible => root.visible;
  set visible(bool v) {
    if (root.visible != v) root.visible = v;
  }

  void setQuality(Quality q) {
    vegetation
      ..showWithin = q == Quality.low ? 1300 : 2400
      // Tree shadows look great but every cascade re-draws every tree.
      ..setCastsShadows(q == Quality.high);
  }

  void update(
    double dt,
    vm.Vector3 eye, {
    required double time,
    required double night,
    required bool showCars,
    required vm.Vector3 sun,
  }) {
    for (final r in rides) {
      r.update(dt);
    }
    if (!visible) return;
    final far2 = farDistance * farDistance;
    for (final (node, box) in _farHidden) {
      final dx = eye.x.clamp(box.min.x, box.max.x) - eye.x;
      final dz = eye.z.clamp(box.min.z, box.max.z) - eye.z;
      final show = dx * dx + dz * dz < far2;
      if (node.visible != show) node.visible = show;
    }
    movers.update(dt, eye, showCars: showCars, night: night > 0.5);
    lamps.update(time, night);
    crowns.update(time, night);
    vegetation.update(eye);
    treeShade.update(sun);
    grass?.update(eye, near: showCars);
    rooftops.update(eye);
  }
}
