import 'dart:math';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';

/// Glowing lamp heads along the main roads, lit from dusk. The glow comes
/// from bloom on bright unlit spheres, not real lights, which keeps
/// thousands of lamps cheap. Most are old sodium lamps (orange) or warm
/// LEDs; a handful flicker, as real street lights do.
class StreetLamps {
  /// [lamps] are the build tool's street lamp details: pole bases at the
  /// road edge, rotated so local +x is the arm pointing over the road. The
  /// head sits at the arm's tip.
  StreetLamps(List<Detail> lamps) {
    final rnd = Random(9);
    final geometry = CuboidGeometry(vm.Vector3(0.8, 0.2, 0.4));
    InstancedMesh mesh(vm.Vector4 c) => InstancedMesh(
      geometry: geometry,
      material: UnlitMaterial()..baseColorFactor = c,
    );
    final sodium = mesh(vm.Vector4(2.4, 1.15, 0.38, 1));
    final led = mesh(vm.Vector4(2.1, 1.75, 1.25, 1));
    _flicker = mesh(vm.Vector4(1, 1, 1, 1));
    for (final lamp in lamps) {
      final rot = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), lamp.rotation);
      final m = vm.Matrix4.compose(
        lamp.position + rot.rotated(vm.Vector3(2.0, 7.75, 0)),
        rot,
        vm.Vector3.all(1),
      );
      final r = rnd.nextDouble();
      if (r < 0.02) {
        _flicker.addInstance(m);
        _phase.add(rnd.nextDouble() * 100);
      } else {
        (r < 0.55 ? sodium : led).addInstance(m);
      }
    }
    for (final m in [sodium, led, _flicker]) {
      root.add(
        Node()
          ..castsShadows = false
          ..addComponent(InstancedMeshComponent(m)),
      );
    }
    root
      ..castsShadows = false
      ..visible = false;
  }

  final Node root = Node(name: 'street lamps');
  late final InstancedMesh _flicker;
  final List<double> _phase = [];

  /// [level] 0..1 fades lamps in at dusk; flickering ones stutter.
  void update(double t, double level) {
    final on = level > 0.05;
    if (root.visible != on) root.visible = on;
    if (!on) return;
    for (var i = 0; i < _phase.length; i++) {
      final ph = _phase[i];
      // Mostly on, with irregular quick dropouts.
      final n = sin(t * 13 + ph) * sin(t * 7.3 + ph * 1.7) * sin(t * 2.1 + ph);
      final k = n > 0.55 ? 0.15 : (0.85 + 0.15 * sin(t * 40 + ph));
      _flicker.setInstanceColor(i, vm.Vector4(2.2 * k, 1.6 * k, 0.9 * k, 1));
    }
  }
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
