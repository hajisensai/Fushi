package app.fushi.reader;

import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.util.HashMap;
import java.util.Map;

/**
 * Turns a game controller's analog triggers (LT / RT) into the discrete
 * {@link KeyEvent#KEYCODE_BUTTON_L2} / {@link KeyEvent#KEYCODE_BUTTON_R2} key
 * events the Dart side already understands.
 *
 * <p>Why this exists: on Android an Xbox-class controller reports LT / RT as
 * <em>motion axes</em> ({@link MotionEvent#AXIS_LTRIGGER} / {@link
 * MotionEvent#AXIS_RTRIGGER}, or {@code AXIS_BRAKE} / {@code AXIS_GAS}), never
 * as key events. The Flutter engine forwards joystick {@link MotionEvent}s to
 * nobody (its {@code AndroidTouchProcessor.onGenericMotionEvent} only handles
 * pointer hover / scroll), so without this bridge the triggers are invisible to
 * the app: they can neither be captured in the shortcut editor nor fire a
 * binding. Every other controller button (A/B/X/Y, LB/RB, sticks, Start /
 * Select) is a real key event and needs no help; the D-pad is synthesized from
 * the hat axes by the framework itself ({@code ViewRootImpl.SyntheticJoystickHandler}),
 * which is why {@link #onGenericMotionEvent} must never consume the motion
 * event — consuming it would switch that synthesis off.
 *
 * <p>The synthesized key carries the controller's device id and its source bits
 * (plus {@link InputDevice#SOURCE_GAMEPAD}) so Flutter classifies it as a
 * gamepad key exactly like a physical L2 / R2 button, and the Linux scan codes
 * {@code BTN_TL2} / {@code BTN_TR2} so the physical-key identity matches a
 * controller whose triggers really are buttons.
 *
 * <p>Threshold logic is a hysteresis edge detector: press at {@link
 * #PRESS_DEPTH}, release only below {@link #RELEASE_DEPTH}, so a trigger
 * hovering around the press point does not chatter. The axis choice per device
 * is resolved once from the device's motion ranges (see {@link
 * #resolveTriggerAxes}) — Android's own layouts disagree on which axis a
 * trigger lives on, and a centred {@code AXIS_Z} / {@code AXIS_RZ} is the right
 * stick, not a trigger.
 *
 * <p>The right stick's horizontal axis is also bridged: pushing it left / right
 * past {@link #STICK_PRESS} synthesizes {@link KeyEvent#KEYCODE_BUTTON_15} /
 * {@link KeyEvent#KEYCODE_BUTTON_16} (Dart side: {@code GamepadButton.rightStickLeft}
 * / {@code rightStickRight} map to {@code gameButton15} / {@code gameButton16}),
 * so the stick becomes a bindable virtual key. The axis is {@code AXIS_Z} when
 * the device has it and it is centred (range minimum &lt; 0), else {@code AXIS_RX}
 * if present, else the stick is not bridged (see {@link #resolveRightStickXAxis}).
 * Left and right are mutually exclusive: swinging straight across releases the
 * old key before pressing the new one. Scan code is 0 (no Linux BTN exists for
 * it). Like the triggers, these never consume the motion event.
 */
public final class GamepadTriggerKeySynthesizer {

    /** Pull depth (0..1) at which a trigger counts as pressed. */
    static final float PRESS_DEPTH = 0.5f;

    /**
     * Depth a pressed trigger must fall back below to count as released. Lower
     * than {@link #PRESS_DEPTH} on purpose (hysteresis).
     */
    static final float RELEASE_DEPTH = 0.25f;

    /** Linux {@code BTN_TL2} / {@code BTN_TR2}: what a button-type trigger scans as. */
    static final int SCAN_CODE_BTN_TL2 = 0x138;
    static final int SCAN_CODE_BTN_TR2 = 0x139;

    /** Right-stick horizontal depth (absolute) at which a virtual key counts as pressed. */
    static final float STICK_PRESS = 0.6f;

    /** Absolute depth the stick must fall back below to release (hysteresis). */
    static final float STICK_RELEASE = 0.35f;

    static final int STICK_NONE = -1;

    static final int SIDE_LEFT = 0;
    static final int SIDE_RIGHT = 1;

    /** Where the synthesized key events go (the Activity's {@code dispatchKeyEvent}). */
    public interface KeySink {
        void dispatchSynthesizedKey(KeyEvent event);
    }

    /** Motion-range facts about one device, abstracted so the axis choice is unit-testable. */
    interface AxisRanges {
        boolean hasAxis(int axis);

        /** Lower bound of the axis' normalised range; only queried when {@link #hasAxis} is true. */
        float minOf(int axis);
    }

    /**
     * Picks the motion axes that carry the trigger on one side, in the order
     * they should be sampled. Rules, in priority order:
     * <ol>
     *   <li>{@code AXIS_LTRIGGER} / {@code AXIS_RTRIGGER}: what every Xbox layout
     *       shipped in AOSP maps the triggers to.</li>
     *   <li>{@code AXIS_BRAKE} / {@code AXIS_GAS}: the alias Android's input
     *       documentation tells apps to read as well; some layouts use only it.</li>
     *   <li>{@code AXIS_Z} / {@code AXIS_RZ}, but <em>only when unipolar</em>
     *       (range minimum ≥ 0). A wired Xbox pad on a device lacking its
     *       vendor layout lands here (kernel {@code ABS_Z}/{@code ABS_RZ} through
     *       {@code Generic.kl}). A centred Z/RZ (range −1..1) is the right stick
     *       under Android's standard mapping and must never be read as a trigger.</li>
     * </ol>
     * When more than one applies (a layout exposing both LTRIGGER and BRAKE) all
     * are sampled and the deepest pull wins — see {@link #depthOf}.
     *
     * @return the axes to sample, possibly empty (device has no trigger on that side)
     */
    static int[] resolveTriggerAxes(AxisRanges ranges, int side) {
        final int primary = side == SIDE_LEFT ? MotionEvent.AXIS_LTRIGGER : MotionEvent.AXIS_RTRIGGER;
        final int alias = side == SIDE_LEFT ? MotionEvent.AXIS_BRAKE : MotionEvent.AXIS_GAS;
        final int legacy = side == SIDE_LEFT ? MotionEvent.AXIS_Z : MotionEvent.AXIS_RZ;
        final int[] picked = new int[3];
        int count = 0;
        if (ranges.hasAxis(primary)) picked[count++] = primary;
        if (ranges.hasAxis(alias)) picked[count++] = alias;
        if (count == 0 && ranges.hasAxis(legacy) && ranges.minOf(legacy) >= 0f) {
            picked[count++] = legacy;
        }
        final int[] result = new int[count];
        System.arraycopy(picked, 0, result, 0, count);
        return result;
    }

    /**
     * Picks the horizontal axis of the right stick: {@code AXIS_Z} when the
     * device has it and it is centred (range minimum &lt; 0; a unipolar Z is a
     * trigger), else {@code AXIS_RX} when present.
     *
     * @return the axis, or {@code -1} when the right stick cannot be bridged
     */
    static int resolveRightStickXAxis(AxisRanges ranges) {
        if (ranges.hasAxis(MotionEvent.AXIS_Z) && ranges.minOf(MotionEvent.AXIS_Z) < 0f) {
            return MotionEvent.AXIS_Z;
        }
        if (ranges.hasAxis(MotionEvent.AXIS_RX)) return MotionEvent.AXIS_RX;
        return -1;
    }

    /**
     * Stick hysteresis step. {@code state} is {@code -1} (left held), {@code 0}
     * (neutral) or {@code 1} (right held).
     *
     * @return the new state
     */
    static int stickState(int state, float value) {
        if (state == 0) {
            if (value <= -STICK_PRESS) return -1;
            if (value >= STICK_PRESS) return 1;
            return 0;
        }
        if (state < 0) {
            if (value >= STICK_PRESS) return 1;
            return value > -STICK_RELEASE ? 0 : -1;
        }
        if (value <= -STICK_PRESS) return -1;
        return value < STICK_RELEASE ? 0 : 1;
    }

    /**
     * Hysteresis step for one trigger. Pure so the press / release contract has
     * direct assertions.
     *
     * @return {@code +1} on a press edge, {@code -1} on a release edge, {@code 0} otherwise
     */
    static int edge(boolean pressed, float depth) {
        if (!pressed && depth >= PRESS_DEPTH) return 1;
        if (pressed && depth <= RELEASE_DEPTH) return -1;
        return 0;
    }

    /** Per-controller state: resolved axes and the pressed flag / down time per side. */
    static final class DeviceTriggers {
        final int[][] axes = new int[2][];
        final boolean[] pressed = new boolean[2];
        final long[] downTime = new long[2];
        /** Right-stick X axis, or {@code -1} when not bridged. */
        final int stickAxis;
        /** {@code -1} left held, {@code 0} neutral, {@code 1} right held. */
        int stickHeld = 0;
        long stickDownTime = 0;

        DeviceTriggers(AxisRanges ranges) {
            stickAxis = resolveRightStickXAxis(ranges);
            axes[SIDE_LEFT] = resolveTriggerAxes(ranges, SIDE_LEFT);
            axes[SIDE_RIGHT] = resolveTriggerAxes(ranges, SIDE_RIGHT);
        }

        /**
         * Applies one sampled depth per side and reports the edges. Pure (no
         * Android types) so the whole press / hold / release sequence is
         * unit-testable; {@link #onGenericMotionEvent} only supplies the depths.
         *
         * @param depths sampled depth per side ({@code NaN} = side has no trigger axis)
         * @param time   event time to remember as down time on a press edge
         * @return edge per side, as in {@link #edge}
         */
        int[] step(float[] depths, long time) {
            final int[] edges = new int[2];
            for (int side = 0; side < 2; side++) {
                if (Float.isNaN(depths[side])) continue;
                final int e = edge(pressed[side], depths[side]);
                edges[side] = e;
                if (e > 0) {
                    pressed[side] = true;
                    downTime[side] = time;
                } else if (e < 0) {
                    pressed[side] = false;
                }
            }
            return edges;
        }

        /**
         * Applies one sampled right-stick X value. Pure, like {@link #step}.
         *
         * @return {@code {releasedSide, pressedSide}} using {@link #SIDE_LEFT} /
         *         {@link #SIDE_RIGHT}, {@link #STICK_NONE} for "nothing". The
         *         release (if any) must be emitted before the press.
         */
        int[] stepStick(float value, long time) {
            final int next = stickState(stickHeld, value);
            final int prev = stickHeld;
            if (next == prev) return new int[] {STICK_NONE, STICK_NONE};
            final int released = prev == 0 ? STICK_NONE : (prev < 0 ? SIDE_LEFT : SIDE_RIGHT);
            final int pressed = next == 0 ? STICK_NONE : (next < 0 ? SIDE_LEFT : SIDE_RIGHT);
            stickHeld = next;
            if (pressed != STICK_NONE) stickDownTime = time;
            return new int[] {released, pressed};
        }
    }

    private static final int[] KEYCODES = {
        KeyEvent.KEYCODE_BUTTON_L2, KeyEvent.KEYCODE_BUTTON_R2,
    };
    private static final int[] STICK_KEYCODES = {
        KeyEvent.KEYCODE_BUTTON_15, KeyEvent.KEYCODE_BUTTON_16,
    };
    private static final int[] SCAN_CODES = {SCAN_CODE_BTN_TL2, SCAN_CODE_BTN_TR2};

    private final KeySink sink;
    private final Map<Integer, DeviceTriggers> devices = new HashMap<>();
    private final Map<Integer, Integer> sources = new HashMap<>();

    public GamepadTriggerKeySynthesizer(KeySink sink) {
        this.sink = sink;
    }

    /**
     * Feed every generic motion event here <em>before</em> handing it to
     * {@code super.dispatchGenericMotionEvent}. Never consumes the event.
     */
    public void onGenericMotionEvent(MotionEvent event) {
        if (!event.isFromSource(InputDevice.SOURCE_CLASS_JOYSTICK)
                || event.getAction() != MotionEvent.ACTION_MOVE) {
            return;
        }
        final InputDevice device = event.getDevice();
        if (device == null) return;
        final int deviceId = event.getDeviceId();
        DeviceTriggers triggers = devices.get(deviceId);
        if (triggers == null) {
            triggers = new DeviceTriggers(rangesOf(device));
            devices.put(deviceId, triggers);
        }
        sources.put(deviceId, event.getSource());
        final float[] depths = {
            depthOf(event, triggers.axes[SIDE_LEFT]),
            depthOf(event, triggers.axes[SIDE_RIGHT]),
        };
        final long time = event.getEventTime();
        final int[] edges = triggers.step(depths, time);
        for (int side = 0; side < 2; side++) {
            if (edges[side] > 0) {
                emit(KeyEvent.ACTION_DOWN, side, deviceId, triggers.downTime[side], time);
            } else if (edges[side] < 0) {
                emit(KeyEvent.ACTION_UP, side, deviceId, triggers.downTime[side], time);
            }
        }
        if (triggers.stickAxis >= 0) {
            final int[] stick = triggers.stepStick(event.getAxisValue(triggers.stickAxis), time);
            if (stick[0] != STICK_NONE) {
                emitStick(KeyEvent.ACTION_UP, stick[0], deviceId, triggers.stickDownTime, time);
            }
            if (stick[1] != STICK_NONE) {
                emitStick(KeyEvent.ACTION_DOWN, stick[1], deviceId, triggers.stickDownTime, time);
            }
        }
    }

    /**
     * Releases every trigger still held (emits the matching UP) and forgets all
     * devices. Call when the Activity pauses: a controller unplugged or the app
     * backgrounded mid-pull must not leave L2 / R2 stuck down on the Dart side.
     */
    public void releaseAll(long time) {
        for (Map.Entry<Integer, DeviceTriggers> entry : devices.entrySet()) {
            final DeviceTriggers triggers = entry.getValue();
            for (int side = 0; side < 2; side++) {
                if (triggers.pressed[side]) {
                    triggers.pressed[side] = false;
                    emit(KeyEvent.ACTION_UP, side, entry.getKey(), triggers.downTime[side], time);
                }
            }
            if (triggers.stickHeld != 0) {
                final int side = triggers.stickHeld < 0 ? SIDE_LEFT : SIDE_RIGHT;
                triggers.stickHeld = 0;
                emitStick(KeyEvent.ACTION_UP, side, entry.getKey(), triggers.stickDownTime, time);
            }
        }
        devices.clear();
        sources.clear();
    }

    /** Deepest pull across the side's resolved axes; {@code NaN} when the side has none. */
    private static float depthOf(MotionEvent event, int[] axes) {
        if (axes.length == 0) return Float.NaN;
        float depth = 0f;
        for (int axis : axes) {
            depth = Math.max(depth, event.getAxisValue(axis));
        }
        return depth;
    }

    private static AxisRanges rangesOf(final InputDevice device) {
        return new AxisRanges() {
            private InputDevice.MotionRange range(int axis) {
                final InputDevice.MotionRange joystick =
                        device.getMotionRange(axis, InputDevice.SOURCE_JOYSTICK);
                return joystick != null ? joystick : device.getMotionRange(axis);
            }

            @Override
            public boolean hasAxis(int axis) {
                return range(axis) != null;
            }

            @Override
            public float minOf(int axis) {
                return range(axis).getMin();
            }
        };
    }

    private void emitStick(int action, int side, int deviceId, long downTime, long eventTime) {
        final Integer source = sources.get(deviceId);
        final int keySource =
                (source == null ? 0 : source) | InputDevice.SOURCE_GAMEPAD;
        sink.dispatchSynthesizedKey(new KeyEvent(
                downTime,
                eventTime,
                action,
                STICK_KEYCODES[side],
                /* repeat= */ 0,
                /* metaState= */ 0,
                deviceId,
                /* scancode= */ 0,
                /* flags= */ 0,
                keySource));
    }

    private void emit(int action, int side, int deviceId, long downTime, long eventTime) {
        final Integer source = sources.get(deviceId);
        final int keySource =
                (source == null ? 0 : source) | InputDevice.SOURCE_GAMEPAD;
        sink.dispatchSynthesizedKey(new KeyEvent(
                downTime,
                eventTime,
                action,
                KEYCODES[side],
                /* repeat= */ 0,
                /* metaState= */ 0,
                deviceId,
                SCAN_CODES[side],
                /* flags= */ 0,
                keySource));
    }
}
