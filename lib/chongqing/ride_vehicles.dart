import 'dart:math';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';

/// The vehicles that run along one ride path: two cable car cabins passing
/// each other on the cableway, or two monorail trains on Line 2. The ride
/// camera rides the first vehicle.
class RideVehicles {
  RideVehicles(this.path, Node parent) {
    final monorail = path.kind == 'monorail';
    speed = monorail ? 14 : 6; // m/s
    PhysicallyBasedMaterial mat(vm.Vector4 c, double rough) =>
        PhysicallyBasedMaterial()
          ..baseColorFactor = c
          ..metallicFactor = 0
          ..roughnessFactor = rough;

    if (monorail) {
      // Straddle-beam trains: four cars each, white with a red band.
      final body = Mesh(
        CuboidGeometry(vm.Vector3(2.9, 3.2, _carLength)),
        mat(vm.Vector4(0.92, 0.93, 0.95, 1), 0.35),
      );
      final band = Mesh(
        CuboidGeometry(vm.Vector3(2.95, 0.5, _carLength - 0.2)),
        mat(vm.Vector4(0.75, 0.1, 0.08, 1), 0.4),
      );
      for (var v = 0; v < 2; v++) {
        final cars = <Node>[];
        for (var c = 0; c < 4; c++) {
          final car = Node(name: 'train $v car $c', mesh: body)
            ..add(Node(mesh: band)..position = vm.Vector3(0, -0.6, 0));
          cars.add(car);
          parent.add(car);
        }
        _vehicles.add(
          _Vehicle(cars, v == 0 ? 0.0 : path.length, v == 0 ? 1.0 : -1.0),
        );
      }
    } else {
      final cabin = Mesh(
        CuboidGeometry(vm.Vector3(3.2, 2.8, 4.2)),
        mat(vm.Vector4(0.75, 0.08, 0.06, 1), 0.4),
      );
      for (var v = 0; v < 2; v++) {
        final node = Node(name: 'cabin $v', mesh: cabin);
        parent.add(node);
        _vehicles.add(
          _Vehicle([node], v == 0 ? 0.0 : path.length, v == 0 ? 1.0 : -1.0),
        );
      }
    }
  }

  final RidePath path;
  late final double speed;
  final List<_Vehicle> _vehicles = [];

  static const double _carLength = 14;

  /// How far above the path a vehicle's centre sits: trains straddle the
  /// beam (the path is the beam top), cabins hang below the cable.
  double get _lift => path.kind == 'monorail' ? 0.9 : 0;

  void update(double dt) {
    for (final v in _vehicles) {
      v.s += v.dir * speed * dt;
      if (v.s > path.length || v.s < 0) {
        v.s = v.s.clamp(0.0, path.length);
        v.dir = -v.dir; // turn back at the end of the line
      }
      for (var c = 0; c < v.parts.length; c++) {
        // Cars trail the lead car along the track.
        final s = v.s - v.dir * c * (_carLength + 1);
        final (p, fwd) = path.sample(s);
        final f = fwd * v.dir;
        v.parts[c].globalTransform = vm.Matrix4.compose(
          p + vm.Vector3(0, _lift, 0),
          vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), atan2(f.x, f.z)),
          vm.Vector3.all(1),
        );
      }
    }
  }

  /// Camera eye and look direction for a rider in the first vehicle, with
  /// [yaw] / [pitch] from dragging.
  (vm.Vector3, vm.Vector3) riderView(double yaw, double pitch) {
    final v = _vehicles.first;
    final (p, fwd) = path.sample(v.s);
    final heading = atan2(fwd.x * v.dir, fwd.z * v.dir);
    final ahead = vm.Vector3(sin(heading), 0, cos(heading));
    final eye =
        p +
        vm.Vector3(0, path.kind == 'monorail' ? 2.6 : 0.6, 0) +
        ahead * (path.kind == 'monorail' ? _carLength / 2 + 0.5 : 1.4);
    final h = heading + yaw;
    final look = vm.Vector3(
      sin(h) * cos(pitch),
      sin(pitch),
      cos(h) * cos(pitch),
    );
    return (eye, look);
  }
}

class _Vehicle {
  _Vehicle(this.parts, this.s, this.dir);
  final List<Node> parts;
  double s;
  double dir;
}
