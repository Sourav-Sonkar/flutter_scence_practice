/// 2D polygon helpers on (x, z) points.
library;

typedef P2 = (double, double);

/// Twice the signed area; positive when the ring is counter-clockwise in a
/// frame with x right and z up.
double signedArea2(List<P2> ring) {
  var a = 0.0;
  for (var i = 0; i < ring.length; i++) {
    final (x0, z0) = ring[i];
    final (x1, z1) = ring[(i + 1) % ring.length];
    a += x0 * z1 - x1 * z0;
  }
  return a;
}

/// Drops a repeated closing point and consecutive duplicates.
List<P2> cleanRing(List<P2> pts) {
  final out = <P2>[];
  for (final p in pts) {
    if (out.isEmpty || _dist2(out.last, p) > 1e-6) out.add(p);
  }
  if (out.length > 1 && _dist2(out.first, out.last) < 1e-6) out.removeLast();
  return out;
}

double _dist2(P2 a, P2 b) {
  final dx = a.$1 - b.$1, dz = a.$2 - b.$2;
  return dx * dx + dz * dz;
}

/// Ear-clipping triangulation of a simple polygon. Returns index triples
/// into [ring]. Falls back to a fan if the polygon is self-intersecting.
List<int> triangulate(List<P2> ring) {
  final n = ring.length;
  if (n < 3) return const [];
  final ccw = signedArea2(ring) > 0;
  final idx = List<int>.generate(n, (i) => i);
  final out = <int>[];
  var guard = 0;
  while (idx.length > 3 && guard < n * n) {
    guard++;
    var clipped = false;
    for (var k = 0; k < idx.length; k++) {
      final ia = idx[(k - 1 + idx.length) % idx.length];
      final ib = idx[k];
      final ic = idx[(k + 1) % idx.length];
      final a = ring[ia], b = ring[ib], c = ring[ic];
      final cross =
          (b.$1 - a.$1) * (c.$2 - a.$2) - (b.$2 - a.$2) * (c.$1 - a.$1);
      if (ccw ? cross <= 1e-9 : cross >= -1e-9) continue; // reflex or flat
      var inside = false;
      for (final ip in idx) {
        if (ip == ia || ip == ib || ip == ic) continue;
        if (_inTriangle(ring[ip], a, b, c)) {
          inside = true;
          break;
        }
      }
      if (inside) continue;
      out.addAll([ia, ib, ic]);
      idx.removeAt(k);
      clipped = true;
      break;
    }
    if (!clipped) {
      // Degenerate or self-intersecting: fan the rest.
      for (var k = 1; k < idx.length - 1; k++) {
        out.addAll([idx[0], idx[k], idx[k + 1]]);
      }
      return out;
    }
  }
  if (idx.length == 3) out.addAll(idx);
  return out;
}

bool _inTriangle(P2 p, P2 a, P2 b, P2 c) {
  double s(P2 p1, P2 p2, P2 p3) =>
      (p1.$1 - p3.$1) * (p2.$2 - p3.$2) - (p2.$1 - p3.$1) * (p1.$2 - p3.$2);
  final d1 = s(p, a, b), d2 = s(p, b, c), d3 = s(p, c, a);
  final neg = d1 < 0 || d2 < 0 || d3 < 0;
  final pos = d1 > 0 || d2 > 0 || d3 > 0;
  return !(neg && pos);
}
