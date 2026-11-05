import 'dart:typed_data';
import 'dart:math';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';

/// Small details (rooftop items, later trees and props) split into square
/// map tiles. Each tile is one node holding one instanced mesh per item
/// type, and a tile only draws when the camera is near it, so detail appears
/// as you zoom in instead of being paid for everywhere at once.
class DetailChunks {
  DetailChunks(
    List<Detail> details, {
    this.tileSize = 200,
    this.showWithin = 650,
    this.castsShadows = true,
  }) {
    final tiles = <(int, int), Map<String, List<Detail>>>{};
    for (final d in details) {
      final key = (
        (d.position.x / tileSize).floor(),
        (d.position.z / tileSize).floor(),
      );
      tiles.putIfAbsent(key, () => {}).putIfAbsent(d.type, () => []).add(d);
    }
    for (final MapEntry(key: (tx, tz), value: byType) in tiles.entries) {
      final tile = Node(name: 'detail tile $tx,$tz');
      var y = 0.0, n = 0;
      byType.forEach((type, items) {
        final parts = _styles[type];
        if (parts == null) return;
        for (final part in parts) {
          final mesh = InstancedMesh(
            geometry: part.geometry,
            material: part.material,
          );
          for (final d in items) {
            mesh.addInstance(transformFor(type, part, d));
          }
          tile.add(
            Node(name: type)
              ..castsShadows = castsShadows
              ..addComponent(InstancedMeshComponent(mesh)),
          );
        }
        for (final d in items) {
          y += d.position.y;
          n++;
        }
      });
      tile.visible = false;
      root.add(tile);
      _items.add((tile, byType));
      _tiles.add((
        tile,
        vm.Vector3(
          (tx + 0.5) * tileSize,
          n == 0 ? 0 : y / n,
          (tz + 0.5) * tileSize,
        ),
      ));
    }
  }

  final double tileSize;

  final List<(Node, Map<String, List<Detail>>)> _items = [];
  final List<Node> _realistic = [], _painted = [];
  bool _paintedBuilt = false;

  /// Switches every item between its realistic and painted material.
  /// Painted copies are built the first time they're needed (same
  /// geometry and transforms, painted materials from [paintedFor]).
  void setPainted(bool painted, Material Function(Material) paintedFor) {
    if (painted && !_paintedBuilt) {
      _paintedBuilt = true;
      for (final (tile, byType) in _items) {
        for (final child in tile.children.toList()) {
          _realistic.add(child);
        }
        byType.forEach((type, items) {
          for (final part in _styles[type] ?? const []) {
            final node = _partNode(
              type,
              part,
              items,
              paintedFor(part.material),
            );
            _painted.add(node);
            tile.add(node);
          }
        });
      }
    }
    for (final n in _realistic) {
      n.visible = !painted;
    }
    for (final n in _painted) {
      n.visible = painted;
    }
  }

  /// A part's transform for one item. Wires are special: position is one
  /// end, size is the vector to the other end and rotation is the sag, so
  /// one shared unit strip stretches exactly between two poles.
  static vm.Matrix4 transformFor(
    String type,
    ({
      Geometry geometry,
      Material material,
      vm.Vector3 scale,
      double lift,
      double side,
    })
    part,
    Detail d,
  ) {
    if (type == 'wire') {
      final dx = d.size.x, dz = d.size.z;
      final len = sqrt(dx * dx + dz * dz);
      final wx = len < 1e-6 ? 1.0 : -dz / len, wz = len < 1e-6 ? 0.0 : dx / len;
      // Columns: tilted width axis, sag (down), span; translation = start.
      return vm.Matrix4(
        wx * 0.707,
        0.707,
        wz * 0.707,
        0, //
        0,
        d.rotation,
        0,
        0,
        dx,
        d.size.y,
        dz,
        0,
        d.position.x,
        d.position.y,
        d.position.z,
        1,
      );
    }
    final size = vm.Vector3(
      d.size.x * part.scale.x,
      d.size.y * part.scale.y,
      d.size.z * part.scale.z,
    );
    final rot = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), d.rotation);
    return vm.Matrix4.compose(
      d.position +
          vm.Vector3(0, d.size.y * part.lift, 0) +
          rot.rotated(vm.Vector3(part.side, 0, 0)),
      rot,
      size,
    );
  }

  Node _partNode(
    String type,
    ({
      Geometry geometry,
      Material material,
      vm.Vector3 scale,
      double lift,
      double side,
    })
    part,
    List<Detail> items,
    Material material,
  ) {
    final mesh = InstancedMesh(geometry: part.geometry, material: material);
    for (final d in items) {
      mesh.addInstance(transformFor(type, part, d));
    }
    return Node(name: type)
      ..castsShadows = castsShadows
      ..addComponent(InstancedMeshComponent(mesh));
  }

  /// Tiles whose centre is within this distance of the camera are drawn.
  double showWithin;

  /// Whether these items cast shadows. Each shadow cascade re-draws every
  /// casting tile, so small clutter skips it.
  bool castsShadows;

  /// Turns shadow casting on or off for every tile.
  void setCastsShadows(bool value) {
    if (value == castsShadows) return;
    castsShadows = value;
    for (final (tile, _) in _tiles) {
      for (final child in tile.children) {
        child.castsShadows = value;
      }
    }
  }

  final Node root = Node(name: 'details');
  final List<(Node, vm.Vector3)> _tiles = [];

  void update(vm.Vector3 camera) {
    final limit2 = pow(showWithin, 2);
    for (final (tile, centre) in _tiles) {
      final show = camera.distanceToSquared(centre) < limit2;
      if (tile.visible != show) tile.visible = show;
    }
  }

  static PhysicallyBasedMaterial _mat(
    double r,
    double g,
    double b, {
    double rough = 0.7,
  }) => PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(r, g, b, 1)
    ..metallicFactor = 0
    ..roughnessFactor = rough;

  static ({
    Geometry geometry,
    Material material,
    vm.Vector3 scale,
    double lift,
    double side,
  })
  _part(
    Geometry g,
    Material m, {
    double sx = 1,
    double sy = 1,
    double sz = 1,
    double? lift,
    double side = 0, // metres along the item's local +x
  }) => (
    geometry: g,
    material: m,
    scale: vm.Vector3(sx, sy, sz),
    lift: lift ?? sy / 2,
    side: side,
  );

  static final Geometry _box = CuboidGeometry(vm.Vector3.all(1));
  static final Geometry _cylinder = CylinderGeometry(
    bottomRadius: 0.5,
    topRadius: 0.5,
    height: 1,
    radialSegments: 10,
  );
  static final Geometry _blob = IcosphereGeometry(radius: 0.5, subdivisions: 1);
  static final Geometry _cone = CylinderGeometry(
    bottomRadius: 0.5,
    topRadius: 0.08,
    height: 1,
    radialSegments: 8,
  );
  static final Material _bark = _mat(0.36, 0.26, 0.18, rough: 0.9);

  /// A tree: trunk up to [trunkTop] of the height, canopy above it.
  static List<
    ({
      Geometry geometry,
      Material material,
      vm.Vector3 scale,
      double lift,
      double side,
    })
  >
  _tree(Geometry canopy, Material leaves, {double trunkTop = 0.45}) => [
    _part(_cylinder, _bark, sx: 0.1, sy: trunkTop + 0.1, sz: 0.1),
    _part(
      canopy,
      leaves,
      sy: 1 - trunkTop + 0.1,
      lift: trunkTop + (1 - trunkTop) / 2,
    ),
  ];

  /// A unit sagging strip: from z = 0 to z = 1, dipping to y = -1 at the
  /// middle (a parabola, close to a hanging cable), 0.1 wide along x.
  static final Geometry _wireStrip = () {
    const segments = 6;
    final positions = <double>[];
    final indices = <int>[];
    for (var i = 0; i <= segments; i++) {
      final t = i / segments;
      final v = -4 * t * (1 - t);
      positions.addAll([-0.05, v, t, 0.05, v, t]);
      if (i > 0) {
        final a = (i - 1) * 2, b = a + 1, c = a + 3, d = a + 2;
        indices.addAll([a, b, c, a, c, d]);
      }
    }
    return MeshGeometry.fromArrays(
      positions: Float32List.fromList(positions),
      indices: indices,
    );
  }();

  // Unit-sized shapes; each instance is scaled to its item's size.
  static final Map<
    String,
    List<
      ({
        Geometry geometry,
        Material material,
        vm.Vector3 scale,
        double lift,
        double side,
      })
    >
  >
  _styles = {
    'waterTank': [_part(_cylinder, _mat(0.62, 0.72, 0.82, rough: 0.35))],
    'acUnit': [_part(_box, _mat(0.86, 0.87, 0.86))],
    'stairHut': [_part(_box, _mat(0.78, 0.76, 0.72))],
    'plant': [_part(_blob, _mat(0.24, 0.48, 0.18, rough: 0.9))],
    'helipad': [
      _part(
        CylinderGeometry(
          bottomRadius: 0.5,
          topRadius: 0.5,
          height: 1,
          radialSegments: 24,
        ),
        _mat(0.22, 0.32, 0.28),
      ),
    ],
    // Utility pole (9 m) with a 2 m crossarm across the street.
    'powerPole': [
      _part(_box, _mat(0.36, 0.34, 0.32, rough: 0.8), sx: 0.26, sz: 0.26),
      _part(
        _box,
        _mat(0.36, 0.34, 0.32, rough: 0.8),
        sx: 2.0,
        sy: 0.016,
        sz: 0.14,
        lift: 0.946,
      ),
    ],
    'wire': [
      _part(_wireStrip, _mat(0.07, 0.07, 0.08, rough: 0.6)..doubleSided = true),
    ],
    'mast': [_part(_box, _mat(0.82, 0.2, 0.18, rough: 0.5))],
    // Huangge (Ficus virens), Chongqing's city tree: wide, low, dark canopy.
    'treeHuangge': _tree(
      _blob,
      _mat(0.13, 0.3, 0.1, rough: 0.85),
      trunkTop: 0.35,
    ),
    // Camphor: rounder, denser, mid green.
    'treeCamphor': _tree(_blob, _mat(0.22, 0.42, 0.14, rough: 0.85)),
    // Chinese banyan: broad and glossy.
    'treeBanyan': _tree(
      _blob,
      _mat(0.1, 0.26, 0.09, rough: 0.6),
      trunkTop: 0.3,
    ),
    // Ginkgo: narrow, light yellow-green.
    'treeGinkgo': _tree(
      _cone,
      _mat(0.5, 0.58, 0.16, rough: 0.85),
      trunkTop: 0.2,
    ),
    'shrub': [_part(_blob, _mat(0.2, 0.38, 0.13, rough: 0.9))],
    // Bougainvillea spills over railings in low, flat clumps of deep pink,
    // not big balls.
    // Long, low planter boxes along bridge railings: concrete trough with a
    // hedge on top.
    'planter': [
      _part(_box, _mat(0.66, 0.64, 0.6), sy: 0.45),
      _part(
        _box,
        _mat(0.18, 0.34, 0.13, rough: 0.9),
        sx: 0.85,
        sy: 0.55,
        sz: 0.95,
        lift: 0.7,
      ),
    ],
    // Street lamp: an 8 m pole with an arm reaching over the road. The
    // glowing head at the arm's tip is drawn by StreetLamps (night only).
    'streetLamp': [
      _part(
        _cylinder,
        _mat(0.3, 0.31, 0.33, rough: 0.5),
        sx: 0.24,
        sy: 8,
        sz: 0.24,
      ),
      _part(
        _box,
        _mat(0.3, 0.31, 0.33, rough: 0.5),
        sx: 2.2,
        sy: 0.16,
        sz: 0.16,
        lift: 7.9,
        side: 1.1,
      ),
    ],
  };
}
