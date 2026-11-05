import 'dart:typed_data';

import 'package:flutter_scene_practice/chongqing/city_data.dart';
import 'package:flutter_scene_practice/chongqing/walk_world.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// A 200 x 200 m slope rising 0.1 m per metre in x, with the river level at
/// 100 m and ground from 105 m up; a 20 x 20 m building in the middle; and a
/// bridge deck at 130 m crossing it along z.
WalkWorld _world() {
  const cols = 21, rows = 21, step = 10.0;
  final h = Float32List(cols * rows);
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      h[j * cols + i] = 105 + (i * step) * 0.1;
    }
  }
  final grid = TerrainGrid(-100, -100, step, step, cols, rows, h);
  final walls = Float32List.fromList([4, 160, -10, -10, 10, -10, 10, 10, -10, 10]);
  final decks = Float32List.fromList([2, 4, 50, 130, -100, 50, 130, 100]);
  return WalkWorld()..add(WalkData([grid], walls, decks, 100));
}

void main() {
  test('ground follows the terrain slope', () {
    final w = _world();
    expect(w.groundAt(-100, 0, 0), closeTo(105, 1e-6));
    expect(w.groundAt(0, 0, 0), closeTo(115, 1e-6));
    expect(w.groundAt(500, 0, 0), isNull); // outside the city
  });

  test('walls push the walker out and let it slide', () {
    final w = _world();
    final p = vm.Vector3(9.9, 115, 0); // just inside the east wall
    w.resolveWalls(p, 0.35);
    expect(p.x, closeTo(10.35, 1e-6));
    expect(p.z, closeTo(0, 1e-6));
  });

  test('bridge decks are walkable from above, ignored from below', () {
    final w = _world();
    // Standing on the deck: the deck wins over the terrain far below.
    expect(w.groundAt(50, 0, 130), closeTo(130, 1e-6));
    // Walking underneath: the deck is far overhead, so the terrain wins.
    expect(w.groundAt(50, 0, 120), closeTo(120, 1e-6));
  });

  test('the river is water', () {
    final w = _world();
    expect(w.isWater(99), isTrue);
    expect(w.isWater(110), isFalse);
  });
}
