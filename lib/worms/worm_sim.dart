import 'dart:math';
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

/// Axis-aligned solid box the worms collide with and can climb.
class SimBox {
  const SimBox(this.min, this.max);
  final (double, double, double) min;
  final (double, double, double) max;
}

/// A swarm of worms, each a Verlet chain of points, that chases a target.
///
/// Pure Dart (no rendering) so it can be stepped in tests. Positions are in
/// world units with +Y up and the ground at y = 0.
class WormSwarmSim {
  WormSwarmSim({
    this.wormCount = 160,
    this.pointsPerWorm = 16,
    this.segmentLength = 0.048,
    this.radius = 0.026,
    this.tailRadius = 0.011,
    this.arenaHalfX = 3.2,
    this.arenaHalfZ = 2.6,
    SimBox? bench,
    int seed = 7,
  }) : bench = bench ?? const SimBox((-0.8, 0, -0.5), (0.8, 0.55, 0.5)),
       _rng = Random(seed) {
    final n = wormCount * pointsPerWorm;
    pos = Float32List(n * 3);
    _prev = Float32List(n * 3);
    _contact = Uint8List(n);
    _normal = Float32List(n * 3);
    radii = Float32List(n);
    _phase = Float32List(wormCount);
    _orbit = Float32List(wormCount * 3);
    _next = Int32List(n);
    for (var w = 0; w < wormCount; w++) {
      _phase[w] = _rng.nextDouble() * 2 * pi;
      // Random offset inside a flattened sphere: where this worm's head
      // wants to sit relative to the target, so heads surround it.
      final a = _rng.nextDouble() * 2 * pi;
      final r = sqrt(_rng.nextDouble()) * 0.42;
      _orbit[w * 3] = cos(a) * r;
      _orbit[w * 3 + 1] = _rng.nextDouble() * 0.3;
      _orbit[w * 3 + 2] = sin(a) * r;
      // Spawn scattered around the arena, lying flat.
      final cx = (_rng.nextDouble() * 2 - 1) * (arenaHalfX - 0.8);
      final cz = (_rng.nextDouble() * 2 - 1) * (arenaHalfZ - 0.8);
      final heading = _rng.nextDouble() * 2 * pi;
      for (var p = 0; p < pointsPerWorm; p++) {
        final i = w * pointsPerWorm + p;
        final t = p / (pointsPerWorm - 1);
        radii[i] = radius + (tailRadius - radius) * (t * t);
        final x = cx + cos(heading) * p * segmentLength;
        final z = cz + sin(heading) * p * segmentLength;
        final y = radius + 0.02;
        pos[i * 3] = _prev[i * 3] = x;
        pos[i * 3 + 1] = _prev[i * 3 + 1] = y;
        pos[i * 3 + 2] = _prev[i * 3 + 2] = z;
      }
      _resolveWorld(w * pointsPerWorm, pointsPerWorm);
    }
    _prev.setAll(0, pos);
  }

  final int wormCount;
  final int pointsPerWorm;
  final double segmentLength;
  final double radius;
  final double tailRadius;
  final double arenaHalfX;
  final double arenaHalfZ;
  final SimBox bench;
  final Random _rng;

  /// Point positions, xyz interleaved, worm-major (worm 0 points first).
  late final Float32List pos;

  /// Collision radius of each point (tapers toward the tail).
  late final Float32List radii;

  late final Float32List _prev;
  late final Uint8List _contact; // 0 none, 1 world, 2 other worm
  late final Float32List _normal;
  late final Float32List _phase;
  late final Float32List _orbit;
  late final Int32List _next;
  final Int32List _cellHead = Int32List(_hashSize);

  static const int _hashSize = 8192;
  static const double substep = 1 / 120;
  static const int maxSubsteps = 4;

  static const double gravity = 9.8;
  static const double headSteer = 34;
  static const double wiggle = 11;
  static const double crawl = 16;
  static const double climb = 22;
  static const double airDamping = 0.995;
  static const double contactFriction = 0.86;
  static const double targetMaxSpeed = 1.1;

  /// Surface point the swarm is heading to (eases toward [targetGoal]).
  final vm.Vector3 target = vm.Vector3(0, 0, 1.4);

  /// Where the target is trying to get to.
  final vm.Vector3 targetGoal = vm.Vector3(0, 0, 1.4);

  double _time = 0;
  double _accumulator = 0;

  void setTargetGoal(vm.Vector3 goal) {
    targetGoal
      ..setFrom(goal)
      ..x = goal.x.clamp(-arenaHalfX + 0.2, arenaHalfX - 0.2)
      ..z = goal.z.clamp(-arenaHalfZ + 0.2, arenaHalfZ - 0.2);
  }

  /// Advances the simulation by [dt] seconds using fixed substeps.
  void step(double dt) {
    _accumulator = min(_accumulator + dt, substep * maxSubsteps);
    while (_accumulator >= substep) {
      _accumulator -= substep;
      _substep(substep);
    }
  }

  void _substep(double h) {
    _time += h;
    _moveTarget(h);
    _integrate(h);
    for (var k = 0; k < 3; k++) {
      _solveChains();
    }
    _collideWorms();
    for (var w = 0; w < wormCount; w++) {
      _resolveWorld(w * pointsPerWorm, pointsPerWorm);
    }
  }

  void _moveTarget(double h) {
    final d = targetGoal - target;
    final len = d.length;
    final maxStep = targetMaxSpeed * h;
    if (len > maxStep) {
      target.addScaled(d, maxStep / len);
    } else {
      target.setFrom(targetGoal);
    }
  }

  void _integrate(double h) {
    final h2 = h * h;
    final ppw = pointsPerWorm;
    for (var w = 0; w < wormCount; w++) {
      final base = w * ppw;
      for (var p = 0; p < ppw; p++) {
        final i = base + p;
        final ix = i * 3;
        final x = pos[ix], y = pos[ix + 1], z = pos[ix + 2];
        final c = _contact[i];
        final damp = c != 0 ? contactFriction : airDamping;
        var vx = (x - _prev[ix]) * damp;
        var vy = (y - _prev[ix + 1]) * damp;
        var vz = (z - _prev[ix + 2]) * damp;

        var ax = 0.0, ay = -gravity, az = 0.0;
        final nx = _normal[ix], ny = _normal[ix + 1], nz = _normal[ix + 2];
        final onWall = c == 1 && ny.abs() < 0.5;

        if (p == 0) {
          // Head: steer to its slot around the target, slithering sideways.
          final gx = target.x + _orbit[w * 3] - x;
          final gy = target.y + _orbit[w * 3 + 1] - y;
          final gz = target.z + _orbit[w * 3 + 2] - z;
          final gl = sqrt(gx * gx + gz * gz) + 1e-6;
          final pull = min(1.0, gl / 0.25);
          ax += gx / gl * headSteer * pull;
          az += gz / gl * headSteer * pull;
          final s = sin(_time * 6 + _phase[w]) * wiggle;
          ax += -gz / gl * s;
          az += gx / gl * s;
          if (c != 0 && gy > 0.03) {
            ay += onWall ? gravity + climb : climb * 0.6;
          }
          if (onWall) {
            // Keep the head pressed against the wall while climbing.
            ax -= nx * 4;
            az -= nz * 4;
          }
        } else if (c != 0) {
          // Body touching something: crawl after the point ahead.
          final jx = (i - 1) * 3;
          final dx = pos[jx] - x, dy = pos[jx + 1] - y, dz = pos[jx + 2] - z;
          final dl = sqrt(dx * dx + dy * dy + dz * dz) + 1e-6;
          ax += dx / dl * crawl;
          ay += dy / dl * crawl;
          az += dz / dl * crawl;
          if (onWall) {
            ay += gravity * 0.95; // grip
            ax -= nx * 3;
            az -= nz * 3;
          }
        }

        _prev[ix] = x;
        _prev[ix + 1] = y;
        _prev[ix + 2] = z;
        pos[ix] = x + vx + ax * h2;
        pos[ix + 1] = y + vy + ay * h2;
        pos[ix + 2] = z + vz + az * h2;
        _contact[i] = 0;
      }
    }
  }

  void _solveChains() {
    final ppw = pointsPerWorm;
    final bendRest = segmentLength * 1.85;
    for (var w = 0; w < wormCount; w++) {
      final base = w * ppw;
      for (var p = 0; p < ppw - 1; p++) {
        _distance(base + p, base + p + 1, segmentLength, 1.0);
      }
      for (var p = 0; p < ppw - 2; p++) {
        _distance(base + p, base + p + 2, bendRest, 0.35, minOnly: true);
      }
    }
  }

  void _distance(
    int a,
    int b,
    double rest,
    double stiffness, {
    bool minOnly = false,
  }) {
    final ia = a * 3, ib = b * 3;
    final dx = pos[ib] - pos[ia];
    final dy = pos[ib + 1] - pos[ia + 1];
    final dz = pos[ib + 2] - pos[ia + 2];
    final d = sqrt(dx * dx + dy * dy + dz * dz);
    if (d < 1e-7) return;
    if (minOnly && d >= rest) return;
    final k = (d - rest) / d * 0.5 * stiffness;
    pos[ia] += dx * k;
    pos[ia + 1] += dy * k;
    pos[ia + 2] += dz * k;
    pos[ib] -= dx * k;
    pos[ib + 1] -= dy * k;
    pos[ib + 2] -= dz * k;
  }

  int _cellKey(int cx, int cy, int cz) =>
      ((cx * 73856093) ^ (cy * 19349663) ^ (cz * 83492791)) & (_hashSize - 1);

  void _collideWorms() {
    final n = wormCount * pointsPerWorm;
    final cell = radius * 2;
    final inv = 1 / cell;
    _cellHead.fillRange(0, _hashSize, -1);
    for (var i = 0; i < n; i++) {
      final key = _cellKey(
        (pos[i * 3] * inv).floor(),
        (pos[i * 3 + 1] * inv).floor(),
        (pos[i * 3 + 2] * inv).floor(),
      );
      _next[i] = _cellHead[key];
      _cellHead[key] = i;
    }
    final ppw = pointsPerWorm;
    for (var i = 0; i < n; i++) {
      final ix = i * 3;
      final cx = (pos[ix] * inv).floor();
      final cy = (pos[ix + 1] * inv).floor();
      final cz = (pos[ix + 2] * inv).floor();
      final wi = i ~/ ppw;
      for (var ox = -1; ox <= 1; ox++) {
        for (var oy = -1; oy <= 1; oy++) {
          for (var oz = -1; oz <= 1; oz++) {
            var j = _cellHead[_cellKey(cx + ox, cy + oy, cz + oz)];
            while (j >= 0) {
              // Each pair once; skip close neighbours on the same worm.
              if (j > i && !(j ~/ ppw == wi && j - i <= 2)) {
                _separate(i, j);
              }
              j = _next[j];
            }
          }
        }
      }
    }
  }

  void _separate(int i, int j) {
    final ix = i * 3, jx = j * 3;
    final dx = pos[jx] - pos[ix];
    final dy = pos[jx + 1] - pos[ix + 1];
    final dz = pos[jx + 2] - pos[ix + 2];
    final minD = radii[i] + radii[j];
    final d2 = dx * dx + dy * dy + dz * dz;
    if (d2 >= minD * minD || d2 < 1e-12) return;
    final d = sqrt(d2);
    final k = (minD - d) / d * 0.5;
    pos[ix] -= dx * k;
    pos[ix + 1] -= dy * k;
    pos[ix + 2] -= dz * k;
    pos[jx] += dx * k;
    pos[jx + 1] += dy * k;
    pos[jx + 2] += dz * k;
    // Resting on another worm counts as support, so worms crawl over
    // each other and the pile grows into one mass.
    if (_contact[i] == 0) _contact[i] = 2;
    if (_contact[j] == 0) _contact[j] = 2;
  }

  void _resolveWorld(int start, int count) {
    final (bx0, by0, bz0) = bench.min;
    final (bx1, by1, bz1) = bench.max;
    for (var i = start; i < start + count; i++) {
      final ix = i * 3;
      final r = radii[i];
      var x = pos[ix], y = pos[ix + 1], z = pos[ix + 2];

      // Bench: push out of the box grown by r along the shallowest axis.
      if (x > bx0 - r &&
          x < bx1 + r &&
          y > by0 - r &&
          y < by1 + r &&
          z > bz0 - r &&
          z < bz1 + r) {
        final pxMin = x - (bx0 - r), pxMax = (bx1 + r) - x;
        final pyMax = (by1 + r) - y;
        final pzMin = z - (bz0 - r), pzMax = (bz1 + r) - z;
        var best = pyMax;
        var axis = 1; // +y
        if (pxMin < best) (best, axis) = (pxMin, 0);
        if (pxMax < best) (best, axis) = (pxMax, 2);
        if (pzMin < best) (best, axis) = (pzMin, 3);
        if (pzMax < best) (best, axis) = (pzMax, 4);
        _normal[ix] = _normal[ix + 1] = _normal[ix + 2] = 0;
        switch (axis) {
          case 0:
            x = bx0 - r;
            _normal[ix] = -1;
          case 2:
            x = bx1 + r;
            _normal[ix] = 1;
          case 3:
            z = bz0 - r;
            _normal[ix + 2] = -1;
          case 4:
            z = bz1 + r;
            _normal[ix + 2] = 1;
          default:
            y = by1 + r;
            _normal[ix + 1] = 1;
        }
        _contact[i] = 1;
      }

      if (y < r) {
        y = r;
        _normal[ix] = 0;
        _normal[ix + 1] = 1;
        _normal[ix + 2] = 0;
        _contact[i] = 1;
      }

      x = x.clamp(-arenaHalfX, arenaHalfX);
      z = z.clamp(-arenaHalfZ, arenaHalfZ);
      pos[ix] = x;
      pos[ix + 1] = y;
      pos[ix + 2] = z;
    }
  }

  /// Top surface height of the bench.
  double get benchTop => bench.max.$2;

  /// True when (x, z) lies over the bench top.
  bool overBench(double x, double z) =>
      x >= bench.min.$1 &&
      x <= bench.max.$1 &&
      z >= bench.min.$3 &&
      z <= bench.max.$3;
}
