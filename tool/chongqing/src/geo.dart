import 'dart:math';
import 'dart:typed_data';

/// Converts latitude/longitude to local metres around an origin.
/// +x is east, +z is south (so north is -z), +y is up.
/// Equirectangular is accurate to well under a metre at district size.
class LocalProjection {
  LocalProjection(this.originLat, this.originLon)
    : _mPerDegLon = 111320 * cos(originLat * pi / 180);

  final double originLat, originLon;
  final double _mPerDegLon;
  static const double _mPerDegLat = 110574;

  (double, double) toLocal(double lat, double lon) =>
      ((lon - originLon) * _mPerDegLon, -(lat - originLat) * _mPerDegLat);

  (double, double) toLatLon(double x, double z) =>
      (originLat - z / _mPerDegLat, originLon + x / _mPerDegLon);
}

/// Heights on a regular grid in local metres. [heightAt] interpolates on the
/// same two triangles per cell that the terrain mesh uses, so anything draped
/// with it sits exactly on the rendered ground.
class GridTerrain {
  GridTerrain({
    required this.minX,
    required this.minZ,
    required this.spacing,
    double? spacingZ,
    required this.cols,
    required this.rows,
    required this.heights,
  }) : spacingZ = spacingZ ?? spacing;

  /// Grid step along x; [spacingZ] along z (defaults to the same). They can
  /// differ slightly so a district's grid ends exactly on its edges and
  /// neighbouring districts share their border vertices.
  final double minX, minZ, spacing;
  final double spacingZ;
  final int cols, rows; // vertex counts
  final Float64List heights; // rows * cols, row-major (z then x)

  double get maxX => minX + (cols - 1) * spacing;
  double get maxZ => minZ + (rows - 1) * spacingZ;

  double vertex(int i, int j) => heights[j * cols + i];

  double heightAt(double x, double z) {
    final fx = ((x - minX) / spacing).clamp(0.0, cols - 1.000001);
    final fz = ((z - minZ) / spacingZ).clamp(0.0, rows - 1.000001);
    final i = fx.floor(), j = fz.floor();
    final u = fx - i, v = fz - j;
    final h00 = vertex(i, j), h10 = vertex(i + 1, j);
    final h01 = vertex(i, j + 1), h11 = vertex(i + 1, j + 1);
    // Cells split along the (i,j)-(i+1,j+1) diagonal.
    return u >= v
        ? h00 + (h10 - h00) * u + (h11 - h10) * v
        : h00 + (h11 - h01) * u + (h01 - h00) * v;
  }
}
