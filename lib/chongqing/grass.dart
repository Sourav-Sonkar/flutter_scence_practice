import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';

/// The two grass models: a dense lawn patch (about 2.9 m square, thin blade
/// cards) for right around the camera, and a light tuft for further out.
class GrassModels {
  GrassModels._(this.patch, this.tuft);

  final MeshPrimitive patch, tuft;

  /// Loads assets/chongqing/grass_patch.glb and grass.glb. Returns null if
  /// either is missing, so the city still runs without grass.
  static Future<GrassModels?> load() async {
    try {
      final patch = _firstPrimitive(
        await Node.fromGlbAsset('assets/chongqing/grass_patch.glb'),
      );
      final tuft = _firstPrimitive(
        await Node.fromGlbAsset('assets/chongqing/grass.glb'),
      );
      if (patch == null || tuft == null) return null;
      for (final m in [patch.material, tuft.material]) {
        // Cut-out blades: blended ones would only draw their front faces.
        if (m is PhysicallyBasedMaterial) {
          m
            ..alphaMode = AlphaMode.mask
            ..doubleSided = true;
        }
      }
      return GrassModels._(patch, tuft);
    } catch (e) {
      debugPrint('Grass unavailable: $e');
      return null;
    }
  }

  static MeshPrimitive? _firstPrimitive(Node node) {
    final mesh = node.mesh;
    if (mesh != null && mesh.primitives.isNotEmpty)
      return mesh.primitives.first;
    for (final child in node.children) {
      final p = _firstPrimitive(child);
      if (p != null) return p;
    }
    return null;
  }
}

/// Grass around the trees near the camera. Trees already mark the parks,
/// verges and green slopes, so each tree gets a few fixed spots around its
/// trunk. The nearest spots get lawn patches, the next ones tufts; a fixed
/// pool of each is re-placed when the camera has moved a few metres, so the
/// cost stays the same wherever you are. Grass is under a metre tall, so it
/// only matters at street level and in the drone.
class GrassField {
  GrassField(CityData data, GrassModels models) {
    final rnd = Random(11);
    for (final d in data.details) {
      if (!_trees.contains(d.type)) continue;
      final reach = max(d.size.x * 0.5, 2.0);
      for (var k = 0; k < 4; k++) {
        final a = rnd.nextDouble() * 2 * pi;
        final r = reach * (0.3 + rnd.nextDouble() * 1.1);
        final x = d.position.x + cos(a) * r, z = d.position.z + sin(a) * r;
        final y = _ground(data, x, z) ?? d.position.y;
        // Lie along the slope, not flat over it: a hillside patch would
        // otherwise float on one side and bury the other.
        double at(double dx, double dz) => _ground(data, x + dx, z + dz) ?? y;
        final normal = vm.Vector3(
          at(-1.5, 0) - at(1.5, 0),
          3,
          at(0, -1.5) - at(0, 1.5),
        )..normalize();
        final spot = (
          position: vm.Vector3(x, y - 0.05, z),
          turn:
              vm.Quaternion.fromTwoVectors(vm.Vector3(0, 1, 0), normal) *
              vm.Quaternion.axisAngle(
                vm.Vector3(0, 1, 0),
                rnd.nextDouble() * 2 * pi,
              ),
          scale: 0.8 + rnd.nextDouble() * 0.5,
        );
        _spots.putIfAbsent(_key(x, z), () => []).add(spot);
      }
    }
    _patches = InstancedMesh(
      geometry: models.patch.geometry,
      material: models.patch.material,
    );
    _tufts = InstancedMesh(
      geometry: models.tuft.geometry,
      material: models.tuft.material,
    );
    for (var i = 0; i < patchCount; i++) {
      _patches.addInstance(_hidden);
    }
    for (var i = 0; i < tuftCount; i++) {
      _tufts.addInstance(_hidden);
    }
    root
      ..castsShadows = false
      ..visible = false
      ..add(Node()..addComponent(InstancedMeshComponent(_patches)))
      ..add(Node()..addComponent(InstancedMeshComponent(_tufts)));
  }

  static const _trees = {
    'treeHuangge',
    'treeCamphor',
    'treeBanyan',
    'treeGinkgo',
    'shrub',
  };

  /// Lawn patches within [patchRange] of the camera, tufts out to
  /// [tuftRange]; beyond that grass is too small to see.
  static const patchCount = 28, tuftCount = 320;
  static const patchRange = 35.0, tuftRange = 90.0;

  /// The tuft model is in centimetres and about 0.6 m tall at this scale.
  static const _tuftScale = 0.011;

  static const _cell = 30.0;
  static int _key(double x, double z) =>
      (x / _cell).floor() * 100003 + (z / _cell).floor();

  static final vm.Matrix4 _hidden = vm.Matrix4.zero();

  final Node root = Node(name: 'grass');
  final Map<
    int,
    List<({vm.Vector3 position, vm.Quaternion turn, double scale})>
  >
  _spots = {};
  late final InstancedMesh _patches, _tufts;
  final vm.Vector3 _placedAt = vm.Vector3.all(1e9);

  static double? _ground(CityData data, double x, double z) {
    for (final g in data.walk.grids) {
      if (g.contains(x, z)) return g.heightAt(x, z);
    }
    return null;
  }

  /// Shows grass when [near] (the camera is low over this district) and
  /// re-places it once the camera has moved a few metres.
  void update(vm.Vector3 eye, {required bool near}) {
    if (root.visible != near) root.visible = near;
    if (!near || (eye - _placedAt).length2 < 6 * 6) return;
    _placedAt.setFrom(eye);
    final found =
        <(double, ({vm.Vector3 position, vm.Quaternion turn, double scale}))>[];
    final r = (tuftRange / _cell).ceil();
    final ci = (eye.x / _cell).floor(), cj = (eye.z / _cell).floor();
    for (var i = ci - r; i <= ci + r; i++) {
      for (var j = cj - r; j <= cj + r; j++) {
        for (final s in _spots[i * 100003 + j] ?? const []) {
          final d2 = s.position.distanceToSquared(eye);
          if (d2 < tuftRange * tuftRange) found.add((d2, s));
        }
      }
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    var next = 0;
    _patches.updateInstanceTransforms((list) {
      for (var i = 0; i < list.length; i++) {
        final ok =
            next < found.length && found[next].$1 < patchRange * patchRange;
        // The lawn's blades are short; twice the height reads as grass.
        list[i].setFrom(ok ? _place(found[next++].$2, 1, tall: 2) : _hidden);
      }
    }, recomputeWinding: false);
    _tufts.updateInstanceTransforms((list) {
      for (var i = 0; i < list.length; i++) {
        list[i].setFrom(
          next < found.length ? _place(found[next++].$2, _tuftScale) : _hidden,
        );
      }
    }, recomputeWinding: false);
  }

  static vm.Matrix4 _place(
    ({vm.Vector3 position, vm.Quaternion turn, double scale}) s,
    double base, {
    double tall = 1,
  }) {
    final k = base * s.scale;
    return vm.Matrix4.compose(s.position, s.turn, vm.Vector3(k, k * tall, k));
  }
}
