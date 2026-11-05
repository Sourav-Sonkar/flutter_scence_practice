import 'dart:math';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'walk_world.dart';

/// A person exploring the city on foot, built from simple shapes (no model
/// files): legs, torso, arms and head, with a walk cycle that follows the
/// distance covered so feet don't slide.
class Walker {
  Walker() {
    PhysicallyBasedMaterial mat(
      double r,
      double g,
      double b, [
      double rough = 0.7,
    ]) => PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(r, g, b, 1)
      ..metallicFactor = 0
      ..roughnessFactor = rough;
    final jacket = mat(0.78, 0.16, 0.12, 0.6); // red, easy to spot from above
    final jeans = mat(0.16, 0.22, 0.36);
    final skin = mat(0.85, 0.66, 0.52);
    final hair = mat(0.08, 0.06, 0.05, 0.5);
    final shoes = mat(0.92, 0.92, 0.9);

    final limb = CapsuleGeometry(
      radius: 0.07,
      height: 0.62,
      radialSegments: 10,
      capRings: 3,
    );
    final arm = CapsuleGeometry(
      radius: 0.055,
      height: 0.5,
      radialSegments: 10,
      capRings: 3,
    );

    Node leg(double side) => Node(name: 'hip $side')
      ..position = vm.Vector3(0.11 * side, 0.92, 0)
      ..add(Node(mesh: Mesh(limb, jeans))..position = vm.Vector3(0, -0.42, 0))
      ..add(
        Node(mesh: Mesh(CuboidGeometry(vm.Vector3(0.12, 0.08, 0.26)), shoes))
          ..position = vm.Vector3(0, -0.86, 0.04),
      );
    Node armNode(double side) => Node(name: 'shoulder $side')
      ..position = vm.Vector3(0.24 * side, 1.42, 0)
      ..add(Node(mesh: Mesh(arm, jacket))..position = vm.Vector3(0, -0.3, 0))
      ..add(
        Node(
          mesh: Mesh(
            SphereGeometry(radius: 0.055, segments: 10, rings: 6),
            skin,
          ),
        )..position = vm.Vector3(0, -0.62, 0),
      );

    _legL = leg(-1);
    _legR = leg(1);
    _armL = armNode(-1);
    _armR = armNode(1);
    _body = Node(name: 'body')
      ..add(_legL)
      ..add(_legR)
      ..add(
        Node(mesh: Mesh(CuboidGeometry(vm.Vector3(0.42, 0.56, 0.24)), jacket))
          ..position = vm.Vector3(0, 1.2, 0),
      )
      ..add(_armL)
      ..add(_armR)
      ..add(
        Node(
          mesh: Mesh(
            SphereGeometry(radius: 0.12, segments: 16, rings: 10),
            skin,
          ),
        )..position = vm.Vector3(0, 1.64, 0),
      )
      ..add(
        Node(
            mesh: Mesh(
              SphereGeometry(radius: 0.125, segments: 16, rings: 10),
              hair,
            ),
          )
          ..position = vm.Vector3(0, 1.69, -0.02)
          ..scale = vm.Vector3(1, 0.75, 1),
      );
    root.add(_body);
  }

  final Node root = Node(name: 'walker');
  late final Node _body, _legL, _legR, _armL, _armR;

  final vm.Vector3 position = vm.Vector3.zero();
  double heading = 0; // radians, 0 = facing +z
  double _stride = 0; // walk-cycle phase
  double _speed = 0;

  static const double radius = 0.35;
  static const double walkSpeed = 2.2,
      runSpeed = 7.0; // m/s (a brisk miniature pace)

  /// Puts the walker on the ground near (x, z), outside any building.
  void spawn(WalkWorld world, double x, double z) {
    position.setValues(x, 1e4, z);
    for (var i = 0; i < 40; i++) {
      final g = world.groundAt(position.x, position.z, 1e4);
      if (g != null) position.y = g;
      final before = vm.Vector3.copy(position);
      world.resolveWalls(position, radius);
      if ((position - before).length < 0.01 && g != null && !world.isWater(g)) {
        break;
      }
      if (g == null || world.isWater(g)) {
        // Step toward the city centre until on dry land.
        position.x *= 0.9;
        position.z *= 0.9;
      }
    }
    position.y = world.groundAt(position.x, position.z, 1e4) ?? 0;
    _place();
  }

  /// Moves by [input] (x = right, y = forward, length 0..1) relative to the
  /// camera's [forward] / [right] directions.
  void update(
    double dt,
    WalkWorld world,
    vm.Vector2 input,
    vm.Vector3 forward,
    vm.Vector3 right, {
    required bool run,
  }) {
    final amount = min(1.0, input.length);
    final target = amount * (run ? runSpeed : walkSpeed);
    // Ease speed so starts and stops aren't instant.
    _speed += (target - _speed) * min(1.0, dt * 10);
    if (amount > 0.05) {
      final dir = (forward * input.y + right * input.x)..y = 0;
      if (dir.length2 > 1e-6) {
        dir.normalize();
        final want = atan2(dir.x, dir.z);
        var diff = want - heading;
        while (diff > pi) {
          diff -= 2 * pi;
        }
        while (diff < -pi) {
          diff += 2 * pi;
        }
        heading += diff * min(1.0, dt * 12);
        final step = dir * (_speed * dt);
        final next = position + step;
        final ground = world.groundAt(next.x, next.z, position.y);
        // Stop at the city's edge, the water, and slopes too steep to climb
        // (more than 1.2 m up in one step means a wall or cliff).
        if (ground != null &&
            !world.isWater(ground) &&
            ground - position.y < max(1.2, step.length * 1.2)) {
          next.y = ground;
          world.resolveWalls(next, radius);
          final settled = world.groundAt(next.x, next.z, position.y);
          if (settled != null && !world.isWater(settled)) {
            next.y = settled;
            position.setFrom(next);
          }
        }
        _stride += step.length * (run ? 2.4 : 3.2);
      }
    }
    _place();
  }

  void _place() {
    root.globalTransform = vm.Matrix4.compose(
      position,
      vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), heading),
      vm.Vector3.all(1),
    );
    final moving = (_speed / walkSpeed).clamp(0.0, 1.6);
    final swing = sin(_stride) * 0.55 * min(1.0, moving);
    vm.Quaternion pitch(double a) =>
        vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), a);
    _legL.rotation = pitch(swing);
    _legR.rotation = pitch(-swing);
    _armL.rotation = pitch(-swing * 0.8);
    _armR.rotation = pitch(swing * 0.8);
    // A little bob and forward lean when running.
    _body.position = vm.Vector3(
      0,
      (sin(_stride * 2).abs() * 0.04) * min(1.0, moving),
      0,
    );
    _body.rotation = pitch(0.12 * max(0.0, moving - 1));
  }
}
