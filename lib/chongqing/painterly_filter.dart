import 'package:flutter/foundation.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';

/// The Painted style's full-screen painterly filter (shaders/painterly.frag):
/// a Kuwahara filter that turns smooth 3D shading into soft, flat brush
/// patches with crisp edges, plus a light paper grain.
class PainterlyFilter {
  PainterlyFilter._(this.effect);

  final PostEffect effect;

  /// Loads the compiled shader and adds the (disabled) effect to [scene].
  /// Returns null if the shader bundle isn't available on this platform.
  static Future<PainterlyFilter?> attach(Scene scene) async {
    try {
      // Built by hook/build.dart and listed under flutter: assets.
      final library = await gpu.loadShaderLibraryAsync(
        'build/shaderbundles/painterly.shaderbundle',
      );
      final shader = library?['PainterlyFragment'];
      if (shader == null) return null;
      final effect = PostEffect(
        fragmentShader: shader,
        insertion: PostInsertion.afterTonemap,
        enabled: false,
        useFrameInfo: true,
      );
      scene.postProcess.customEffects.add(effect);
      return PainterlyFilter._(effect)..configure(radius: 4, stride: 1.5);
    } catch (e) {
      debugPrint('Painterly filter unavailable: $e');
      return null;
    }
  }

  bool get enabled => effect.enabled;
  set enabled(bool v) => effect.enabled = v;

  /// [radius] is samples per side (up to 4); [stride] is pixels between
  /// samples, so the brush is about radius x stride pixels.
  void configure({
    double radius = 4,
    double strength = 1,
    double grain = 0.05,
    double stride = 1.5,
  }) {
    effect.setUniformBlockFromFloats('PainterlyParams', [
      radius,
      strength,
      grain,
      stride,
    ]);
  }
}
