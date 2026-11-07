import 'dart:math';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';

/// Things that move along paths: cars on the main roads, people on
/// footpaths, stairs and pavements, and boats on the rivers. Each kind is one instanced mesh per part, so a few draw calls
/// cover all of them.
class _Mover {
  _Mover(this.path, this.s, this.speed, this.dir, this.side);
  RidePath path; // people change paths as the camera moves
  double s, speed, dir;
  final double side; // lateral offset, metres to the right
}

class _Fleet {
  _Fleet(this.movers, this.parts, this.lift);
  final List<_Mover> movers;
  final List<(InstancedMesh, vm.Vector3 offset)> parts;
  final double lift;

  void step(double dt) {
    advance(dt);
    place();
  }

  void advance(double dt) {
    for (final m in movers) {
      m.s += m.speed * m.dir * dt;
      if (m.s > m.path.length || m.s < 0) {
        // Turn around at the end of the road or lane.
        m.s = m.s.clamp(0.0, m.path.length);
        m.dir = -m.dir;
      }
    }
  }

  /// Writes every part's transform from the movers' current positions.
  void place() {
    for (final (mesh, offset) in parts) {
      mesh.updateInstanceTransforms((list) {
        for (var i = 0; i < movers.length; i++) {
          final m = movers[i];
          final (p, fwd) = m.path.sample(m.s);
          final f = fwd * m.dir;
          final right = vm.Vector3(-f.z, 0, f.x);
          final heading = atan2(f.x, f.z);
          final rot = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), heading);
          // Not rot.rotated(): vector_math turns vectors the opposite way to the
          // matrix the mesh is drawn with, which put lights on the car sides.
          final local = rot.asRotationMatrix().transformed(offset);
          list[i].setFromTranslationRotationScale(
            p + right * m.side + vm.Vector3(0, lift, 0) + local,
            rot,
            vm.Vector3.all(1),
          );
        }
      }, recomputeWinding: false);
    }
  }
}

class Movers {
  Movers(CityData city, {int maxCars = 240, int maxPeople = 300}) {
    final rnd = Random(5);
    PhysicallyBasedMaterial mat(double rough) => PhysicallyBasedMaterial()
      ..metallicFactor = 0
      ..roughnessFactor = rough;

    // Cars: a body and a cabin. Chongqing's taxis are yellow.
    final roads = city.traffic.where((p) => p.length > 60).toList();
    if (roads.isNotEmpty) {
      final cars = <_Mover>[];
      final total = roads.fold(0.0, (a, p) => a + p.length);
      for (final road in roads) {
        final n = max(1, (maxCars * road.length / total).round());
        for (var k = 0; k < n; k++) {
          final dir = rnd.nextBool() ? 1.0 : -1.0;
          cars.add(
            _Mover(
              road,
              rnd.nextDouble() * road.length,
              8 + rnd.nextDouble() * 7,
              dir,
              1.9 + rnd.nextDouble() * 1.2,
            ),
          );
        }
      }
      final body = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(1.8, 0.8, 4.4)),
        material: mat(0.35),
      );
      final cabin = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(1.6, 0.6, 2.2)),
        material: mat(0.2),
      );
      const palette = [
        (0.95, 0.78, 0.1), // taxi yellow
        (0.95, 0.95, 0.95),
        (0.7, 0.72, 0.75),
        (0.12, 0.12, 0.14),
        (0.7, 0.1, 0.08),
        (0.15, 0.3, 0.6),
      ];
      for (var i = 0; i < cars.length; i++) {
        final (r, g, b) = rnd.nextDouble() < 0.25
            ? palette[0]
            : palette[1 + rnd.nextInt(palette.length - 1)];
        body.addInstance(vm.Matrix4.identity(), color: vm.Vector4(r, g, b, 1));
        cabin.addInstance(
          vm.Matrix4.identity(),
          color: vm.Vector4(0.2, 0.24, 0.3, 1),
        );
      }
      // Night: two warm headlights in front, red tail lights behind.
      final heads = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(1.6, 0.35, 0.2)),
        material: UnlitMaterial()
          ..baseColorFactor = vm.Vector4(3.0, 2.6, 1.9, 1),
      );
      final tails = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(1.5, 0.3, 0.2)),
        material: UnlitMaterial()
          ..baseColorFactor = vm.Vector4(2.6, 0.12, 0.08, 1),
      );
      for (var i = 0; i < cars.length; i++) {
        heads.addInstance(vm.Matrix4.identity());
        tails.addInstance(vm.Matrix4.identity());
      }
      _carLights = _Fleet(cars, [
        (heads, vm.Vector3(0, 0.05, 2.22)),
        (tails, vm.Vector3(0, 0.1, -2.22)),
      ], 0.4);
      carLightsNode
        ..castsShadows = false
        ..visible = false
        ..add(Node()..addComponent(InstancedMeshComponent(heads)))
        ..add(Node()..addComponent(InstancedMeshComponent(tails)));
      carsNode.add(carLightsNode);
      _cars = _Fleet(cars, [
        (body, vm.Vector3.zero()),
        (cabin, vm.Vector3(0, 0.7, -0.3)),
      ], 0.4);
      carsNode
        ..add(Node()..addComponent(InstancedMeshComponent(body)))
        ..add(Node()..addComponent(InstancedMeshComponent(cabin)));
      root.add(carsNode);
    }

    // People: legs, a shirt and a head, strolling both ways. A fixed crowd
    // that stays near the camera (see [_Crowd]); footpaths, pedestrian
    // streets and stairs draw four times the people pavements do.
    final walks = [
      for (final p in city.walkways)
        if (p.length > 20) (p, 4.0),
      for (final p in city.pavements)
        if (p.length > 20) (p, 1.0),
    ];
    if (walks.isNotEmpty) {
      final people = [
        for (var k = 0; k < maxPeople; k++)
          _Mover(
            walks.first.$1,
            0,
            0.9 + rnd.nextDouble() * 0.7,
            rnd.nextBool() ? 1 : -1,
            (rnd.nextDouble() - 0.5) * 2.8,
          ),
      ];
      const shirts = [
        (0.92, 0.92, 0.9),
        (0.2, 0.2, 0.22),
        (0.75, 0.18, 0.16),
        (0.25, 0.4, 0.7),
        (0.9, 0.75, 0.3),
        (0.55, 0.7, 0.55),
        (0.9, 0.55, 0.6),
      ];
      final parts = <(InstancedMesh, vm.Vector3)>[];
      for (final (size, offset, colour) in [
        (
          vm.Vector3(0.38, 0.85, 0.24),
          vm.Vector3(0, 0.43, 0),
          (int i) => i % 3 == 0
              ? vm.Vector4(0.2, 0.25, 0.4, 1)
              : vm.Vector4(0.14, 0.14, 0.16, 1),
        ),
        (
          vm.Vector3(0.48, 0.66, 0.3),
          vm.Vector3(0, 1.18, 0),
          (int i) {
            final (r, g, b) = shirts[(i * 7 + i ~/ 3) % shirts.length];
            return vm.Vector4(r, g, b, 1);
          },
        ),
        (
          vm.Vector3(0.24, 0.26, 0.24),
          vm.Vector3(0, 1.66, 0),
          (int _) => vm.Vector4(0.82, 0.64, 0.5, 1),
        ),
      ]) {
        final mesh = InstancedMesh(
          geometry: CuboidGeometry(size),
          material: mat(0.7),
        );
        for (var i = 0; i < people.length; i++) {
          mesh.addInstance(vm.Matrix4.identity(), color: colour(i));
        }
        parts.add((mesh, offset));
        peopleNode.add(Node()..addComponent(InstancedMeshComponent(mesh)));
      }
      _people = _Fleet(people, parts, 0);
      _crowd = _Crowd(walks, people, rnd);
      root.add(peopleNode);
    }

    // River traffic, by lane length: Yangtze cruise ships with stacked
    // decks, low cargo barges loaded with sand or containers, and small
    // sightseeing ferries. Each kind is one fleet of instanced parts.
    final lanes = city.boatLanes.where((p) => p.length > 300).toList();
    final cruisers = <_Mover>[], barges = <_Mover>[], ferries = <_Mover>[];
    for (final lane in lanes) {
      final n = max(1, (lane.length / 320).round());
      for (var k = 0; k < n; k++) {
        final pick = rnd.nextDouble();
        final (list, speed) = pick < 0.35
            ? (cruisers, 3 + rnd.nextDouble() * 2)
            : pick < 0.65
            ? (barges, 1.8 + rnd.nextDouble() * 1.2)
            : (ferries, 5 + rnd.nextDouble() * 3);
        list.add(
          _Mover(
            lane,
            (k + rnd.nextDouble() * 0.8) / n * lane.length,
            speed,
            rnd.nextBool() ? 1 : -1,
            (rnd.nextDouble() - 0.5) * 24,
          ),
        );
      }
    }
    final white = vm.Vector4(0.92, 0.92, 0.9, 1);
    _Fleet? fleet(
      List<_Mover> movers,
      List<(vm.Vector3 size, vm.Vector3 offset, vm.Vector4 Function(int))>
      parts,
    ) {
      if (movers.isEmpty) return null;
      final built = <(InstancedMesh, vm.Vector3)>[];
      for (final (size, offset, colour) in parts) {
        final mesh = InstancedMesh(
          geometry: CuboidGeometry(size),
          material: mat(0.4),
        );
        for (var i = 0; i < movers.length; i++) {
          mesh.addInstance(vm.Matrix4.identity(), color: colour(i));
        }
        built.add((mesh, offset));
        root.add(Node()..addComponent(InstancedMeshComponent(mesh)));
      }
      return _Fleet(movers, built, 0.6);
    }

    const trims = [
      (0.75, 0.15, 0.1),
      (0.2, 0.35, 0.65),
      (0.85, 0.62, 0.15),
      (0.15, 0.45, 0.4),
    ];
    vm.Vector4 trim(int i) {
      final (r, g, b) = trims[i % trims.length];
      return vm.Vector4(r, g, b, 1);
    }

    _vessels = [
      fleet(cruisers, [
        (vm.Vector3(9, 2.6, 52), vm.Vector3.zero(), (_) => white),
        (vm.Vector3(8, 2.6, 38), vm.Vector3(0, 2.6, -2), trim),
        (vm.Vector3(7, 2.4, 28), vm.Vector3(0, 5.1, -4), (_) => white),
        (vm.Vector3(5, 2.2, 7), vm.Vector3(0, 7.4, 6), trim),
      ]),
      fleet(barges, [
        (
          vm.Vector3(10, 1.8, 54),
          vm.Vector3.zero(),
          (_) => vm.Vector4(0.24, 0.22, 0.2, 1),
        ),
        (
          vm.Vector3(8, 1.8, 38),
          vm.Vector3(0, 1.6, 3),
          // Sand, gravel or a stack of coloured containers.
          (i) => switch (i % 4) {
            0 => vm.Vector4(0.66, 0.54, 0.36, 1),
            1 => vm.Vector4(0.45, 0.43, 0.4, 1),
            2 => vm.Vector4(0.7, 0.3, 0.18, 1),
            _ => vm.Vector4(0.2, 0.42, 0.6, 1),
          },
        ),
        (vm.Vector3(6, 3.4, 6), vm.Vector3(0, 2.4, -23), (_) => white),
      ]),
      fleet(ferries, [
        (vm.Vector3(5, 1.4, 18), vm.Vector3.zero(), (_) => white),
        (vm.Vector3(4.4, 2, 10), vm.Vector3(0, 1.7, -1), trim),
      ]),
    ].nonNulls.toList();

    // Night: a band of warm deck lights along each cruiser, a lit cabin on
    // each ferry.
    final lamp = UnlitMaterial()
      ..baseColorFactor = vm.Vector4(2.6, 1.6, 0.6, 1);
    _Fleet? lights(List<_Mover> movers, vm.Vector3 size, vm.Vector3 offset) {
      if (movers.isEmpty) return null;
      final mesh = InstancedMesh(
        geometry: CuboidGeometry(size),
        material: lamp,
      );
      for (var i = 0; i < movers.length; i++) {
        mesh.addInstance(vm.Matrix4.identity());
      }
      boatLightsNode.add(Node()..addComponent(InstancedMeshComponent(mesh)));
      return _Fleet(movers, [(mesh, offset)], 0.6);
    }

    _vesselLights = [
      lights(cruisers, vm.Vector3(8.4, 0.5, 38.4), vm.Vector3(0, 2.4, -2)),
      lights(ferries, vm.Vector3(4.6, 0.5, 10.2), vm.Vector3(0, 1.4, -1)),
    ].nonNulls.toList();
    boatLightsNode
      ..castsShadows = false
      ..visible = false;
    root.add(boatLightsNode);
  }

  final Node root = Node(name: 'movers');
  final Node carsNode = Node(name: 'cars');
  final Node carLightsNode = Node(name: 'car lights');
  final Node boatLightsNode = Node(name: 'boat lights');
  final Node peopleNode = Node(name: 'people');
  _Fleet? _people;
  _Crowd? _crowd;
  _Fleet? _cars, _carLights;
  List<_Fleet> _vessels = const [], _vesselLights = const [];

  /// Cars and people only draw and move when [showCars] (the camera is
  /// close), people only where there are walkways near [eye]; car lights and the boats' deck lights show at [night].
  void update(
    double dt,
    vm.Vector3 eye, {
    required bool showCars,
    required bool night,
  }) {
    for (final f in _vessels) {
      f.step(dt);
    }
    if (boatLightsNode.visible != night) boatLightsNode.visible = night;
    if (night) {
      for (final f in _vesselLights) {
        f.place();
      }
    }
    if (carsNode.visible != showCars) carsNode.visible = showCars;
    final crowd = showCars && (_crowd?.gather(eye, dt) ?? false);
    if (peopleNode.visible != crowd) peopleNode.visible = crowd;
    if (crowd) _people!.step(dt);
    if (carLightsNode.visible != night) carLightsNode.visible = night;
    if (showCars) {
      _cars?.step(dt);
      if (night) _carLights?.place();
    }
  }
}

/// Keeps a fixed number of people on the walkways around the camera: anyone
/// who ends up farther than [radius] from the eye is moved to a random spot
/// on a nearby walkway (busier paths more likely). Streets look lived-in
/// wherever the camera is, at the cost of a few hundred figures.
class _Crowd {
  _Crowd(List<(RidePath, double)> walks, this.people, this.rnd)
    : walks = [
        for (final (p, weight) in walks)
          (
            path: p,
            weight: weight * p.length,
            box: vm.Aabb2.minMax(
              vm.Vector2(
                p.points.map((v) => v.x).reduce(min),
                p.points.map((v) => v.z).reduce(min),
              ),
              vm.Vector2(
                p.points.map((v) => v.x).reduce(max),
                p.points.map((v) => v.z).reduce(max),
              ),
            ),
          ),
      ];

  static const radius = 220.0;
  final List<({RidePath path, double weight, vm.Aabb2 box})> walks;
  final List<_Mover> people;
  final Random rnd;
  List<({RidePath path, double weight, vm.Aabb2 box})> _near = const [];
  double _total = 0, _since = 1e9;
  final vm.Vector3 _last = vm.Vector3.all(1e9);

  /// Refreshes who is near [eye]; false when no walkway is in range.
  bool gather(vm.Vector3 eye, double dt) {
    _since += dt;
    if (_since < 0.5) return _near.isNotEmpty;
    _since = 0;
    if ((eye - _last).length2 > 20 * 20) {
      _last.setFrom(eye);
      _near = [
        for (final w in walks)
          if (_distance(w.box, eye) < radius) w,
      ];
      _total = _near.fold(0.0, (a, w) => a + w.weight);
    }
    if (_near.isEmpty) return false;
    for (final m in people) {
      final (p, _) = m.path.sample(m.s);
      final dx = p.x - eye.x, dz = p.z - eye.z;
      if (dx * dx + dz * dz < radius * radius &&
          _near.any((w) => w.path == m.path)) {
        continue;
      }
      var pick = rnd.nextDouble() * _total;
      for (final w in _near) {
        pick -= w.weight;
        if (pick <= 0) {
          m.path = w.path;
          break;
        }
      }
      m.s = rnd.nextDouble() * m.path.length;
    }
    return true;
  }

  static double _distance(vm.Aabb2 box, vm.Vector3 eye) {
    final dx = max(0.0, max(box.min.x - eye.x, eye.x - box.max.x));
    final dz = max(0.0, max(box.min.y - eye.z, eye.z - box.max.y));
    return sqrt(dx * dx + dz * dz);
  }
}
