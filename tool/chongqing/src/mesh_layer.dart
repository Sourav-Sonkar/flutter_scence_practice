import 'dart:math' show sqrt, sin, cos, pi, max;
import 'dart:typed_data';

/// Accumulates one renderable layer: positions, sRGB vertex colours and
/// triangle indices. Triangles are wound so their face normal agrees with a
/// caller-supplied outward direction, which keeps back-face culling correct
/// without reasoning about winding at every call site.
class MeshLayer {
  MeshLayer(this.name, {this.hasUv = false});

  /// Window texture tiling: one texture repeat covers this many metres of
  /// facade horizontally (8 bays of 3.6 m) and vertically (8 floors of 3.2 m).
  static const double facadeTileU = 28.8;
  static const double facadeTileV = 25.6;

  /// A texture coordinate inside the solid pillar column of the window
  /// texture, used for roofs so they show plain wall colour.
  static const (double, double) solidUv = (0.004, 0.5);

  final String name;
  final bool hasUv;
  final List<double> uvs = [];
  final List<double> positions = [];
  final List<int> colors = []; // RGBA bytes, sRGB
  final List<int> indices = [];

  int get vertexCount => positions.length ~/ 3;

  int vertex(
    double x,
    double y,
    double z,
    (int, int, int) rgb, [
    double u = 0,
    double v = 0,
  ]) {
    if (hasUv) {
      uvs
        ..add(u)
        ..add(v);
    }
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
    List<int> topTriangles, {
    double? facadeGround,
  }) {
    _walls(ring, y0, y1, wall, facadeGround ?? y0);
    final base = vertexCount;
    final (su, sv) = solidUv;
    for (final (x, z) in ring) {
      vertex(x, y1, z, top, su, sv);
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
    double facadeGround,
  ) {
    // Signed area tells which side of each edge is outside.
    var area2 = 0.0;
    for (var i = 0; i < ring.length; i++) {
      final (x0, z0) = ring[i];
      final (x1, z1) = ring[(i + 1) % ring.length];
      area2 += x0 * z1 - x1 * z0;
    }
    final sign = area2 > 0 ? 1.0 : -1.0;
    // Facade texture: u runs along the perimeter, v up from the building's
    // ground, so windows line up floor by floor across stacked parts.
    final v0 = (y0 - facadeGround) / facadeTileV;
    final v1 = (y1 - facadeGround) / facadeTileV;
    var along = 0.0;
    for (var i = 0; i < ring.length; i++) {
      final (x0, z0) = ring[i];
      final (x1, z1) = ring[(i + 1) % ring.length];
      final ex = x1 - x0, ez = z1 - z0;
      final len = (ex * ex + ez * ez);
      final u0 = along / facadeTileU;
      // Snap each wall to whole bays so windows never get sliced.
      final bays = (len <= 0 ? 0.0 : sqrt(len) / 3.6).roundToDouble();
      along += bays * 3.6;
      final u1 = along / facadeTileU;
      final outward = (ez * sign, 0.0, -ex * sign);
      final a = vertex(x0, y0, z0, rgb, u0, -v0);
      final b = vertex(x1, y0, z1, rgb, u1, -v0);
      final c = vertex(x1, y1, z1, rgb, u1, -v1);
      final d = vertex(x0, y1, z0, rgb, u0, -v1);
      quad(a, b, c, d, outward);
    }
  }

  /// A truncated cone (or cylinder) around (cx, cz) from y0 (radius r0) to
  /// y1 (radius r1), with a flat top cap when r1 > 0.
  void frustum(
    double cx,
    double cz,
    double y0,
    double y1,
    double r0,
    double r1,
    (int, int, int) rgb, {
    int segments = 32,
  }) {
    final ring0 = <int>[], ring1 = <int>[];
    for (var k = 0; k < segments; k++) {
      final a = k / segments * 2 * pi;
      ring0.add(vertex(cx + cos(a) * r0, y0, cz + sin(a) * r0, rgb));
      ring1.add(vertex(cx + cos(a) * r1, y1, cz + sin(a) * r1, rgb));
    }
    final slope = (r0 - r1) / max(1e-6, y1 - y0);
    for (var k = 0; k < segments; k++) {
      final n = (k + 1) % segments;
      final a = (k + 0.5) / segments * 2 * pi;
      quad(ring0[k], ring0[n], ring1[n], ring1[k], (cos(a), slope, sin(a)));
    }
    if (r1 > 0.01) {
      final centre = vertex(cx, y1, cz, rgb);
      for (var k = 0; k < segments; k++) {
        triangle(ring1[k], ring1[(k + 1) % segments], centre, (0, 1, 0));
      }
    }
  }

  Float32List positionsF32() => Float32List.fromList(positions);
  Float32List uvsF32() => Float32List.fromList(uvs);
  Uint8List colorsU8() => Uint8List.fromList(colors);
  Uint32List indicesU32() => Uint32List.fromList(indices);
}
