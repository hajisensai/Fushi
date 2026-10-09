import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/bluray_disc_menu_input.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';

void main() {
  test('disc arrows and confirm use the same keyboard/controller actions', () {
    expect(
      blurayMenuKeyAction(LogicalKeyboardKey.arrowLeft),
      blurayMenuGamepadAction(GamepadButton.dpadLeft),
    );
    expect(blurayMenuKeyAction(LogicalKeyboardKey.arrowRight), 'right');
    expect(blurayMenuKeyAction(LogicalKeyboardKey.arrowUp), 'up');
    expect(blurayMenuKeyAction(LogicalKeyboardKey.arrowDown), 'down');
    expect(
      blurayMenuKeyAction(LogicalKeyboardKey.enter),
      blurayMenuGamepadAction(GamepadButton.a),
    );
    expect(
      blurayMenuKeyAction(LogicalKeyboardKey.escape),
      blurayMenuGamepadAction(GamepadButton.b),
    );
    expect(blurayMenuKeyAction(LogicalKeyboardKey.keyA), isNull);
    expect(blurayMenuGamepadAction(GamepadButton.start), 'menu');
    expect(blurayMenuGamepadAction(GamepadButton.select), 'popup');
  });

  test('letterboxing rejects black bars and maps the actual video edges', () {
    Offset? locate(Offset position) => blurayMenuPointerPosition(
      position: position,
      viewport: const Size(1000, 1000),
      video: const Size(1920, 1080),
      fit: BoxFit.contain,
    );
    expect(locate(const Offset(500, 100)), isNull);
    expect(locate(const Offset(500, 900)), isNull);
    expect(locate(const Offset(500, 500)), const Offset(.5, .5));
    expect(locate(const Offset(0, 218.75)), Offset.zero);
  });

  test(
    'cover maps cropped source instead of stretching button coordinates',
    () {
      final Offset? left = blurayMenuPointerPosition(
        position: const Offset(0, 500),
        viewport: const Size(1000, 1000),
        video: const Size(1920, 1080),
        fit: BoxFit.cover,
      );
      expect(left!.dx, closeTo(420 / 1920, .00001));
      expect(left.dy, .5);
    },
  );

  test('stretch and unready geometry cannot misroute input', () {
    expect(
      blurayMenuPointerPosition(
        position: const Offset(100, 200),
        viewport: const Size(400, 400),
        video: const Size(1920, 1080),
        fit: BoxFit.fill,
      ),
      const Offset(.25, .5),
    );
    expect(
      blurayMenuPointerPosition(
        position: Offset.zero,
        viewport: const Size(400, 400),
        video: Size.zero,
        fit: BoxFit.contain,
      ),
      isNull,
    );
  });
}
