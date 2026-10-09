import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';

/// Disc menus own these keys only while their authored buttons are active.
String? blurayMenuKeyAction(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowUp) return 'up';
  if (key == LogicalKeyboardKey.arrowDown) return 'down';
  if (key == LogicalKeyboardKey.arrowLeft) return 'left';
  if (key == LogicalKeyboardKey.arrowRight) return 'right';
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    return 'select';
  }
  if (key == LogicalKeyboardKey.escape) return 'prev';
  return null;
}

String? blurayMenuGamepadAction(GamepadButton button) => switch (button) {
  GamepadButton.dpadUp => 'up',
  GamepadButton.dpadDown => 'down',
  GamepadButton.dpadLeft => 'left',
  GamepadButton.dpadRight => 'right',
  GamepadButton.a => 'select',
  GamepadButton.b => 'prev',
  GamepadButton.start => 'menu',
  GamepadButton.select => 'popup',
  _ => null,
};

/// Converts the displayed surface into normalized video coordinates. Black
/// bars are not buttons; cover crops retain their source-space offset.
Offset? blurayMenuPointerPosition({
  required Offset position,
  required Size viewport,
  required Size video,
  required BoxFit fit,
}) {
  if (viewport.isEmpty || video.isEmpty) return null;
  final FittedSizes sizes = applyBoxFit(fit, video, viewport);
  final Rect destination = Alignment.center.inscribe(
    sizes.destination,
    Offset.zero & viewport,
  );
  if (!destination.contains(position)) return null;
  final Rect source = Alignment.center.inscribe(
    sizes.source,
    Offset.zero & video,
  );
  return Offset(
    (source.left +
            (position.dx - destination.left) /
                destination.width *
                source.width) /
        video.width,
    (source.top +
            (position.dy - destination.top) /
                destination.height *
                source.height) /
        video.height,
  );
}
