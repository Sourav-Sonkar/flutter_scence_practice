import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_look.dart';
import 'facade_textures.dart';
import 'sky.dart';

/// The "Painted" style: hand-painted, anime-inspired shading for the city
/// (assets/chongqing/painted.fmat), one material instance per layer kind.
class PaintedLook {
  PaintedLook._(
    this.materials,
    this._home,
    this._tower,
    this._homeTex,
    this._glassTex,
  );

  /// Loads the painted material instances and gives buildings their window
  /// textures. Returns null if the material isn't available.
  static Future<PaintedLook?> load(
    FacadeTextures home,
    FacadeTextures glass,
  ) async {
    try {
      Future<PreprocessedMaterial> one() =>
          loadFmatMaterial('assets/chongqing/painted.fmat');
      final mats = <String, PreprocessedMaterial>{
        'terrain': await one(),
        'buildings': await one(),
        'towers': await one(),
        'roads': await one(),
        'structures': await one(),
      };
      void tex(PreprocessedMaterial m, String name, Texture2D t) => m.parameters
          .setTexture(name, t.sampledTexture!, sampler: t.sampledSampler);
      tex(mats['buildings']!, 'facade', home.color);
      tex(mats['towers']!, 'facade', glass.color);
      mats['structures']!.doubleSided = true; // wires, deck undersides
      // Windows read clearly on buildings; glass towers reflect the sky.
      mats['buildings']!.parameters
        ..setFloat('detail', 1.0)
        ..setFloat('remap', 1.0);
      mats['towers']!.parameters
        ..setFloat('detail', 1.0)
        ..setFloat('glass', 1.0);
      // Roads and the ground read better a little calmer than the buildings.
      for (final k in ['terrain', 'roads']) {
        mats[k]!.parameters.setFloat('saturation', 1.12);
      }
      final look = PaintedLook._(
        mats,
        mats['buildings']!,
        mats['towers']!,
        home,
        glass,
      );
      // One twin per distinct detail colour (about 20 today).
      for (var i = 0; i < 32; i++) {
        look._pool.add(await one());
      }
      return look;
    } catch (_) {
      return null;
    }
  }

  final Map<String, PreprocessedMaterial> materials;

  /// Painted twins of detail materials (trees, rooftop items, lamp poles),
  /// keyed by the realistic material they replace.
  final Map<Material, PreprocessedMaterial> _details = {};
  final List<PreprocessedMaterial> _pool = [];

  /// The painted twin of a detail [realistic] material: same colour, and
  /// leafy greens get the clumpy foliage shading. Created on first use, from
  /// a preloaded pool so it can be handed out synchronously.
  Material detailFor(Material realistic) {
    final existing = _details[realistic];
    if (existing != null) return existing;
    if (_pool.isEmpty || realistic is! PhysicallyBasedMaterial) {
      return realistic;
    }
    final twin = _pool.removeLast();
    twin.doubleSided = realistic.doubleSided; // wires stay visible
    final c = realistic.baseColorFactor;
    twin.parameters.setVec4('tint', c);
    if (c.y > c.x * 1.15 && c.y > c.z * 1.15) {
      twin.parameters.setFloat('foliage', 1);
    }
    _details[realistic] = twin;
    return twin;
  }

  final PreprocessedMaterial _home, _tower;
  final FacadeTextures _homeTex, _glassTex;
  int _level = -1;

  /// Per-frame colours from the sky: the shadow side takes the sky's hue
  /// (blue by day, violet at dusk, deep navy at night).
  void update(SkyState sky, double hour) {
    final night = sky.night;
    final skyLight =
        (sky.zenith * 0.6 + sky.horizon * 0.6) * (1.0 + 0.6 * (1 - night)) +
        // Night stays dark so the lit windows carry the scene.
        vm.Vector3(0.02, 0.025, 0.05) * (1 - night);
    final shade =
        vm.Vector3(0.5, 0.48, 0.74) * (1 - night) +
        vm.Vector3(0.55, 0.6, 0.95) * night;
    final bounce =
        vm.Vector3(0.55, 0.48, 0.38) * (1 - 0.85 * night) + sky.cityGlow * 2;
    for (final m in [...materials.values, ..._details.values]) {
      m.parameters
        ..setVec3('sky_light', skyLight)
        ..setVec3('shade_tint', shade)
        ..setVec3('ground_bounce', bounce)
        // The moon is faint; boost its band so night shapes still read.
        ..setFloat('light_scale', 0.46 + 0.25 * night);
    }
    _home.parameters.setFloat('lights_strength', 1.4 * night);
    _tower.parameters.setFloat('lights_strength', 0.32 * night);
    final level = CityLook.lightLevelFor(hour);
    if (level != _level) {
      _level = level;
      void tex(PreprocessedMaterial m, Texture2D t) => m.parameters.setTexture(
        'lights',
        t.sampledTexture!,
        sampler: t.sampledSampler,
      );
      tex(_home, _homeTex.lights[level]);
      tex(_tower, _glassTex.lights[level]);
    }
  }
}
