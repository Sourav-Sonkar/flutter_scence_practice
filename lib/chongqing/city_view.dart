import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Material;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'city_data.dart';
import 'city_look.dart';
import 'clouds.dart';
import 'district_scene.dart';
import 'street_lamps.dart' show RainPainter;
import 'facade_textures.dart';
import 'joystick.dart';
import 'ride_vehicles.dart';
import 'sky.dart';
import 'drone.dart';
import 'walk_world.dart';

enum _Mode { diorama, ride, drone }

/// A miniature district of Chongqing built from OpenStreetMap data.
/// Diorama mode orbits the city; ride mode follows a cableway or monorail.
class CityView extends StatefulWidget {
  const CityView({super.key});

  @override
  State<CityView> createState() => _CityViewState();
}

class _CityViewState extends State<CityView> {
  final Scene _scene = Scene();
  CityIndex? _city;

  // District streaming: districts load when the camera comes within
  // [_loadDistance] of them and are hidden beyond [_hideDistance].
  final Map<String, DistrictScene> _districts = {};
  final Set<String> _loading = {};
  late final Map<String, Material> _materials;
  static const double _loadDistance = 3500, _hideDistance = 6000;
  Object? _error;

  // Diorama camera: a node with a camera and an orbit controller.
  final Node _orbitNode = Node(name: 'orbit camera');
  late final CameraComponent _orbitCamera;
  late final OrbitCameraController _orbit;

  // Ride camera, placed by hand each frame.
  final Node _rideNode = Node(name: 'ride camera');
  late final CameraComponent _rideCamera;
  double _rideYaw = 0, _ridePitch = -0.15;

  // Drone: a free-flying first-person camera that can't clip into things.
  final Node _droneNode = Node(name: 'drone camera');
  late final CameraComponent _droneCamera;
  final Drone _drone = Drone();
  final WalkWorld _walkWorld = WalkWorld();
  final ValueNotifier<vm.Vector2> _flyStick = ValueNotifier(vm.Vector2.zero());
  final ValueNotifier<vm.Vector2> _liftStick = ValueNotifier(vm.Vector2.zero());
  double _scrollLift = 0;

  Camera get _camera => switch (_mode) {
    _Mode.diorama => _orbitCamera.toCamera(),
    _Mode.ride => _rideCamera.toCamera(),
    _Mode.drone => _droneCamera.toCamera(),
  };

  Node get _cameraNode => switch (_mode) {
    _Mode.diorama => _orbitNode,
    _Mode.ride => _rideNode,
    _Mode.drone => _droneNode,
  };

  List<RideVehicles> get _rides => [
    for (final d in _districts.values) ...d.rides,
  ];
  int _rideIndex = 0;
  RideVehicles? get _ride {
    final rides = _rides;
    return rides.isEmpty ? null : rides[_rideIndex.clamp(0, rides.length - 1)];
  }

  late final CityLook _look;
  CloudTextures? _clouds;
  PreprocessedSky? _shaderSky;

  /// Local clock time in hours (0-24). Starts on a warm afternoon.
  final ValueNotifier<double> _hour = ValueNotifier(15.5);
  bool _playing = false;

  /// One in-game hour passes in this many real seconds while playing.
  static const double _secondsPerHour = 10;
  late SkyState _sky = SkyState(15.5, overcast: false, foggy: false);
  Weather _weather = Weather.clear;
  final ValueNotifier<double> _clock = ValueNotifier(0);

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
    _flyStick.dispose();
    _liftStick.dispose();
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
      final city = await CityIndex.load('Chongqing · Yuzhong');
      _clouds = await CloudTextures.load();
      try {
        _shaderSky = await loadFmatSky('assets/chongqing/sky.fmat');
      } catch (e) {
        debugPrint('Shader sky unavailable: $e');
      }
      _build(city);
      _city = city;
      // Load the districts around the starting view before showing it;
      // the rest stream in as the camera moves.
      await Future.wait([
        for (final e in city.districts.entries)
          if (_distanceTo(e.value, vm.Vector3(0, 0, 0)) < _loadDistance)
            _loadDistrict(e.key),
      ]);
      if (mounted) setState(() {});
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

  /// Horizontal distance from [eye] to a district's box (0 inside it).
  static double _distanceTo(vm.Aabb2 b, vm.Vector3 eye) {
    final dx = eye.x.clamp(b.min.x, b.max.x) - eye.x;
    final dz = eye.z.clamp(b.min.y, b.max.y) - eye.z;
    return sqrt(dx * dx + dz * dz);
  }

  Future<void> _loadDistrict(String name) async {
    if (_districts.containsKey(name) || !_loading.add(name)) return;
    try {
      final data = await CityData.load(name);
      final district = DistrictScene(name, data, _materials)..setQuality(_q);
      _walkWorld.add(data.walk);
      _districts[name] = district;
      _scene.add(district.root);
      if (mounted) setState(() {}); // new rides for the picker
    } catch (e) {
      debugPrint('District $name failed to load: $e');
    } finally {
      _loading.remove(name);
    }
  }

  /// Loads districts the camera is approaching and hides far ones. A
  /// district with the active ride always stays visible.
  void _stream(vm.Vector3 eye) {
    final city = _city;
    if (city == null) return;
    final riding = _mode == _Mode.ride ? _ride : null;
    for (final e in city.districts.entries) {
      final d = _distanceTo(e.value, eye);
      final loaded = _districts[e.key];
      if (loaded == null) {
        if (d < _loadDistance && _loading.isEmpty) _loadDistrict(e.key);
        continue;
      }
      final hasRide = riding != null && loaded.rides.contains(riding);
      loaded.visible = hasRide || d < _hideDistance;
    }
  }

  void _build(CityIndex city) {
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
    _materials = materials;

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

    _droneCamera = CameraComponent(
      projection: PerspectiveProjection(
        fovRadiansY: 60 * vm.degrees2Radians,
        near: 0.5,
        far: 9000,
      ),
    );
    _droneNode.addComponent(_droneCamera);
    _scene.add(_droneNode);

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
    for (final d in _districts.values) {
      d.setQuality(_q);
    }
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
    final camera = _camera;
    final eye = _cameraNode.globalTransform.getTranslation();
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

    _advanceRide();
    _clock.value += dt;
    _shaderSky?.parameters.setFloat('time', _clock.value);
    if (_playing) _hour.value = (_hour.value + dt / _secondsPerHour) % 24;
    if (_hour.value != _sky.hour) _updateSky();
    if (_mode == _Mode.drone) _updateDrone(dt);
    final eye = _cameraNode.globalTransform.getTranslation();
    _stream(eye);
    for (final d in _districts.values) {
      d.update(
        dt,
        eye,
        time: _clock.value,
        night: _sky.night,
        showCars: _mode != _Mode.diorama || _orbit.distance < 900,
      );
    }
    // Tilt-shift is a diorama effect; riding, it would only smear the view.
    final dof = _mode == _Mode.diorama && _look.depthOfField;
    // (No tilt-shift while walking or riding: it would blur the street.)
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

  void _setMode(_Mode mode) {
    if (mode == _Mode.drone && _mode != _Mode.drone) {
      // Take off from just behind and above where the current view looks,
      // facing the same way, so the view carries on naturally.
      final eye = _cameraNode.globalTransform.getTranslation();
      final f = _camera.forward;
      final flat = vm.Vector3(f.x, 0, f.z)..normalize();
      final focus = _mode == _Mode.diorama ? _orbit.target : eye + f * 60;
      final start = focus - flat * 120 + vm.Vector3(0, 70, 0);
      final ground = _walkWorld.terrainAt(start.x, start.z) ?? start.y;
      start.y = max(start.y, ground + 60);
      _drone.place(start, (focus - start)..normalize());
      _updateDrone(0);
    }
    setState(() => _mode = mode);
  }

  /// Keyboard (WASD / arrows, Space/E up, Q/C down, Shift boost), scroll,
  /// and the two on-screen sticks.
  void _updateDrone(double dt) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    bool down(List<LogicalKeyboardKey> any) => any.any(keys.contains);
    final move = vm.Vector2(
      (down([LogicalKeyboardKey.keyD, LogicalKeyboardKey.arrowRight])
              ? 1.0
              : 0.0) -
          (down([LogicalKeyboardKey.keyA, LogicalKeyboardKey.arrowLeft])
              ? 1.0
              : 0.0),
      (down([LogicalKeyboardKey.keyW, LogicalKeyboardKey.arrowUp])
              ? 1.0
              : 0.0) -
          (down([LogicalKeyboardKey.keyS, LogicalKeyboardKey.arrowDown])
              ? 1.0
              : 0.0),
    )..add(_flyStick.value);
    var lift =
        (down([LogicalKeyboardKey.space, LogicalKeyboardKey.keyE])
            ? 1.0
            : 0.0) -
        (down([LogicalKeyboardKey.keyQ, LogicalKeyboardKey.keyC]) ? 1.0 : 0.0) +
        _liftStick.value.y +
        _scrollLift;
    lift = lift.clamp(-1.0, 1.0);
    _scrollLift *= max(0.0, 1 - dt * 6); // a scroll nudge fades out
    final boost = down([
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.shiftRight,
    ]);
    _drone.update(
      dt,
      _walkWorld,
      move: move,
      lift: lift,
      turn: _liftStick.value.x * 1.4,
      boost: boost,
      riverLevel: _city?.riverLevel ?? 0,
    );
    final p = _drone.position;
    _droneNode.lookAtFrom(p, p + _drone.forward);
  }

  /// Puts the ride camera in the active ride's lead vehicle. (Vehicles
  /// themselves are moved by their district.)
  void _advanceRide() {
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
    final view = SceneView(_scene, camera: _camera, onTick: _onTick);
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
                  forward: () => _camera.forward,
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
        else if (_mode == _Mode.drone)
          Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                _scrollLift -= e.scrollDelta.dy * 0.02;
              }
            },
            child: GestureDetector(
              onPanUpdate: (d) =>
                  _drone.look(d.delta.dx * 0.004, d.delta.dy * 0.004),
              child: view,
            ),
          )
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
        if (_mode == _Mode.drone) ...[
          // Two sticks like a real drone controller: left climbs and turns,
          // right flies.
          Positioned(
            left: 24,
            bottom: 36,
            child: SafeArea(child: Joystick(value: _liftStick, size: 112)),
          ),
          Positioned(
            right: 24,
            bottom: 36,
            child: SafeArea(child: Joystick(value: _flyStick, size: 112)),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: IgnorePointer(
              child: Text(
                'WASD / arrows to fly · Space or E up · Q or C down · Shift boost · drag to look · scroll to climb',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  shadows: [Shadow(blurRadius: 4)],
                ),
              ),
            ),
          ),
        ],
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

  Widget _topBar(CityIndex city) {
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
              const ButtonSegment(
                value: _Mode.drone,
                icon: Icon(Icons.flight),
                label: Text('Drone'),
              ),
              ButtonSegment(
                value: _Mode.ride,
                icon: const Icon(Icons.airline_seat_recline_normal),
                label: const Text('Ride'),
                enabled: ride != null,
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => _setMode(s.first),
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

  Widget _landmarkStrip(CityIndex city) => SizedBox(
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

  Widget _attribution(CityIndex city) => Text(
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
