import 'dart:math';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';

/// Glowing lamp heads along the main roads, shown at sunset and night.
/// One instanced mesh; the glow comes from bloom, not real lights, which
/// keeps thousands of lamps cheap.
Node buildStreetLamps(List<RidePath> roads) {
  final heads = InstancedMesh(
    geometry: IcosphereGeometry(radius: 0.5, subdivisions: 1),
    material: UnlitMaterial()..baseColorFactor = vm.Vector4(4.0, 2.9, 1.6, 1),
  );
  for (final road in roads) {
    for (var s = 10.0; s < road.length; s += 32) {
      final (p, fwd) = road.sample(s);
      final right = vm.Vector3(-fwd.z, 0, fwd.x);
      for (final side in [-1.0, 1.0]) {
        heads.addInstance(
          vm.Matrix4.compose(
            p + right * (7.5 * side) + vm.Vector3(0, 7, 0),
            vm.Quaternion.identity(),
            vm.Vector3.all(1.4),
          ),
        );
      }
    }
  }
  return Node(name: 'street lamps')
    ..castsShadows = false
    ..visible = false
    ..add(
      Node()
        ..castsShadows = false
        ..addComponent(InstancedMeshComponent(heads)),
    );
}

/// Screen-space rain streaks over the 3D view.
class RainPainter {
  RainPainter._();

  static final List<(double, double, double)> drops = () {
    final rnd = Random(3);
    return [
      for (var i = 0; i < 260; i++)
        (rnd.nextDouble(), rnd.nextDouble(), 0.7 + rnd.nextDouble() * 0.6),
    ];
  }();
}
