import 'dart:math';

import 'package:flutter/material.dart' hide Material;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'worm_sim.dart';

/// A swarm of worms that chases a glowing target. Drag or tap to move the
/// target; after a few idle seconds it wanders on its own.
class WormSwarmView extends StatefulWidget {
  const WormSwarmView({super.key});

  @override
  State<WormSwarmView> createState() => _WormSwarmViewState();
}

class _WormSwarmViewState extends State<WormSwarmView> {
  final Scene _scene = Scene();
  final WormSwarmSim _sim = WormSwarmSim();
  final PerspectiveCamera _camera = PerspectiveCamera(
    position: vm.Vector3(0, 2.7, 3.6),
    target: vm.Vector3(0, 0.1, 0.2),
  );
  final ValueNotifier<int> _fps = ValueNotifier(0);

  late final InstancedMesh _worms;
  late final Node _targetNode;
  bool _ready = false;
  Size _viewSize = Size.zero;
  double _idle = 0;
  double _clock = 0;
  double _fpsTime = 0;
  int _fpsFrames = 0;

  static const double _targetRadius = 0.07;
  static const double _targetHover = 0.45;

  @override
  void initState() {
    super.initState();
    Scene.initializeStaticResources().then((_) {
      _buildScene();
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _fps.dispose();
    super.dispose();
  }

  PhysicallyBasedMaterial _pbr(vm.Vector3 c, {double roughness = 0.8}) =>
      PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(c.x, c.y, c.z, 1)
        ..metallicFactor = 0
        ..roughnessFactor = roughness;

  void _buildScene() {
    _scene.directionalLight = DirectionalLight(
      direction: vm.Vector3(-0.45, -1.0, -0.35),
      color: vm.Vector3(1.0, 0.96, 0.9),
      intensity: 3.2,
      castsShadow: true,
      shadowMaxDistance: 20,
    );
    _scene.environmentSettings = EnvironmentSettings(
      toneMapping: ToneMappingMode.aces,
      exposure: 0.95,
      environmentIntensity: 0.45,
      bloomEnabled: true,
      bloomThreshold: 1.2,
      bloomIntensity: 0.25,
      ambientOcclusionEnabled: true,
      ambientOcclusionMethod: AmbientOcclusionMethod.groundTruth,
      ambientOcclusionIntensity: 1.3,
      ambientOcclusionRadius: 0.2,
      vignetteEnabled: true,
      vignetteIntensity: 0.3,
    );

    // Floor, with a grid so motion reads clearly.
    _scene.add(
      Node(
        mesh: Mesh(
          PlaneGeometry(width: 30, depth: 30),
          _pbr(vm.Vector3(0.16, 0.18, 0.23)),
        ),
      ),
    );
    final grid = InstancedMesh(
      geometry: CuboidGeometry(vm.Vector3(1, 0.002, 0.008)),
      material: _pbr(vm.Vector3(0.5, 0.53, 0.6)),
    );
    const spacing = 0.4;
    final hx = _sim.arenaHalfX + 0.6, hz = _sim.arenaHalfZ + 0.6;
    for (var x = -hx; x <= hx + 1e-6; x += spacing) {
      grid.addInstance(
        vm.Matrix4.compose(
          vm.Vector3(x, 0.001, 0),
          vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), pi / 2),
          vm.Vector3(hz * 2, 1, 1),
        ),
      );
    }
    for (var z = -hz; z <= hz + 1e-6; z += spacing) {
      grid.addInstance(
        vm.Matrix4.compose(
          vm.Vector3(0, 0.001, z),
          vm.Quaternion.identity(),
          vm.Vector3(hx * 2, 1, 1),
        ),
      );
    }
    _scene.add(Node()..addComponent(InstancedMeshComponent(grid)));

    // Bench, sized to the simulation's collision box.
    final (bx0, by0, bz0) = _sim.bench.min;
    final (bx1, by1, bz1) = _sim.bench.max;
    _scene.add(
      Node(
          mesh: Mesh(
            CuboidGeometry(vm.Vector3(bx1 - bx0, by1 - by0, bz1 - bz0)),
            _pbr(vm.Vector3(0.5, 0.52, 0.55), roughness: 0.6),
          ),
        )
        ..position = vm.Vector3(
          (bx0 + bx1) / 2,
          (by0 + by1) / 2,
          (bz0 + bz1) / 2,
        ),
    );

    // Worms: one capsule per segment, all in a single instanced draw.
    _worms = InstancedMesh(
      geometry: CapsuleGeometry(
        radius: _sim.radius,
        height: _sim.segmentLength,
        radialSegments: 10,
        capRings: 3,
      ),
      material: _pbr(vm.Vector3(0.3, 0.02, 0.03), roughness: 0.3)
        ..clearcoat = 0.7
        ..clearcoatRoughness = 0.12,
    );
    final rng = Random(3);
    final segs = _sim.pointsPerWorm - 1;
    for (var w = 0; w < _sim.wormCount; w++) {
      final shade = 0.7 + rng.nextDouble() * 0.5;
      final color = vm.Vector4(
        shade,
        shade * (0.85 + rng.nextDouble() * 0.3),
        shade * (0.85 + rng.nextDouble() * 0.3),
        1,
      );
      for (var s = 0; s < segs; s++) {
        _worms.addInstance(vm.Matrix4.identity(), color: color);
      }
    }
    _writeWormTransforms();
    _scene.add(
      Node()
        ..frustumCulled = false
        ..addComponent(InstancedMeshComponent(_worms)),
    );

    _targetNode = Node(
      mesh: Mesh(
        SphereGeometry(radius: _targetRadius, segments: 24, rings: 12),
        UnlitMaterial()..baseColorFactor = vm.Vector4(0.4, 2.4, 2.6, 1),
      ),
    )..castsShadows = false;
    _scene.add(_targetNode);
  }

  /// Places each capsule between two consecutive simulated points.
  void _writeWormTransforms() {
    final pos = _sim.pos;
    final radii = _sim.radii;
    final ppw = _sim.pointsPerWorm;
    final segs = ppw - 1;
    final rest = _sim.segmentLength;
    final r0 = _sim.radius;
    _worms.updateInstanceTransforms((list) {
      var k = 0;
      for (var w = 0; w < _sim.wormCount; w++) {
        for (var s = 0; s < segs; s++, k++) {
          final a = (w * ppw + s) * 3, b = a + 3;
          var dx = pos[b] - pos[a];
          var dy = pos[b + 1] - pos[a + 1];
          var dz = pos[b + 2] - pos[a + 2];
          final len = sqrt(dx * dx + dy * dy + dz * dz);
          if (len < 1e-6) {
            (dx, dy, dz) = (0, 1, 0);
          } else {
            dx /= len;
            dy /= len;
            dz /= len;
          }
          // Basis with local +Y along the segment: x = d × helper, z = x × d.
          final (hx, hy, hz) = dy.abs() > 0.9
              ? (1.0, 0.0, 0.0)
              : (0.0, 1.0, 0.0);
          var xx = dy * hz - dz * hy;
          var xy = dz * hx - dx * hz;
          var xz = dx * hy - dy * hx;
          final xl = sqrt(xx * xx + xy * xy + xz * xz);
          xx /= xl;
          xy /= xl;
          xz /= xl;
          final zx = xy * dz - xz * dy;
          final zy = xz * dx - xx * dz;
          final zz = xx * dy - xy * dx;
          final i = w * ppw + s;
          final taper = (radii[i] + radii[i + 1]) * 0.5 / r0;
          final stretch = max(len, 1e-4) / rest;
          list[k].setValues(
            xx * taper,
            xy * taper,
            xz * taper,
            0,
            dx * stretch,
            dy * stretch,
            dz * stretch,
            0,
            zx * taper,
            zy * taper,
            zz * taper,
            0,
            (pos[a] + pos[b]) * 0.5,
            (pos[a + 1] + pos[b + 1]) * 0.5,
            (pos[a + 2] + pos[b + 2]) * 0.5,
            1,
          );
        }
      }
    });
  }

  void _onTick(Duration elapsed, double dt) {
    dt = min(dt, 0.05);
    _clock += dt;
    _idle += dt;
    if (_idle > 3) _autopilot();
    _sim.step(dt);
    _writeWormTransforms();
    final bob = sin(_clock * 3) * 0.04;
    _targetNode.position = _sim.target + vm.Vector3(0, _targetHover + bob, 0);

    _fpsFrames++;
    _fpsTime += dt;
    if (_fpsTime >= 0.25) {
      _fps.value = (_fpsFrames / _fpsTime).round();
      _fpsFrames = 0;
      _fpsTime = 0;
    }
  }

  /// Slow figure-eight that crosses onto and off the bench.
  void _autopilot() {
    final t = _clock;
    final x = sin(t * 0.21) * (_sim.arenaHalfX - 0.7);
    final z = sin(t * 0.34 + 1.2) * (_sim.arenaHalfZ - 0.7);
    _setGoalAt(x, z);
  }

  void _setGoalAt(double x, double z) {
    final y = _sim.overBench(x, z) ? _sim.benchTop : 0.0;
    _sim.setTargetGoal(vm.Vector3(x, y, z));
  }

  void _pointTo(Offset local) {
    if (_viewSize.isEmpty) return;
    _idle = 0;
    final ray = _camera.screenPointToRay(local, _viewSize);
    final o = ray.origin, d = ray.direction;
    if (d.y.abs() < 1e-5) return;
    // Bench top first (it is closer to the camera), then the floor.
    final tTop = (_sim.benchTop - o.y) / d.y;
    if (tTop > 0) {
      final x = o.x + d.x * tTop, z = o.z + d.z * tTop;
      if (_sim.overBench(x, z)) return _setGoalAt(x, z);
    }
    final t = -o.y / d.y;
    if (t > 0) _setGoalAt(o.x + d.x * t, o.z + d.z * t);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewSize = constraints.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onTapDown: (e) => _pointTo(e.localPosition),
              onPanStart: (e) => _pointTo(e.localPosition),
              onPanUpdate: (e) => _pointTo(e.localPosition),
              child: SceneView(_scene, camera: _camera, onTick: _onTick),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 48,
              child: IgnorePointer(
                child: ValueListenableBuilder<int>(
                  valueListenable: _fps,
                  builder: (context, fps, _) => Column(
                    children: [
                      Text(
                        '$fps',
                        style: const TextStyle(
                          color: Color(0xff7fe6dc),
                          fontSize: 56,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Text(
                        'F P S',
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
