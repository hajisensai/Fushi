# gamepads

<p align="center">
  A Flutter plugin to handle gamepad input across multiple platforms.
</p>

<p align="center">
  <a title="Pub" href="https://pub.dev/packages/gamepads">
    <img
      src="https://img.shields.io/pub/v/gamepads.svg?style=popout&include_prereleases"
      alt="Badge for latest release"
    />
  </a>
  <a title="Build Status" href="https://github.com/flame-engine/gamepads/actions?query=workflow%3Acicd+branch%3Amain">
    <img
      src="https://github.com/flame-engine/gamepads/workflows/cicd/badge.svg?branch=main"
      alt="Badge for build status"
    />
  </a>
  <a title="Discord" href="https://discord.gg/pxrBmy4">
    <img src="https://img.shields.io/discord/509714518008528896.svg" alt="Badge for Discord server"/>
  </a>
  <a title="Melos" href="https://github.com/invertase/melos">
    <img
      src="https://img.shields.io/badge/maintained%20with-melos-f700ff.svg"
      alt="Badge showing that Melos is used"
    />
  </a>
</p>

---

Gamepads is a Flutter plugin to handle gamepad (or joystick) input across multiple platforms.

It supports multiple simultaneously connected gamepads, and will automatically detect and listen to
new connections.


## Platform Support

| Platform | Status |
|----------|--------|
| Android  | Supported |
| iOS      | Supported |
| macOS    | Supported |
| Linux    | Supported |
| Windows  | Supported |
| Web      | Supported |


## Getting Started

The `list` method will list all currently connected gamepads:

```dart
  final gamepads = await Gamepads.list();
  // ...
```

This uses the data class `GamepadController`, which has an `id` and a user-facing `name`.

Listen to `normalizedEvents` for gamepad input with consistent
button/axis names and value ranges across all platforms:

```dart
Gamepads.normalizedEvents.listen((event) {
  if (event.button == GamepadButton.a && event.value != 0) {
    print('A button pressed!');
  }
  if (event.axis == GamepadAxis.leftStickX) {
    print('Left stick X: ${event.value}');
  }
});
```

The platform is auto-detected. The `normalizedEvents` stream
is lazy — normalization only runs while there is an active
listener. When nobody is listening, no normalized events are
created.

To override the auto-detected platform, set a custom
normalizer before accessing `normalizedEvents`:

```dart
Gamepads.normalizer = GamepadNormalizer.forPlatform(
  GamepadPlatform.linux,
);
```


## Raw Events

If you need access to the underlying platform-specific events,
use the `events` stream instead. Note that raw key names and
value ranges differ across platforms (e.g., the A button is
`"0"` on Linux, `"a"` on Windows, `"buttonA"` on iOS,
`"KEYCODE_BUTTON_A"` on Android, and `"button 0"` on Web).

```dart
  Gamepads.events.listen((event) {
    // ...
  });
```

You can also listen to events only for a specific gamepad with `eventsByGamepad`.

Events are described by the data class `GamepadEvent`:

```dart
class GamepadEvent {
  /// The id of the gamepad controller that fired the event.
  final String gamepadId;

  /// The timestamp in which the event was fired, in milliseconds since epoch.
  final int timestamp;

  /// The [KeyType] of the key that was triggered.
  final KeyType type;

  /// A platform-dependant identifier for the key that was triggered.
  final String key;

  /// The current value of the key.
  final double value;

  // ...
}
```

Normalized events always preserve the original raw event via
`NormalizedGamepadEvent.rawEvent`, so you can fall back to
platform-specific handling when needed.


## Standard Gamepad Model

Buttons and axes follow the Xbox/standard gamepad layout:

| Type     | Values                       | Range       |
|----------|------------------------------|-------------|
| `Button` | `a`, `b`, `x`, `y`           | 0.0 or 1.0  |
| `Button` | `leftBumper`, `rightBumper`  | 0.0 or 1.0  |
| `Button` | `leftTrigger`, `rightTrigger`| 0.0 or 1.0  |
| `Button` | `back`, `start`, `home`      | 0.0 or 1.0  |
| `Button` | `leftStick`, `rightStick`    | 0.0 or 1.0  |
| `Button` | `dpadUp/Down/Left/Right`     | 0.0 or 1.0  |
| `Button` | `touchpad`                   | 0.0 or 1.0  |
| `Axis`   | `leftStickX`, `leftStickY`   | -1.0 to 1.0 |
| `Axis`   | `rightStickX`, `rightStickY` | -1.0 to 1.0 |
| `Axis`   | `leftTrigger`, `rightTrigger`| 0.0 to 1.0  |

Buttons use 0.0 (released) and 1.0 (pressed).
Stick conventions: Left/Down = -1, Right/Up = +1.


## Platform Details

**iOS / macOS** — Uses the GCController API. Button and axis
names are SF Symbols strings (e.g. `a.circle`, `l.joystick`),
which the normalizer matches by pattern.

**Android** — Uses `KeyEvent` and `MotionEvent` with
platform-defined key codes (e.g. `KEYCODE_BUTTON_A`,
`AXIS_X`). No device-specific lookup needed.

**Web** — Uses the W3C Gamepad API with the standard mapping.
Buttons and axes are reported as numeric indices (`button 0`,
`analog 0`).

**Windows** — Uses the
[GameInput API](https://learn.microsoft.com/en-us/gaming/gdk/docs/reference/input/gameinput/gameinput_members)
v0 which provides consistent named keys (e.g. `a`, `leftThumbstickX`)
for all controllers. To compile for windows you need Windows SDK which
gets installed when you setup [Windows target for Flutter](https://docs.flutter.dev/platform-integration/windows/setup).
End users do not need Windows SDK.

**Linux** — Uses raw numeric joystick indices that vary by
controller hardware. The normalizer uses a bundled copy of
the community-maintained
[SDL GameController DB](https://github.com/gabomdq/SDL_GameControllerDB)
to select the correct mapping by vendor/product ID (1500+
controllers). Unknown controllers fall back to an Xbox-like
layout. You can load additional mappings at runtime via
`ControllerDatabase.loadSdlMappings()`.


## Contributing

If you are interested in helping, please reach out!
You can use GitHub or our [Discord server](https://discord.gg/pxrBmy4).


## Android Integration

The Android implementation requires the application's Activity to forward input events (and
input devices) to the plugin. Below is an example of a MainActivity for a clean Flutter project
that has implemented the required boilerplate code. For many projects it will be possible to simply
duplicate this setup.

```kotlin
package [YOUR_PACKAGE_NAME]

import android.hardware.input.InputManager
import android.os.Handler
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import org.flame_engine.gamepads_android.GamepadsCompatibleActivity

class MainActivity: FlutterActivity(), GamepadsCompatibleActivity {
    var keyListener: ((KeyEvent) -> Boolean)? = null
    var motionListener: ((MotionEvent) -> Boolean)? = null

    override fun dispatchGenericMotionEvent(motionEvent: MotionEvent): Boolean {
        return motionListener?.invoke(motionEvent) ?: false
    }
    
    override fun dispatchKeyEvent(keyEvent: KeyEvent): Boolean {
        if (keyListener?.invoke(keyEvent) == true) {
            return true
        }
        return super.dispatchKeyEvent(keyEvent)
    }

    override fun registerInputDeviceListener(
      listener: InputManager.InputDeviceListener, handler: Handler?) {
        val inputManager = getSystemService(INPUT_SERVICE) as InputManager
        inputManager.registerInputDeviceListener(listener, null)
    }

    override fun registerKeyEventHandler(handler: (KeyEvent) -> Boolean) {
        keyListener = handler
    }

    override fun registerMotionEventHandler(handler: (MotionEvent) -> Boolean) {
        motionListener = handler
    }
}

```


## Windows troubleshooting

If you get a compilation error due to missing "GameInput.h" it
is because it doesn't find your [Windows SDK](https://learn.microsoft.com/en-us/windows/apps/windows-sdk/)
installation.

Make sure you have setup [Windows target for Flutter](https://docs.flutter.dev/platform-integration/windows/setup).
It is specifically the step to setup C++ for desktop development
that installs Windows SDK.

Neither package users (developers) nor end users needs GameInput
redistributable. This is because gamepads uses GameInput API v0
which is statically linked.


## Bridge packages

- [flame_gamepads](https://github.com/flame-engine/flame/tree/main/packages/flame_gamepads) -
  Provides a GamepadCallbacks component mixin for your Flame games
- [flutter_gamepads](./packages/flutter_gamepads/) - Provides a widget that maps gamepad input
  to UI interaction with your Flutter widgets. In regular Flutter apps as well as for Flame
  overlays.


## Support

The simplest way to show us your support is by giving the project a star! :star:

If you want, you can also support us monetarily by donating through OpenCollective:

<a href="https://opencollective.com/blue-fire/donate" target="_blank">
  <img
    src="https://opencollective.com/blue-fire/donate/button@2x.png?color=blue"
    width=200
    alt="Open Collective donate button"
  />
</a>

Through GitHub Sponsors:

<a href="https://github.com/sponsors/bluefireteam" target="_blank">
  <img
    src="https://img.shields.io/badge/Github%20Sponsor-blue?style=for-the-badge&logo=github&logoColor=white"
    width=200
    alt="GitHub Sponsor button"
  />
</a>

Or by becoming a patron on Patreon:

<a href="https://www.patreon.com/bluefireoss" target="_blank">
  <img
   src="https://c5.patreon.com/external/logo/become_a_patron_button.png"
   width=200
   alt="Patreon donate button"
  />
</a>
