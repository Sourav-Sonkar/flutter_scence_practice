import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart' hide Material;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene_practice/main.dart';
import 'package:vector_math/vector_math.dart' as vm;

final Geometry plateGeometry = CylinderGeometry(
  bottomRadius: 1.9,
  topRadius: 1.9,
  height: 0.1,
);
final Geometry cakeGeometry = CylinderGeometry(
  bottomRadius: 1.4,
  topRadius: 1.4,
  height: 0.9,
);
final Geometry candleGeometry = CylinderGeometry(
  bottomRadius: 0.06,
  topRadius: 0.06,
  height: 0.5,
);
final Geometry flameGeometry = SphereGeometry(radius: 0.08);

PhysicallyBasedMaterial pbr(
  Color color, {
  double metallic = 0.0,
  double roughness = 0.45,
}) => PhysicallyBasedMaterial()
  ..baseColorFactor = vm.Vector4(color.r, color.g, color.b, 1.0)
  ..metallicFactor = metallic
  ..roughnessFactor = roughness;

final Material plateMaterial = pbr(
  const Color(0xff17181d),
  metallic: 0.85,
  roughness: 0.3,
);
final Material candleMaterial = pbr(const Color(0xfff0ead6), roughness: 0.6);
final List<Material> frostings = [
  pbr(const Color(0xfff3e3c0)), // Vanilla
  pbr(const Color(0xffec9bb0)), // Strawberry
  pbr(const Color(0xffa7c47a)), // Matcha
];
final Material flameMaterial = UnlitMaterial()
  ..baseColorFactor = vm.Vector4(2.6, 0.62, 0.08, 1.0);

final keyLight = PointLightComponent(
  PointLight(color: vm.Vector3(1.0, 0.93, 0.82), intensity: 80, range: 50),
);
final fillLight = PointLightComponent(
  PointLight(color: vm.Vector3(0.55, 0.68, 1.0), intensity: 30, range: 50),
);
final flameLights = List.generate(
  12,
  (_) => PointLightComponent(
    PointLight(color: vm.Vector3(1.0, 0.5, 0.18), intensity: 6, range: 1.3),
  ),
);

vm.Vector3 candlePosition(int index, int count) {
  final angle = 2 * pi * index / count;
  return vm.Vector3(cos(angle) * 0.9, 1.0, sin(angle) * 0.9);
}

class CakeDemo extends StatelessWidget {
  const CakeDemo({super.key});

  @override
  Widget build(BuildContext context) {
    int candles = 5;
    bool lit = true;
    int flavor = 0;
    return SceneView.declarative(
      exposure: 1.4,
      camera: PerspectiveCamera(
        position: vm.Vector3(0, 3.4, 6.2),
        target: vm.Vector3(0, 0.55, 0),
      ),
      children: [
        //SceneNode(position: vm.Vector3(3.5, 5, 4), components: [keyLight]),
        //SceneNode(position: vm.Vector3(-4, 2.5, -2.5), components: [fillLight]),
        SceneNode(
          components: [SpinComponent(0.5)],
          children: [
            SceneMesh(
              geometry: plateGeometry,
              material: plateMaterial,
              position: vm.Vector3(0, 0.05, 0),
            ),
            SceneMesh(
              geometry: cakeGeometry,
              material: frostings[flavor],
              position: vm.Vector3(0, 0.55, 0),
            ),
            for (var i = 0; i < candles; i++)
              SceneNode(
                key: ValueKey(i),
                position: candlePosition(i, candles),
                children: [
                  SceneMesh(
                    geometry: candleGeometry,
                    material: candleMaterial,
                    position: vm.Vector3(0, 0.25, 0),
                  ),
                  if (lit)
                    SceneMesh(
                      geometry: flameGeometry,
                      material: flameMaterial,
                      position: vm.Vector3(0, 0.58, 0),
                      components: [flameLights[i]],
                    ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}
