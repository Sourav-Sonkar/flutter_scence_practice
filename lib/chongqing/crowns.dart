import 'dart:math';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';

/// LED bands around the tops of the tallest towers. Chongqing's skyline
/// runs slow colour shows at night; each tower here cycles through a warm
/// gold / red / violet palette on its own phase.
class LedCrowns {
  LedCrowns(List<Detail> crowns) {
    _mesh = InstancedMesh(
      geometry: CuboidGeometry(vm.Vector3.all(1)),
      material: UnlitMaterial(),
    );
    final rnd = Random(4);
    // Each crown is a hollow ring: four thin strips along the roof edge of
    // the tower's oriented footprint, all sharing that tower's colour.
    const t = 0.7; // strip thickness, metres
    for (final c in crowns) {
      final rot = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), c.rotation);
      final centre = c.position + vm.Vector3(0, c.size.y / 2, 0);
      final hx = c.size.x / 2, hz = c.size.z / 2;
      for (final (offset, size) in [
        (vm.Vector3(0, 0, hz), vm.Vector3(c.size.x, c.size.y, t)),
        (vm.Vector3(0, 0, -hz), vm.Vector3(c.size.x, c.size.y, t)),
        (vm.Vector3(hx, 0, 0), vm.Vector3(t, c.size.y, c.size.z)),
        (vm.Vector3(-hx, 0, 0), vm.Vector3(t, c.size.y, c.size.z)),
      ]) {
        _mesh.addInstance(
          vm.Matrix4.compose(
            centre + rot.asRotationMatrix().transformed(offset),
            rot,
            size,
          ),
        );
      }
      _phase.add(rnd.nextDouble() * 2 * pi);
      _speed.add(0.25 + rnd.nextDouble() * 0.35);
    }
    root
      ..castsShadows = false
      ..visible = false
      ..add(
        Node()
          ..castsShadows = false
          ..addComponent(InstancedMeshComponent(_mesh)),
      );
  }

  final Node root = Node(name: 'led crowns');
  late final InstancedMesh _mesh;
  final List<double> _phase = [], _speed = [];

  static final List<vm.Vector3> _palette = [
    vm.Vector3(2.6, 1.6, 0.5), // gold
    vm.Vector3(2.6, 0.5, 0.35), // red
    vm.Vector3(1.4, 0.6, 2.4), // violet
    vm.Vector3(0.6, 1.4, 2.6), // ice blue
  ];

  void update(double t, double level) {
    final on = level > 0.3;
    if (root.visible != on) root.visible = on;
    if (!on) return;
    final k = ((level - 0.3) / 0.7).clamp(0.0, 1.0);
    for (var i = 0; i < _phase.length; i++) {
      final x = (t * _speed[i] + _phase[i]) % _palette.length;
      final a = _palette[x.floor() % _palette.length];
      final b = _palette[(x.floor() + 1) % _palette.length];
      final f = x - x.floor();
      final s = f * f * (3 - 2 * f);
      final c = (a + (b - a) * s) * k;
      final colour = vm.Vector4(c.x, c.y, c.z, 1);
      for (var e = 0; e < 4; e++) {
        _mesh.setInstanceColor(i * 4 + e, colour);
      }
    }
  }
}
