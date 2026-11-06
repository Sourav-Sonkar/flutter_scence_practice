import 'dart:math';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';

/// Vehicles that move along paths: cars on the main roads and boats on the
/// rivers. Each kind is one instanced mesh per part, so a few draw calls
/// cover all of them.
class _Mover {
  _Mover(this.path, this.s, this.speed, this.dir, this.side);
  final RidePath path;
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
  Movers(CityData city, {int maxCars = 240}) {
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

    // Boats: river cruisers with a white hull and a coloured deckhouse.
    final lanes = city.boatLanes.where((p) => p.length > 300).toList();
    if (lanes.isNotEmpty) {
      final boats = <_Mover>[];
      for (final lane in lanes) {
        for (var k = 0; k < 2; k++) {
          boats.add(
            _Mover(
              lane,
              rnd.nextDouble() * lane.length,
              3 + rnd.nextDouble() * 3,
              rnd.nextBool() ? 1 : -1,
              0,
            ),
          );
        }
      }
      final hull = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(7, 2.4, 30)),
        material: mat(0.4),
      );
      final house = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(6, 3.5, 14)),
        material: mat(0.4),
      );
      for (var i = 0; i < boats.length; i++) {
        hull.addInstance(
          vm.Matrix4.identity(),
          color: vm.Vector4(0.92, 0.92, 0.9, 1),
        );
        final red = i.isEven;
        house.addInstance(
          vm.Matrix4.identity(),
          color: red
              ? vm.Vector4(0.75, 0.15, 0.1, 1)
              : vm.Vector4(0.2, 0.35, 0.65, 1),
        );
      }
      // Night: a band of warm deck lights along each cruiser.
      final deck = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(7.4, 0.4, 30.4)),
        material: UnlitMaterial()
          ..baseColorFactor = vm.Vector4(2.6, 1.6, 0.6, 1),
      );
      for (var i = 0; i < boats.length; i++) {
        deck.addInstance(vm.Matrix4.identity());
      }
      _boatLights = _Fleet(boats, [(deck, vm.Vector3(0, 1.0, 0))], 0.6);
      boatLightsNode
        ..castsShadows = false
        ..visible = false
        ..add(Node()..addComponent(InstancedMeshComponent(deck)));
      root.add(boatLightsNode);
      _boats = _Fleet(boats, [
        (hull, vm.Vector3.zero()),
        (house, vm.Vector3(0, 2.8, -2)),
      ], 0.6);
      root
        ..add(Node()..addComponent(InstancedMeshComponent(hull)))
        ..add(Node()..addComponent(InstancedMeshComponent(house)));
    }
  }

  final Node root = Node(name: 'movers');
  final Node carsNode = Node(name: 'cars');
  final Node carLightsNode = Node(name: 'car lights');
  final Node boatLightsNode = Node(name: 'boat lights');
  _Fleet? _cars, _carLights;
  _Fleet? _boats, _boatLights;

  /// Cars only draw and move when [showCars] (the camera is close); their
  /// lights and the boats' deck lights show at [night].
  void update(double dt, {required bool showCars, required bool night}) {
    _boats?.step(dt);
    if (boatLightsNode.visible != night) boatLightsNode.visible = night;
    if (night) _boatLights?.place();
    if (carsNode.visible != showCars) carsNode.visible = showCars;
    if (carLightsNode.visible != night) carLightsNode.visible = night;
    if (showCars) {
      _cars?.step(dt);
      if (night) _carLights?.place();
    }
  }
}
