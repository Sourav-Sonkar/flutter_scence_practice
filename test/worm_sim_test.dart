import 'dart:math';

import 'package:flutter_scene_practice/worms/worm_sim.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

double _headDistance(WormSwarmSim sim) {
  var total = 0.0;
  for (var w = 0; w < sim.wormCount; w++) {
    final i = w * sim.pointsPerWorm * 3;
    final dx = sim.pos[i] - sim.target.x, dz = sim.pos[i + 2] - sim.target.z;
    total += sqrt(dx * dx + dz * dz);
  }
  return total / sim.wormCount;
}

void _run(WormSwarmSim sim, double seconds) {
  for (var t = 0.0; t < seconds; t += 1 / 60) {
    sim.step(1 / 60);
  }
}

void main() {
  test('segments keep their length', () {
    final sim = WormSwarmSim(wormCount: 40);
    _run(sim, 5);
    for (var w = 0; w < sim.wormCount; w++) {
      for (var p = 0; p < sim.pointsPerWorm - 1; p++) {
        final a = (w * sim.pointsPerWorm + p) * 3;
        final d = sqrt(
          pow(sim.pos[a + 3] - sim.pos[a], 2) +
              pow(sim.pos[a + 4] - sim.pos[a + 1], 2) +
              pow(sim.pos[a + 5] - sim.pos[a + 2], 2),
        );
        expect(d, closeTo(sim.segmentLength, sim.segmentLength * 0.15));
      }
    }
  });

  test('points stay above ground and out of the bench', () {
    final sim = WormSwarmSim(wormCount: 40);
    sim.setTargetGoal(vm.Vector3(0, sim.benchTop + 0.1, 0));
    _run(sim, 8);
    final (bx0, _, bz0) = sim.bench.min;
    final (bx1, by1, bz1) = sim.bench.max;
    for (var i = 0; i < sim.pos.length; i += 3) {
      final x = sim.pos[i], y = sim.pos[i + 1], z = sim.pos[i + 2];
      expect(y, greaterThan(0));
      final inside =
          x > bx0 + 0.01 &&
          x < bx1 - 0.01 &&
          z > bz0 + 0.01 &&
          z < bz1 - 0.01 &&
          y < by1 - 0.01;
      expect(inside, isFalse, reason: 'point inside bench at $x,$y,$z');
    }
  });

  test('swarm follows the target', () {
    final sim = WormSwarmSim(wormCount: 40);
    sim.setTargetGoal(vm.Vector3(2.4, 0.1, 1.8));
    _run(sim, 1);
    final before = _headDistance(sim);
    _run(sim, 10);
    expect(_headDistance(sim), lessThan(before * 0.5));
  });

  test('worms climb onto the bench when the target is on top', () {
    final sim = WormSwarmSim(wormCount: 40);
    sim.setTargetGoal(vm.Vector3(0, sim.benchTop + 0.1, 0));
    _run(sim, 15);
    var onTop = 0;
    for (var w = 0; w < sim.wormCount; w++) {
      final i = w * sim.pointsPerWorm * 3;
      if (sim.pos[i + 1] > sim.benchTop - 0.01 &&
          sim.overBench(sim.pos[i], sim.pos[i + 2])) {
        onTop++;
      }
    }
    expect(onTop, greaterThan(sim.wormCount ~/ 4));
  });
}
