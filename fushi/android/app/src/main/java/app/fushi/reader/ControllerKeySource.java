package app.fushi.reader;

import android.view.InputDevice;

/**
 * Makes a controller's key events reach Dart as controller events.
 *
 * <p>Android input sources are bit masks: a gamepad's buttons and D-pad arrive
 * from the device's keyboard mapper with {@code SOURCE_KEYBOARD | SOURCE_DPAD |
 * SOURCE_GAMEPAD} (0x701) or {@code SOURCE_KEYBOARD | SOURCE_GAMEPAD} (0x501).
 * Flutter's {@code KeyEmbedderResponder} classifies the source with an exact
 * {@code switch (event.getSource())}, so every combined value falls through to
 * {@code kKeyboard}, and a handheld's D-pad becomes indistinguishable from a
 * keyboard's arrow keys ({@code KeyEvent.deviceType} in Dart).
 *
 * <p>{@link #forFlutter} narrows a source that carries the gamepad or joystick
 * class to exactly that class, which the engine's switch recognises. Plain
 * keyboards are left alone, including the common {@code SOURCE_KEYBOARD |
 * SOURCE_DPAD} (0x301) that every keyboard with arrow keys reports: their
 * arrows must stay keyboard arrows.
 */
final class ControllerKeySource {
    private ControllerKeySource() {}

    /** The source to hand the Flutter view for a key event from {@code source}. */
    static int forFlutter(int source) {
        if (has(source, InputDevice.SOURCE_JOYSTICK)) return InputDevice.SOURCE_JOYSTICK;
        if (has(source, InputDevice.SOURCE_GAMEPAD)) return InputDevice.SOURCE_GAMEPAD;
        return source;
    }

    private static boolean has(int source, int wanted) {
        return (source & wanted) == wanted;
    }
}
