import 'dart:math';

import 'package:vector_math/vector_math.dart' as vm;

import 'walk_world.dart';

/// A free-flying camera drone. It keeps clear of the ground, slides around
/// buildings when lower than their roofs (it can fly over them), and has a
/// little inertia so flight feels smooth rather than snappy.
class Drone {
  final vm.Vector3 position = vm.Vector3.zero();
  final vm.Vector3 _velocity = vm.Vector3.zero();
  double yaw = 0; // radians, 0 = facing +z
  double pitch = -0.25; // radians, negative looks down
  double _climb = 0;

  static const double radius = 3; // clearance around the drone, metres
  // Above the tallest trees and lamp posts (~16 m), so nothing clips.
  static const double minClearance = 18; // above ground, metres
  static const double maxAltitude = 1500; // above the river, metres

  vm.Vector3 get forward =>
      vm.Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch));

  /// Starts at [eye] looking along [look].
  void place(vm.Vector3 eye, vm.Vector3 look) {
    position.setFrom(eye);
    _velocity.setZero();
    _climb = 0;
    yaw = atan2(look.x, look.z);
    pitch = asin(look.normalized().y.clamp(-0.99, 0.99));
  }

  /// [move]: x = strafe right, y = forward (each -1..1, horizontal only, so
  /// looking down doesn't fly you into the ground). [lift]: -1..1 down/up.
  /// [turn]: radians/s of yaw from a stick. [boost] flies 4x faster.
  void update(
    double dt,
    WalkWorld world, {
    required vm.Vector2 move,
    required double lift,
    double turn = 0,
    bool boost = false,
    required double riverLevel,
  }) {
    yaw += turn * dt;
    // Speed grows with height: crawl between towers, cruise over the city.
    final ground = world.terrainAt(position.x, position.z) ?? riverLevel;
    final height = max(0.0, position.y - ground);
    final cruise = (12 + height * 0.45).clamp(12.0, 160.0) * (boost ? 4 : 1);

    final f = vm.Vector3(sin(yaw), 0, cos(yaw));
    // Screen-right. flutter_scene's view is left-handed (+Z forward, +Y up,
    // +X right when facing +Z), so right is d(forward)/d(yaw). This matches
    // FlyCameraController once its opposite yaw sign is accounted for.
    final r = vm.Vector3(cos(yaw), 0, -sin(yaw));
    final want = (f * move.y + r * move.x);
    if (want.length > 1) want.normalize();
    want.scale(cruise);
    // Ease toward the wanted velocity (inertia), stop a little quicker.
    final ease = min(1.0, dt * (want.length2 > 0 ? 3.0 : 4.0));
    _velocity.add((want - _velocity) * ease);
    _climb += (lift * cruise * 0.6 - _climb) * min(1.0, dt * 4);

    final next = position + _velocity * dt + vm.Vector3(0, _climb * dt, 0);

    // Keep above the ground (and any bridge deck), below the ceiling.
    final floor = world.groundAt(next.x, next.z, next.y) ?? riverLevel;
    next.y = next.y.clamp(
      max(floor, riverLevel) + minClearance,
      riverLevel + maxAltitude,
    );
    // Slide around buildings that are taller than the drone.
    world.resolveWalls(next, radius);
    position.setFrom(next);
  }

  /// Turns the view by a drag ([dx], [dy] in radians).
  void look(double dx, double dy) {
    yaw += dx; // dragging right turns the view right (yaw grows rightward)
    pitch = (pitch - dy).clamp(-1.45, 1.2);
  }
}
