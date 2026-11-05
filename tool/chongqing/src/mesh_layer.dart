import 'dart:typed_data';

/// Accumulates one renderable layer: positions, sRGB vertex colours and
/// triangle indices. Triangles are wound so their face normal agrees with a
/// caller-supplied outward direction, which keeps back-face culling correct
/// without reasoning about winding at every call site.
class MeshLayer {
  MeshLayer(this.name);

  final String name;
  final List<double> positions = [];
  final List<int> colors = []; // RGBA bytes, sRGB
  final List<int> indices = [];

  int get vertexCount => positions.length ~/ 3;

  int vertex(double x, double y, double z, (int, int, int) rgb) {
    positions
      ..add(x)
      ..add(y)
      ..add(z);
    colors
      ..add(rgb.$1)
      ..add(rgb.$2)
      ..add(rgb.$3)
      ..add(255);
    return vertexCount - 1;
  }

  void triangle(int a, int b, int c, (double, double, double) outward) {
    final ax = positions[a * 3],
        ay = positions[a * 3 + 1],
        az = positions[a * 3 + 2];
    final ux = positions[b * 3] - ax,
        uy = positions[b * 3 + 1] - ay,
        uz = positions[b * 3 + 2] - az;
    final vx = positions[c * 3] - ax,
        vy = positions[c * 3 + 1] - ay,
        vz = positions[c * 3 + 2] - az;
    final nx = uy * vz - uz * vy,
        ny = uz * vx - ux * vz,
        nz = ux * vy - uy * vx;
    final dot = nx * outward.$1 + ny * outward.$2 + nz * outward.$3;
    // flutter_scene treats clockwise-from-the-viewer as the front face in this
    // +Y-up frame (checked on device), so the right-handed normal of each
    // emitted triangle points away from [outward].
    if (dot <= 0) {
      indices
        ..add(a)
        ..add(b)
        ..add(c);
    } else {
      indices
        ..add(a)
        ..add(c)
        ..add(b);
    }
  }

  /// Quad a-b-c-d (in order around its edge).
  void quad(int a, int b, int c, int d, (double, double, double) outward) {
    triangle(a, b, c, outward);
    triangle(a, c, d, outward);
  }

  /// Axis-aligned-in-Y box from [y0] to [y1], centred on (x, z), rotated by
  /// the unit direction (dx, dz) for its length axis.
  void box(
    double x,
    double z,
    double y0,
    double y1,
    double length,
    double width,
    double dx,
    double dz,
    (int, int, int) rgb,
  ) {
    final hx = dx * length / 2, hz = dz * length / 2; // along
    final wx = -dz * width / 2, wz = dx * width / 2; // across
    final corners = [
      (x - hx - wx, z - hz - wz),
      (x + hx - wx, z + hz - wz),
      (x + hx + wx, z + hz + wz),
      (x - hx + wx, z - hz + wz),
    ];
    _prism(corners, y0, y1, rgb, rgb);
  }

  /// Extruded prism over a ring with separate wall and top colours.
  void prism(
    List<(double, double)> ring,
    double y0,
    double y1,
    (int, int, int) wall,
    (int, int, int) top,
    List<int> topTriangles,
  ) {
    _walls(ring, y0, y1, wall);
    final base = vertexCount;
    for (final (x, z) in ring) {
      vertex(x, y1, z, top);
    }
    for (var t = 0; t < topTriangles.length; t += 3) {
      triangle(
        base + topTriangles[t],
        base + topTriangles[t + 1],
        base + topTriangles[t + 2],
        (0, 1, 0),
      );
    }
  }

  void _prism(
    List<(double, double)> ring,
    double y0,
    double y1,
    (int, int, int) wall,
    (int, int, int) top,
  ) {
    prism(ring, y0, y1, wall, top, const [0, 1, 2, 0, 2, 3]);
  }

  void _walls(
    List<(double, double)> ring,
    double y0,
    double y1,
    (int, int, int) rgb,
  ) {
    // Signed area tells which side of each edge is outside.
    var area2 = 0.0;
    for (var i = 0; i < ring.length; i++) {
      final (x0, z0) = ring[i];
      final (x1, z1) = ring[(i + 1) % ring.length];
      area2 += x0 * z1 - x1 * z0;
    }
    final sign = area2 > 0 ? 1.0 : -1.0;
    for (var i = 0; i < ring.length; i++) {
      final (x0, z0) = ring[i];
      final (x1, z1) = ring[(i + 1) % ring.length];
      final ex = x1 - x0, ez = z1 - z0;
      final outward = (ez * sign, 0.0, -ex * sign);
      final a = vertex(x0, y0, z0, rgb);
      final b = vertex(x1, y0, z1, rgb);
      final c = vertex(x1, y1, z1, rgb);
      final d = vertex(x0, y1, z0, rgb);
      quad(a, b, c, d, outward);
    }
  }

  Float32List positionsF32() => Float32List.fromList(positions);
  Uint8List colorsU8() => Uint8List.fromList(colors);
  Uint32List indicesU32() => Uint32List.fromList(indices);
}
