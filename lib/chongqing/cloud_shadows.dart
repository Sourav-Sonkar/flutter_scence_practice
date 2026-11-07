import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'sky.dart';

/// Cloud shadows drifting over the city (shaders/cloud_shadows.frag), in
/// both styles: a full-screen pass on the HDR scene that darkens whatever
/// lies under a cloud, found by tracing each pixel toward the sun.
class CloudShadows extends CustomRenderPass {
  CloudShadows._(this._shader);

  final gpu.Shader _shader;

  /// Loads the shader and adds the pass to [scene]. Returns null if the
  /// shader bundle isn't available on this platform.
  static Future<CloudShadows?> attach(Scene scene) async {
    try {
      final library = await gpu.loadShaderLibraryAsync(
        'build/shaderbundles/city.shaderbundle',
      );
      final shader = library?['CloudShadowFragment'];
      if (shader == null) return null;
      final pass = CloudShadows._(shader);
      scene.addRenderPass(pass);
      return pass;
    } catch (e) {
      debugPrint('Cloud shadows unavailable: $e');
      return null;
    }
  }

  /// Wind over the city, metres a second (toward the east, like the sky's
  /// clouds); faster than real so the drift reads in a miniature.
  static final vm.Vector2 wind = vm.Vector2(14, 5);

  final vm.Vector2 _offset = vm.Vector2.zero();
  final Float32List _params = Float32List(8);

  @override
  String get name => 'cloud shadows';

  @override
  RenderStage get stage => RenderStage.afterScene;

  @override
  Set<RenderInput> get inputs => const {RenderInput.depth};

  /// Moves the clouds on and follows the sky: firm patches on a fair day,
  /// fading as the sun sets, none under an overcast sky or at night.
  void update(SkyState sky, double dt) {
    _offset.addScaled(wind, -dt);
    final day = ((sky.elevation - 1) / 8).clamp(0.0, 1.0);
    final strength = 0.42 * day * (1 - sky.cloudOvercast);
    enabled = strength > 0.01;
    final sun = sky.sun.normalized();
    _params
      ..[0] = sun.x
      ..[1] = sun.y
      ..[2] = sun.z
      ..[3] = strength
      ..[4] = _offset.x
      ..[5] = _offset.y
      ..[6] = 450
      ..[7] = sky.cloudCover;
  }

  @override
  void execute(RenderPassContext context) {
    final depth = context.sceneDepthLinear;
    if (depth == null) return;
    context.applyShader(
      _shader,
      textures: {'input_depth': depth},
      samplers: {
        'input_depth': gpu.SamplerOptions(
          minFilter: gpu.MinMagFilter.nearest,
          magFilter: gpu.MinMagFilter.nearest,
        ),
      },
      uniforms: {
        'PostCameraInfo': context.cameraInfo,
        'CloudShadowParams': ByteData.sublistView(_params),
      },
    );
  }
}
