// Bakes the sky's cloud textures into assets/chongqing/. Run from the project
// root:
//
//   fvm dart run tool/chongqing/clouds.dart
//
// Generated here (natively) rather than in the app because flutter_scene's
// Dart noise overflows on the web. Each texture wraps seamlessly around the
// horizon: the noise is sampled on a cylinder. White pixels, cloud density
// in alpha; the app colours and thresholds them.
import 'dart:io';
import 'dart:math';

import 'package:flutter_scene/src/noise/fast_noise_lite.dart';
import 'package:image/image.dart' as img;

void main() {
  // Puffy: features as wide as they are tall. Layered: three times wider.
  _bake('clouds_puffy.png', seed: 17, freq: 1.6, stretch: 1.0);
  _bake('clouds_layered.png', seed: 29, freq: 1.3, stretch: 3.0);
}

void _bake(String name, {required int seed, required double freq, required double stretch}) {
  const width = 512, height = 128;
  final n = FastNoiseLite(seed: seed)
    ..noiseType = NoiseType.openSimplex2
    ..fractalType = FractalType.fbm
    ..octaves = 5
    ..frequency = freq;
  final out = img.Image(width: width, height: height, numChannels: 4);
  // Pixel-square noise: the ring's circumference over 512 px matches the
  // band's 3.2 noise units over 128 px when r = 3.2*512/(128*2*pi). A larger
  // [stretch] shrinks the ring, widening features sideways.
  final r = 3.2 * width / (height * 2 * pi) / stretch;
  for (var y = 0; y < height; y++) {
    final v = y / (height - 1);
    final edge = sin(v * pi); // fade out at the band's top and bottom
    for (var x = 0; x < width; x++) {
      final a = x / width * 2 * pi;
      final value = n.getNoise3(cos(a) * r, v * 3.2, sin(a) * r);
      final d = ((value * 0.5 + 0.5) * edge).clamp(0.0, 1.0);
      out.setPixelRgba(x, y, 255, 255, 255, (d * 255).round());
    }
  }
  File('assets/chongqing/$name').writeAsBytesSync(img.encodePng(out));
  stdout.writeln('wrote assets/chongqing/$name');
}
