import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// An on-screen thumbstick for touch screens (it works with a mouse too).
/// [value] is x = right, y = forward, each -1..1.
class Joystick extends StatefulWidget {
  const Joystick({super.key, required this.value, this.size = 128});

  final ValueNotifier<vm.Vector2> value;
  final double size;

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset _knob = Offset.zero;

  void _move(Offset local) {
    final r = widget.size / 2;
    var d = local - Offset(r, r);
    if (d.distance > r) d = d / d.distance * r;
    setState(() => _knob = d);
    widget.value.value = vm.Vector2(d.dx / r, -d.dy / r);
  }

  void _release() {
    setState(() => _knob = Offset.zero);
    widget.value.value = vm.Vector2.zero();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return GestureDetector(
      onPanStart: (d) => _move(d.localPosition),
      onPanUpdate: (d) => _move(d.localPosition),
      onPanEnd: (_) => _release(),
      onPanCancel: _release,
      child: SizedBox(
        width: s,
        height: s,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.18),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.7),
                  width: 2,
                ),
              ),
            ),
            Transform.translate(
              offset: _knob,
              child: Container(
                width: s * 0.42,
                height: s * 0.42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.85),
                  boxShadow: const [
                    BoxShadow(blurRadius: 6, color: Colors.black26),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
