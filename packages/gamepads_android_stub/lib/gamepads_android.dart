import 'package:gamepads_platform_interface/api/gamepad_controller.dart';
import 'package:gamepads_platform_interface/api/gamepad_event.dart';
import 'package:gamepads_platform_interface/gamepads_platform_interface.dart';

/// No-op Android implementation of the `gamepads` platform interface.
///
/// Hibiki reads Android controllers through the Flutter engine's native
/// key-event path (gameButton*/arrow keys → reader/home `_handleKeyEvent`), so
/// the gamepads plugin is never used on Android. The upstream `gamepads_android`
/// is `ActivityAware` and casts the host Activity to `GamepadsCompatibleActivity`
/// in `onAttachedToActivity` WITHOUT a type check, crashing any app whose
/// MainActivity does not implement that interface. Registering this Dart-only
/// stub as the Android implementation keeps the `gamepads` umbrella resolvable
/// while ensuring no native ActivityAware plugin (and thus no cast) is wired in.
class GamepadsAndroidStub extends GamepadsPlatformInterface {
  /// Registered by the Flutter Dart plugin registrant on Android.
  static void registerWith() {
    GamepadsPlatformInterface.instance = GamepadsAndroidStub();
  }

  @override
  Future<List<GamepadController>> listGamepads() async =>
      const <GamepadController>[];

  @override
  Stream<GamepadEvent> get gamepadEventsStream =>
      const Stream<GamepadEvent>.empty();
}
