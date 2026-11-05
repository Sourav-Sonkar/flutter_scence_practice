import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Material;
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';
import 'city_look.dart';
import 'clouds.dart';
import 'crowns.dart';
import 'detail_chunks.dart';
import 'facade_textures.dart';
import 'movers.dart';
import 'ride_vehicles.dart';
import 'sky.dart';
import 'street_lamps.dart';

enum _Mode { diorama, ride }

/// A miniature district of Chongqing built from OpenStreetMap data.
/// Diorama mode orbits the city; ride mode follows a cableway or monorail.
class CityView extends StatefulWidget {
  const CityView({
    super.key,
    this.districts = const ['jialing_riverside', 'yuzhong_tip'],
  });

  /// Districts built by tool/chongqing, loaded side by side.
  final List<String> districts;

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

  final List<RideVehicles> _rides = [];
  int _rideIndex = 0;
  RideVehicles? get _ride => _rides.isEmpty ? null : _rides[_rideIndex];
  late final DetailChunks _rooftops;
  late final DetailChunks _vegetation;
  late final CityLook _look;
  late final StreetLamps _lamps;
  CloudTextures? _clouds;
  PreprocessedSky? _shaderSky;
  late final LedCrowns _crowns;

  /// Local clock time in hours (0-24). Starts on a warm afternoon.
  final ValueNotifier<double> _hour = ValueNotifier(15.5);
  bool _playing = false;

  /// One in-game hour passes in this many real seconds while playing.
  static const double _secondsPerHour = 10;
  late SkyState _sky = SkyState(15.5, overcast: false, foggy: false);
  Weather _weather = Weather.clear;
  final ValueNotifier<double> _clock = ValueNotifier(0);
  late final Movers _movers;

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
    _hour.dispose();
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
      final city = await CityData.loadAll(
        'Chongqing · Yuzhong',
        widget.districts,
      );
      _clouds = await CloudTextures.load();
      try {
        _shaderSky = await loadFmatSky('assets/chongqing/sky.fmat');
      } catch (e) {
        debugPrint('Shader sky unavailable: $e');
      }
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
      ..emissiveTexture = homeTex.lights.first;
    // Glass towers: smoother so they pick up the sky.
    // Rough enough that boosted water reflections don't turn towers to mirrors.
    final towers = _pbr(0.5)
      ..metallicFactor = 0.1
      ..baseColorTexture = glassTex.color
      ..emissiveTexture = glassTex.lights.first;
    final roads = _pbr(0.9);
    final materials = <String, Material>{
      'terrain': _pbr(0.95),
      'buildings': homes,
      'towers': towers,
      'roads': roads,
      'structures': _pbr(0.6),
    };
    city.layers.forEach((name, geometry) {
      final kind = name.split('/').last; // keys are "district/layer"
      _scene.add(
        Node(name: name, mesh: Mesh(geometry, materials[kind] ?? _pbr(0.8)))
          ..frustumCulled = false
          // Ground and roads are flat or gentle: casting shadows from them
          // barely shows but costs a full re-draw per shadow cascade.
          ..castsShadows = kind != 'terrain' && kind != 'roads'
          // The city never moves, so its shadow maps can be cached and only
          // redrawn when the sun does.
          ..shadowStatic = true,
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
      // Big tiles keep the draw count low across two districts.
      tileSize: 600,
      showWithin: 2400,
    );
    _rooftops = DetailChunks(
      city.details
          .where((d) => !plants.contains(d.type) && d.type != 'crown')
          .toList(),
      tileSize: 400,
      castsShadows: false, // too small to matter, costly per cascade
    );
    _crowns = LedCrowns(city.details.where((d) => d.type == 'crown').toList());
    _scene.add(_crowns.root);
    _scene
      ..add(_vegetation.root)
      ..add(_rooftops.root);
    _lamps = StreetLamps(city.traffic);
    _scene.add(_lamps.root);
    _movers = Movers(city);
    _scene.add(_movers.root);

    // River surface, a little larger than the district so edges stay wet.
    final size = city.bounds.max - city.bounds.min;
    // Dark and very smooth: the river is mostly what it reflects.
    final water = _pbr(0.03, vm.Vector4(0.05, 0.075, 0.08, 1));
    _look = CityLook(
      scene: _scene,
      homes: homes,
      towers: towers,
      homeLights: homeTex.lights,
      towerLights: glassTex.lights,
      roads: roads,
      water: water,
      riverLevel: city.riverLevel,
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
      // Start over the peninsula tip (the city origin), where the rivers meet.
      target: vm.Vector3(0, city.riverLevel + 40, 0),
      distance: 1150,
      // From the south-east, looking up the peninsula from the confluence.
      // A high angle is what makes tilt-shift photos read as models.
      azimuth: -2.4,
      polar: 0.72,
      minDistance: 120,
      maxDistance: 5000,
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

    // Vehicles for every ride: cable car cabins, Line 2 trains.
    final ridesNode = Node(name: 'rides');
    _scene.add(ridesNode);
    for (final ride in city.rides) {
      _rides.add(RideVehicles(ride, ridesNode));
    }
    if (_shaderSky != null) {
      _look
        ..skybox = Skybox(_shaderSky!)
        ..skyLighting = SkyEnvironment(_shaderSky!, faceResolution: 64);
    }
    _applyLook();
  }

  void _applyLook() {
    _look.configure(weather: _weather, quality: _q);
    _updateSky();
    // Low keeps trees to a shorter range to save phones some work.
    _vegetation
      ..showWithin = _q == Quality.low ? 1300 : 2400
      // Tree shadows look great but every cascade re-draws every tree.
      ..setCastsShadows(_q == Quality.high);
  }

  void _updateSky() {
    _sky = SkyState(
      _hour.value,
      overcast: _weather != Weather.clear,
      foggy: _weather == Weather.fog,
    );
    _look.update(_sky, _hour.value);
    _pushSkyParams();
  }

  /// Sends the sky state to the shader sky (assets/chongqing/sky.fmat).
  void _pushSkyParams() {
    final p = _shaderSky?.parameters;
    if (p == null) return;
    final s = _sky;
    final sunVisible =
        ((s.elevation + 3) / 4).clamp(0.0, 1.0) * (1 - 0.92 * s.cloudOvercast);
    p
      ..setVec3('zenith', s.zenith)
      ..setVec3('horizon', s.horizon)
      ..setVec3('sun_dir', s.sun)
      ..setVec3('sun_color', s.sunColor)
      ..setFloat('sun_visible', sunVisible)
      ..setVec3('moon_dir', s.moon)
      ..setFloat('night', s.night)
      ..setFloat('stars', s.stars)
      ..setVec3('city_glow', s.cityGlow)
      ..setFloat('coverage', s.cloudCover)
      ..setFloat('overcast', s.cloudOvercast)
      ..setVec3('cloud_lit', s.cloudLit)
      ..setVec3('cloud_shade', s.cloudShade)
      ..setFloat('detail', _q == Quality.low ? 3 : 5);
    // Re-bake the sky lighting only when the sky has visibly changed.
    // Every half in-game hour (5 s of real time while playing) is plenty:
    // ambient light changes slowly, and each bake costs GPU time.
    final key = (_hour.value * 2).round() * 10 + _weather.index;
    if (key != _bakedSkyKey) {
      _bakedSkyKey = key;
      _look.skyLighting?.invalidate();
    }
  }

  int _bakedSkyKey = -1;

  /// Projects a sky direction through whichever camera is active.
  Offset? _projectSky(vm.Vector3 dir, Size size) {
    if (size.isEmpty) return null;
    final camera = _mode == _Mode.diorama
        ? _orbitCamera.toCamera()
        : _rideCamera.toCamera();
    final eye = (_mode == _Mode.diorama ? _orbitNode : _rideNode)
        .globalTransform
        .getTranslation();
    return camera.worldToScreen(eye + dir * 6000, size);
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
    _movers.update(
      dt,
      showCars: _mode == _Mode.ride || _orbit.distance < 900,
      night: _sky.night > 0.5,
    );
    _clock.value += dt;
    _shaderSky?.parameters.setFloat('time', _clock.value);
    if (_playing) _hour.value = (_hour.value + dt / _secondsPerHour) % 24;
    if (_hour.value != _sky.hour) _updateSky();
    _lamps.update(_clock.value, _sky.night);
    _crowns.update(_clock.value, _sky.night);
    final eye = _mode == _Mode.diorama
        ? _orbitNode.globalTransform.getTranslation()
        : _rideNode.globalTransform.getTranslation();
    _vegetation.update(eye);
    _rooftops.update(
      _mode == _Mode.diorama
          ? _orbitNode.globalTransform.getTranslation()
          : _rideNode.globalTransform.getTranslation(),
    );
    // Tilt-shift is a diorama effect; riding, it would only smear the view.
    final dof = _mode == _Mode.diorama && _look.depthOfField;
    if (_scene.depthOfField.enabled != dof) _scene.depthOfField.enabled = dof;
    if (dof) _scene.depthOfField.focusDistance = _orbit.distance;

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
    for (final r in _rides) {
      r.update(dt);
    }
    final ride = _ride;
    if (ride != null && _mode == _Mode.ride) {
      final (eye, look) = ride.riderView(_rideYaw, _ridePitch);
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
        // The sky, painted behind the 3D view (which clears transparent).
        if (_shaderSky == null)
          LayoutBuilder(
            builder: (context, c) {
              return CustomPaint(
                size: c.biggest,
                painter: SkyPainter(
                  state: () => _sky,
                  project: _projectSky,
                  time: () => _clock.value,
                  clouds: () => _clouds,
                  forward: () {
                    final camera = _mode == _Mode.diorama
                        ? _orbitCamera.toCamera()
                        : _rideCamera.toCamera();
                    return camera.forward;
                  },
                  fovY: () => _mode == _Mode.diorama
                      ? 45 * vm.degrees2Radians
                      : 60 * vm.degrees2Radians,
                  repaint: _clock,
                ),
              );
            },
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
                painter: _RainPainter(_clock, night: _sky.night > 0.5),
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
                label: const Text('Ride'),
                enabled: ride != null,
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          if (_mode == _Mode.ride && _rides.length > 1)
            SegmentedButton<int>(
              style: _barButtonStyle,
              showSelectedIcon: false,
              segments: [
                for (var i = 0; i < _rides.length; i++)
                  ButtonSegment(
                    value: i,
                    icon: Icon(
                      _rides[i].path.kind == 'monorail'
                          ? Icons.train
                          : Icons.cable,
                    ),
                    label: Text(
                      _rides[i].path.kind == 'monorail'
                          ? 'Line 2 monorail'
                          : 'Yangtze cableway',
                    ),
                  ),
              ],
              selected: {_rideIndex},
              onSelectionChanged: (s) => setState(() {
                _rideIndex = s.first;
                _rideYaw = 0;
                _ridePitch = -0.15;
              }),
            ),
          _timeControl(wide),
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

  /// Play/pause plus a time-of-day slider with quick sunrise/sunset/night
  /// jumps. The slider listens to the clock directly so the rest of the
  /// bar doesn't rebuild every frame while the day plays.
  Widget _timeControl(bool wide) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _playing ? 'Pause the day' : 'Play the day',
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            onPressed: () => setState(() => _playing = !_playing),
          ),
          SizedBox(
            width: wide ? 220 : 130,
            child: ValueListenableBuilder<double>(
              valueListenable: _hour,
              builder: (context, h, _) =>
                  Slider(value: h, max: 24, onChanged: (v) => _hour.value = v),
            ),
          ),
          ValueListenableBuilder<double>(
            valueListenable: _hour,
            builder: (context, h, _) => SizedBox(
              width: 44,
              child: Text(
                '${h.floor().toString().padLeft(2, '0')}:'
                '${((h % 1) * 60).floor().toString().padLeft(2, '0')}',
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          for (final (icon, hour, tip) in [
            (Icons.wb_twilight, 17.6, 'Sunset'),
            (Icons.nightlight_outlined, 21.0, 'Night'),
            (Icons.wb_sunny_outlined, 12.5, 'Noon'),
          ])
            IconButton(
              tooltip: tip,
              icon: Icon(icon, size: 20),
              onPressed: () => _hour.value = hour,
            ),
        ],
      ),
    ),
  );

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
