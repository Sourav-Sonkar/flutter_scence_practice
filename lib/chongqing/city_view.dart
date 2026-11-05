import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Material;
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';
import 'detail_chunks.dart';
import 'facade_textures.dart';
import 'movers.dart';

enum _Mode { diorama, ride }

/// A miniature district of Chongqing built from OpenStreetMap data.
/// Diorama mode orbits the city; ride mode follows a cableway or monorail.
class CityView extends StatefulWidget {
  const CityView({super.key, this.district = 'yuzhong_tip'});

  final String district;

  @override
  State<CityView> createState() => _CityViewState();
}

class _CityViewState extends State<CityView> {
  final Scene _scene = Scene();
  CityData? _city;
  Object? _error;

  // Diorama camera: a node with a camera and an orbit controller.
  final Node _orbitNode = Node(name: 'orbit camera');
  late final CameraComponent _orbitCamera;
  late final OrbitCameraController _orbit;

  // Ride camera, placed by hand each frame.
  final Node _rideNode = Node(name: 'ride camera');
  late final CameraComponent _rideCamera;
  double _rideYaw = 0, _ridePitch = -0.15;

  final List<Node> _cabins = [];
  late final DetailChunks _details;
  late final Movers _movers;
  RidePath? _ride;
  double _rideS = 0;
  double _rideDir = 1;

  _Mode _mode = _Mode.diorama;
  bool _highQuality =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  // Frame stats for the overlay.
  final ValueNotifier<({int fps, double ui, double gpu})> _stats =
      ValueNotifier((fps: 0, ui: 0, gpu: 0));
  int _frames = 0;
  double _frameTime = 0, _uiMs = 0, _gpuMs = 0;

  static const double _rideSpeed = 6; // m/s, roughly a real cable car

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _load();
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _stats.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await Scene.initializeStaticResources();
      final city = await CityData.load(widget.district);
      _build(city);
      if (mounted) setState(() => _city = city);
    } catch (e, s) {
      debugPrint('City load failed: $e\n$s');
      if (mounted) setState(() => _error = e);
    }
  }

  PhysicallyBasedMaterial _pbr(double roughness, [vm.Vector4? color]) =>
      PhysicallyBasedMaterial()
        ..baseColorFactor = color ?? vm.Vector4(1, 1, 1, 1)
        ..metallicFactor = 0
        ..roughnessFactor = roughness;

  void _build(CityData city) {
    final materials = <String, Material>{
      'terrain': _pbr(0.95),
      'buildings': _pbr(0.75)..baseColorTexture = FacadeTextures.residential(),
      // Glass towers: smoother so they pick up the sky.
      'towers': _pbr(0.4)
        ..metallicFactor = 0.1
        ..baseColorTexture = FacadeTextures.glass(),
      'roads': _pbr(0.9),
      'structures': _pbr(0.6),
    };
    city.layers.forEach((name, geometry) {
      _scene.add(
        Node(name: name, mesh: Mesh(geometry, materials[name] ?? _pbr(0.8)))
          ..frustumCulled = false,
      );
    });

    // Rooftop items, grouped into map tiles that only show up close.
    _details = DetailChunks(city.details);
    _scene.add(_details.root);
    _movers = Movers(city);
    _scene.add(_movers.root);

    // River surface, a little larger than the district so edges stay wet.
    final size = city.bounds.max - city.bounds.min;
    _scene.add(
      Node(
          name: 'water',
          mesh: Mesh(
            PlaneGeometry(width: size.x + 400, depth: size.y + 400),
            _pbr(0.06, vm.Vector4(0.12, 0.18, 0.19, 1)),
          ),
        )
        ..position = vm.Vector3(
          city.center.x,
          city.riverLevel + 0.6,
          city.center.y,
        )
        ..castsShadows = false,
    );

    // Diorama camera, framing the district from the south-west.
    _orbitCamera = CameraComponent(
      projection: PerspectiveProjection(near: 2, far: 9000),
    );
    _orbit = OrbitCameraController(
      target: vm.Vector3(city.center.x, city.riverLevel + 40, city.center.y),
      distance: 1150,
      // From the south-east, looking up the peninsula from the confluence.
      // A high angle is what makes tilt-shift photos read as models.
      azimuth: -2.4,
      polar: 0.72,
      minDistance: 120,
      maxDistance: 3200,
      minPolar: 0.12,
      maxPolar: 1.45,
      smoothing: 0.2,
    );
    _orbitNode
      ..addComponent(_orbitCamera)
      ..addComponent(_orbit);
    _scene.add(_orbitNode);

    _rideCamera = CameraComponent(
      projection: PerspectiveProjection(
        fovRadiansY: 60 * vm.degrees2Radians,
        near: 0.5,
        far: 9000,
      ),
    );
    _rideNode.addComponent(_rideCamera);
    _scene.add(_rideNode);

    // Cabins (or train cars) that run along the first ride path.
    if (city.rides.isNotEmpty) {
      _ride = city.rides.first;
      final cabin = Mesh(
        CuboidGeometry(vm.Vector3(3.2, 2.8, 4.2)),
        _pbr(0.4, vm.Vector4(0.75, 0.08, 0.06, 1)),
      );
      for (var i = 0; i < 2; i++) {
        final n = Node(name: 'cabin $i', mesh: cabin);
        _cabins.add(n);
        _scene.add(n);
      }
    }
    _applyQuality();
  }

  // Late-afternoon sun from the south-west: warm light, long shadows.
  static final vm.Vector3 _sunDir = vm.Vector3(0.62, -0.5, 0.6)..normalize();

  void _applyQuality() {
    final high = _highQuality;
    _scene.directionalLight = DirectionalLight(
      direction: _sunDir,
      color: vm.Vector3(1.0, 0.9, 0.76),
      intensity: 4.2,
      castsShadow: true,
      shadowMaxDistance: high ? 3000 : 1800,
      shadowCascadeCount: high ? 4 : 2,
      shadowMapResolution: high ? 2048 : 1024,
      shadowDepthBias: 0.4,
      shadowNormalBias: 0.6,
    );
    _scene.skybox ??= Skybox(
      GradientSkySource(
        zenithColor: vm.Vector3(0.16, 0.38, 0.78),
        horizonColor: vm.Vector3(0.78, 0.86, 0.95),
        groundColor: vm.Vector3(0.5, 0.52, 0.5),
        sunDirection: -_sunDir,
        sunColor: vm.Vector3(4, 3.4, 2.6),
      ),
    );
    _scene.environmentSettings = EnvironmentSettings(
      toneMapping: ToneMappingMode.aces,
      exposure: 1.05,
      environmentIntensity: 0.75,
      // A painted-model grade: richer colour, a touch warm and contrasty.
      colorGradingEnabled: true,
      saturation: 1.35,
      contrast: 1.1,
      temperature: 0.06,
      // Light blue haze only far away; heavy fog kills the miniature look.
      fogEnabled: true,
      fogMode: FogMode.exponential,
      fogColor: vm.Vector3(0.74, 0.83, 0.94),
      fogDensity: 0.00005,
      ambientOcclusionEnabled: high,
      ambientOcclusionMethod: AmbientOcclusionMethod.groundTruth,
      ambientOcclusionRadius: 6,
      ambientOcclusionIntensity: 1.2,
      screenSpaceReflectionsEnabled: high,
      screenSpaceReflectionsMaxDistance: 600,
      bloomEnabled: high,
      bloomThreshold: 2.2,
      bloomIntensity: 0.12,
      // Tilt-shift: a narrow focus band at the orbit target, strong blur
      // above and below it, makes the real city read as a model.
      depthOfFieldEnabled: high,
      depthOfFieldFStop: 0.7,
      depthOfFieldBlurScale: 40,
      depthOfFieldMaxForegroundBlur: 28,
      depthOfFieldMaxBackgroundBlur: 28,
      vignetteEnabled: true,
      vignetteIntensity: 0.3,
    );
    _scene.renderScale = high ? 1.0 : 0.75;
    _scene.antiAliasingMode = high
        ? AntiAliasingMode.auto
        : AntiAliasingMode.fxaa;
  }

  void _onTick(Duration elapsed, double frameDt) {
    final city = _city;
    if (city == null) return;
    _frames++;
    _frameTime += frameDt;
    final dt = min(frameDt, 0.1);

    // Keep the orbit target inside the district.
    final t = _orbit.target;
    final cx = t.x.clamp(city.bounds.min.x, city.bounds.max.x);
    final cz = t.z.clamp(city.bounds.min.y, city.bounds.max.y);
    if (cx != t.x || cz != t.z) _orbit.target = vm.Vector3(cx, t.y, cz);

    _advanceRide(dt);
    _movers.update(dt, showCars: _mode == _Mode.ride || _orbit.distance < 900);
    _details.update(
      _mode == _Mode.diorama
          ? _orbitNode.globalTransform.getTranslation()
          : _rideNode.globalTransform.getTranslation(),
    );
    if (_mode == _Mode.diorama) {
      _scene.depthOfField.focusDistance = _orbit.distance;
    } else {
      _scene.depthOfField.focusDistance = 400;
    }

    if (_frameTime >= 0.25) {
      _stats.value = (
        fps: (_frames / _frameTime).round(),
        ui: _uiMs,
        gpu: _gpuMs,
      );
      _frames = 0;
      _frameTime = 0;
    }
  }

  void _advanceRide(double dt) {
    final ride = _ride;
    if (ride == null) return;
    _rideS += _rideDir * _rideSpeed * dt;
    if (_rideS >= ride.length || _rideS <= 0) {
      _rideS = _rideS.clamp(0.0, ride.length);
      _rideDir = -_rideDir;
    }
    // Two cabins pass each other, like the real cableway.
    for (var i = 0; i < _cabins.length; i++) {
      final s = i == 0 ? _rideS : ride.length - _rideS;
      final (p, fwd) = ride.sample(s);
      final dir = i == 0 ? fwd * _rideDir : fwd * -_rideDir;
      _cabins[i].globalTransform = vm.Matrix4.compose(
        p,
        vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), atan2(dir.x, dir.z)),
        vm.Vector3.all(1),
      );
    }
    if (_mode == _Mode.ride) {
      final (p, fwd) = ride.sample(_rideS);
      final heading = atan2(fwd.x * _rideDir, fwd.z * _rideDir) + _rideYaw;
      final eye =
          p +
          vm.Vector3(0, 0.6, 0) +
          vm.Vector3(sin(heading), 0, cos(heading)) * 1.4;
      final look = vm.Vector3(
        sin(heading) * cos(_ridePitch),
        sin(_ridePitch),
        cos(heading) * cos(_ridePitch),
      );
      _rideNode.lookAtFrom(eye, eye + look);
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _uiMs = _uiMs * 0.8 + t.buildDuration.inMicroseconds / 1000 * 0.2;
      _gpuMs = _gpuMs * 0.8 + t.rasterDuration.inMicroseconds / 1000 * 0.2;
    }
  }

  void _goTo(Landmark l) {
    setState(() => _mode = _Mode.diorama);
    _orbit
      ..target = vm.Vector3(l.top.x, l.ground + l.height * 0.45, l.top.z)
      ..dollyBy(
        log(_orbit.distance / max(260.0, l.height * 2.4)) / _orbit.dollySpeed,
      );
  }

  @override
  Widget build(BuildContext context) {
    final city = _city;
    if (_error != null) {
      return Center(child: Text('Could not load the city: $_error'));
    }
    if (city == null) {
      return const ColoredBox(
        color: Color(0xff1b1d22),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final camera = _mode == _Mode.diorama
        ? _orbitCamera.toCamera()
        : _rideCamera.toCamera();
    final view = SceneView(_scene, camera: camera, onTick: _onTick);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_mode == _Mode.diorama)
          CameraControls(controller: _orbit, child: view)
        else
          GestureDetector(
            onPanUpdate: (d) => setState(() {
              _rideYaw -= d.delta.dx * 0.005;
              _ridePitch = (_ridePitch - d.delta.dy * 0.005).clamp(-1.2, 0.8);
            }),
            onDoubleTap: () => setState(() {
              _rideYaw = 0;
              _ridePitch = -0.15;
            }),
            child: view,
          ),
        SafeArea(child: _topBar(city)),
        if (_mode == _Mode.diorama)
          Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: _landmarkStrip(city),
          ),
        Positioned(left: 12, bottom: 8, child: _attribution(city)),
        Positioned(right: 12, bottom: 8, child: _statsText()),
      ],
    );
  }

  Widget _topBar(CityData city) {
    final ride = _ride;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            city.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              shadows: [Shadow(blurRadius: 6)],
            ),
          ),
          SegmentedButton<_Mode>(
            segments: [
              const ButtonSegment(
                value: _Mode.diorama,
                icon: Icon(Icons.view_in_ar),
                label: Text('Diorama'),
              ),
              ButtonSegment(
                value: _Mode.ride,
                icon: const Icon(Icons.airline_seat_recline_normal),
                label: Text(ride == null ? 'Ride' : 'Ride ${ride.kind}'),
                enabled: ride != null,
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          FilledButton.tonal(
            onPressed: () {
              setState(() => _highQuality = !_highQuality);
              _applyQuality();
            },
            child: Text(_highQuality ? 'Quality: High' : 'Quality: Low'),
          ),
        ],
      ),
    );
  }

  Widget _landmarkStrip(CityData city) => SizedBox(
    height: 40,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: city.landmarks.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, i) {
        final l = city.landmarks[i];
        return ActionChip(
          avatar: const Icon(Icons.location_city, size: 18),
          label: Text('${l.name} · ${l.height.round()} m'),
          onPressed: () => _goTo(l),
        );
      },
    ),
  );

  Widget _attribution(CityData city) => Text(
    '© OpenStreetMap contributors',
    style: const TextStyle(
      color: Colors.white70,
      fontSize: 11,
      shadows: [Shadow(blurRadius: 4)],
    ),
  );

  Widget _statsText() => IgnorePointer(
    child: ValueListenableBuilder(
      valueListenable: _stats,
      builder: (context, s, _) => Text(
        '${s.fps} FPS · ui ${s.ui.toStringAsFixed(1)} ms · gpu ${s.gpu.toStringAsFixed(1)} ms',
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 11,
          shadows: [Shadow(blurRadius: 4)],
        ),
      ),
    ),
  );
}
