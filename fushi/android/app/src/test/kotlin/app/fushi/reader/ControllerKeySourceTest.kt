package app.fushi.reader

import android.view.InputDevice
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Flutter's key embedder only recognises exact source values; a controller's
 * combined source must be narrowed to the controller class, a keyboard's must
 * not be touched.
 */
class ControllerKeySourceTest {
    @Test
    fun gamepadButtonsAndDpadBecomeGamepad() {
        val keyboardGamepad = InputDevice.SOURCE_KEYBOARD or InputDevice.SOURCE_GAMEPAD
        val keyboardDpadGamepad = keyboardGamepad or InputDevice.SOURCE_DPAD
        assertEquals(InputDevice.SOURCE_GAMEPAD, ControllerKeySource.forFlutter(keyboardGamepad))
        assertEquals(InputDevice.SOURCE_GAMEPAD, ControllerKeySource.forFlutter(keyboardDpadGamepad))
        assertEquals(InputDevice.SOURCE_GAMEPAD, ControllerKeySource.forFlutter(InputDevice.SOURCE_GAMEPAD))
    }

    @Test
    fun joystickSynthesizedKeysStayJoystick() {
        assertEquals(
            InputDevice.SOURCE_JOYSTICK,
            ControllerKeySource.forFlutter(InputDevice.SOURCE_JOYSTICK or InputDevice.SOURCE_GAMEPAD),
        )
        assertEquals(InputDevice.SOURCE_JOYSTICK, ControllerKeySource.forFlutter(InputDevice.SOURCE_JOYSTICK))
    }

    @Test
    fun keyboardsKeepTheirSource() {
        // Every keyboard with arrow keys reports KEYBOARD | DPAD.
        val keyboardWithArrows = InputDevice.SOURCE_KEYBOARD or InputDevice.SOURCE_DPAD
        assertEquals(keyboardWithArrows, ControllerKeySource.forFlutter(keyboardWithArrows))
        assertEquals(InputDevice.SOURCE_KEYBOARD, ControllerKeySource.forFlutter(InputDevice.SOURCE_KEYBOARD))
        assertEquals(InputDevice.SOURCE_DPAD, ControllerKeySource.forFlutter(InputDevice.SOURCE_DPAD))
    }
}
