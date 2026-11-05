import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene_practice/worms/worm_swarm_view.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: Scaffold(body: WormSwarmView()));
  }
}

class FirstScene extends StatelessWidget {
  const FirstScene({super.key});

  @override
  Widget build(BuildContext context) {
    return SceneView.declarative(
      // The camera orbits the origin once per second.
      cameraBuilder: (elapsed) {
        final t = elapsed.inMicroseconds / 1e6;
        return PerspectiveCamera(
          position: vm.Vector3(sin(t) * 5, 2, cos(t) * 5),
          target: vm.Vector3(0, 0, 0),
        );
      },
      loadingBuilder: (context, progress) =>
          const Center(child: CircularProgressIndicator()),
      children: [
        SceneNode(
          components: [SpinComponent(400)],

          children: [
            SceneMesh(
              geometry: CuboidGeometry(vm.Vector3(2, 2, 2), debugColors: true),
              material: UnlitMaterial(),
            ),
          ],
        ),
      ],
    );
  }
}

class SpinComponent extends Component {
  SpinComponent(this.radiansPerSecond);

  final double radiansPerSecond;

  // Runs once when the node joins a live scene, before the first update.
  @override
  void onMount() {
    debugPrint('SpinComponent attached and driving its node');
  }

  // Runs every frame while mounted. deltaSeconds is the time since the
  // previous tick, so motion stays framerate independent.
  @override
  void update(double deltaSeconds) {
    node.localTransform.rotateY(radiansPerSecond * deltaSeconds);
    node.markTransformDirty();
  }

  // Runs when the node leaves the scene. Release any resources here.
  @override
  void onUnmount() {
    debugPrint('SpinComponent removed from the scene');
  }
}
