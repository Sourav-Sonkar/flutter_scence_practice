import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Material;
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';
import 'city_look.dart';
import 'detail_chunks.dart';
import 'facade_textures.dart';
import 'movers.dart';
import 'street_lamps.dart';

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
  late final DetailChunks _rooftops;
  late final DetailChunks _vegetation;
  late final CityLook _look;
  TimeOfDayMode _time = TimeOfDayMode.day;
  Weather _weather = Weather.clear;
  final ValueNotifier<double> _clock = ValueNotifier(0);
  late final Movers _movers;
  RidePath? _ride;
  double _rideS = 0;
  double _rideDir = 1;

  _Mode _mode = _Mode.diorama;
  // Decided from the platform and screen size on first layout: laptops and
  // desktops (including the web on a big screen) start on High, phones and
  // narrow browser windows on Low.
  Quality? _quality;
  Quality get _q => _quality ?? Quality.low;

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
    _clock.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_quality == null) {
      final wide = MediaQuery.sizeOf(context).shortestSide >= 600;
      final android =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
      _quality = kIsWeb
          ? (wide ? Quality.medium : Quality.low)
          : (android ? Quality.low : Quality.high);
      if (_city != null) _applyLook();
    }
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
    final homeTex = FacadeTextures.residential(),
        glassTex = FacadeTextures.glass();
    final homes = _pbr(0.75)
      ..baseColorTexture = homeTex.color
      ..emissiveTexture = homeTex.lights;
    // Glass towers: smoother so they pick up the sky.
    final towers = _pbr(0.4)
      ..metallicFactor = 0.1
      ..baseColorTexture = glassTex.color
      ..emissiveTexture = glassTex.lights;
    final roads = _pbr(0.9);
    final materials = <String, Material>{
      'terrain': _pbr(0.95),
      'buildings': homes,
      'towers': towers,
      'roads': roads,
      'structures': _pbr(0.6),
    };
    city.layers.forEach((name, geometry) {
      _scene.add(
        Node(name: name, mesh: Mesh(geometry, materials[name] ?? _pbr(0.8)))
          ..frustumCulled = false,
      );
    });

    // Small details in map tiles that only draw near the camera. Trees
    // carry the green look, so they stay visible much farther out than
    // rooftop clutter.
    const plants = {
      'treeHuangge',
      'treeCamphor',
      'treeBanyan',
      'treeGinkgo',
      'shrub',
      'bougainvillea',
    };
    _vegetation = DetailChunks(
      city.details.where((d) => plants.contains(d.type)).toList(),
      tileSize: 300,
      showWithin: 2400,
    );
    _rooftops = DetailChunks(
      city.details.where((d) => !plants.contains(d.type)).toList(),
    );
    _scene
      ..add(_vegetation.root)
      ..add(_rooftops.root);
    final lamps = buildStreetLamps(city.traffic);
    _scene.add(lamps);
    _movers = Movers(city);
    _scene.add(_movers.root);

    // River surface, a little larger than the district so edges stay wet.
    final size = city.bounds.max - city.bounds.min;
    final water = _pbr(0.06, vm.Vector4(0.12, 0.18, 0.19, 1));
    _look = CityLook(
      scene: _scene,
      homes: homes,
      towers: towers,
      roads: roads,
      water: water,
      lamps: lamps,
    );
    _scene.add(
      Node(
          name: 'water',
          mesh: Mesh(
            PlaneGeometry(width: size.x + 400, depth: size.y + 400),
            water,
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
    _applyLook();
  }

  void _applyLook() {
    _look.apply(time: _time, weather: _weather, quality: _q);
    // Low keeps trees to a shorter range to save phones some work.
    _vegetation.showWithin = _q == Quality.low ? 1300 : 2400;
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
    _clock.value += dt;
    final eye = _mode == _Mode.diorama
        ? _orbitNode.globalTransform.getTranslation()
        : _rideNode.globalTransform.getTranslation();
    _vegetation.update(eye);
    _rooftops.update(
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
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: _look.backdrop,
            ),
          ),
        ),
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
        if (_weather == Weather.rain)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _RainPainter(
                  _clock,
                  night: _time == TimeOfDayMode.night,
                ),
              ),
            ),
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

  // Solid light buttons, so they stay readable over a night or fog sky.
  static final ButtonStyle _barButtonStyle = SegmentedButton.styleFrom(
    backgroundColor: Colors.white.withValues(alpha: 0.88),
    selectedBackgroundColor: const Color(0xffe2d9ff),
  );

  Widget _topBar(CityData city) {
    final ride = _ride;
    final wide = MediaQuery.sizeOf(context).width >= 900;
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
            style: _barButtonStyle,
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
          SegmentedButton<TimeOfDayMode>(
            style: _barButtonStyle,
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: TimeOfDayMode.day,
                icon: const Icon(Icons.wb_sunny_outlined),
                label: wide ? const Text('Day') : null,
                tooltip: 'Day',
              ),
              ButtonSegment(
                value: TimeOfDayMode.sunset,
                icon: const Icon(Icons.wb_twilight),
                label: wide ? const Text('Sunset') : null,
                tooltip: 'Sunset',
              ),
              ButtonSegment(
                value: TimeOfDayMode.night,
                icon: const Icon(Icons.nightlight_outlined),
                label: wide ? const Text('Night') : null,
                tooltip: 'Night',
              ),
            ],
            selected: {_time},
            onSelectionChanged: (s) {
              setState(() => _time = s.first);
              _applyLook();
            },
          ),
          SegmentedButton<Weather>(
            style: _barButtonStyle,
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: Weather.clear,
                icon: const Icon(Icons.brightness_7_outlined),
                label: wide ? const Text('Clear') : null,
                tooltip: 'Clear',
              ),
              ButtonSegment(
                value: Weather.fog,
                icon: const Icon(Icons.foggy),
                label: wide ? const Text('Fog') : null,
                tooltip: 'Fog',
              ),
              ButtonSegment(
                value: Weather.rain,
                icon: const Icon(Icons.water_drop_outlined),
                label: wide ? const Text('Rain') : null,
                tooltip: 'Rain',
              ),
            ],
            selected: {_weather},
            onSelectionChanged: (s) {
              setState(() => _weather = s.first);
              _applyLook();
            },
          ),
          FilledButton.tonal(
            onPressed: () {
              setState(
                () => _quality =
                    Quality.values[(_q.index + 1) % Quality.values.length],
              );
              _applyLook();
            },
            child: Text(
              'Quality: ${switch (_q) {
                Quality.low => 'Low',
                Quality.medium => 'Medium',
                Quality.high => 'High',
              }}',
            ),
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

/// Falling rain streaks drawn over the 3D view.
class _RainPainter extends CustomPainter {
  _RainPainter(this.clock, {required this.night}) : super(repaint: clock);

  final ValueNotifier<double> clock;
  final bool night;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (night ? const Color(0xff9fb4d8) : Colors.white).withValues(
        alpha: 0.32,
      )
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final t = clock.value;
    for (final (x, y, speed) in RainPainter.drops) {
      final py = ((y + t * speed * 1.6) % 1.0) * (size.height + 60) - 30;
      final px = (x * size.width + py * 0.12) % size.width;
      canvas.drawLine(Offset(px, py), Offset(px - 4, py - 22 * speed), paint);
    }
  }

  @override
  bool shouldRepaint(_RainPainter old) => old.night != night;
}
