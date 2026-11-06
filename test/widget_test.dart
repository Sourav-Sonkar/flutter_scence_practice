import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_scene_practice/chongqing/city_view.dart';
import 'package:flutter_scene_practice/main.dart';

void main() {
  // Flutter GPU needs Impeller, which `flutter test` does not run, so the
  // city itself can't be pumped here. Check the app's wiring instead.
  testWidgets('App opens on the Chongqing city view', (tester) async {
    late Widget app;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          app = const MyApp().build(context);
          return const SizedBox();
        },
      ),
    );
    final home = (app as MaterialApp).home! as Scaffold;
    expect(home.body, isA<CityView>());
  });
}
