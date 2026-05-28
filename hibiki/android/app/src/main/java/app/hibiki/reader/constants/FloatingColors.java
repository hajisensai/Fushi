package app.hibiki.reader.constants;

/**
 * ARGB color constants used by floating overlay services.
 *
 * <p>FloatingDictService colors:</p>
 * <ul>
 *   <li>{@link #DICT_BACKGROUND} — main panel background</li>
 *   <li>{@link #DICT_SEARCH_HINT} — hint text in search input</li>
 *   <li>{@link #DICT_SEARCH_INPUT_BG} — search input field background</li>
 *   <li>{@link #DICT_ANKI_BUTTON_BG} — Anki export button background</li>
 * </ul>
 *
 * <p>FloatingLyricService colors (defaults; overridden at runtime via updateStyle):</p>
 * <ul>
 *   <li>{@link #LYRIC_TEXT} — lyric text colour</li>
 *   <li>{@link #LYRIC_BACKGROUND} — overlay background</li>
 *   <li>{@link #LYRIC_BUTTON_TEXT} — control-button icon tint</li>
 *   <li>{@link #LYRIC_BUTTON_BG} — control-button background</li>
 *   <li>{@link #LYRIC_HIGHLIGHT} — current-lyric highlight fill</li>
 *   <li>{@link #LYRIC_ACTIVE} — active/playing icon tint</li>
 * </ul>
 */
public final class FloatingColors {

    private FloatingColors() {}

    // ── FloatingDictService ───────────────────────────────────────────────────

    /** Panel background: near-black with slight blue, 94 % opacity. */
    public static final int DICT_BACKGROUND = 0xF01E1E2E;

    /** Search-input hint text: white at 50 % opacity. */
    public static final int DICT_SEARCH_HINT = 0x80FFFFFF;

    /** Search-input field background: white at ~20 % opacity.
     *  Same value as {@link #DICT_ANKI_BUTTON_BG} today; kept separate so
     *  their styling can diverge independently. */
    public static final int DICT_SEARCH_INPUT_BG = 0x33FFFFFF;

    /** Anki export button background: white at ~20 % opacity.
     *  Same value as {@link #DICT_SEARCH_INPUT_BG} today; kept separate so
     *  their styling can diverge independently. */
    public static final int DICT_ANKI_BUTTON_BG = 0x33FFFFFF;

    // ── FloatingLyricService (defaults) ─────────────────────────────────────

    /** Default lyric text colour: opaque white. */
    public static final int LYRIC_TEXT = 0xFFFFFFFF;

    /** Default overlay background: black at 80 % opacity. */
    public static final int LYRIC_BACKGROUND = 0xCC000000;

    /** Default control-button icon tint: opaque white. */
    public static final int LYRIC_BUTTON_TEXT = 0xFFFFFFFF;

    /** Default control-button background: black at ~20 % opacity. */
    public static final int LYRIC_BUTTON_BG = 0x33000000;

    /** Default lyric-highlight fill: amber at 50 % opacity. */
    public static final int LYRIC_HIGHLIGHT = 0x80FFD54F;

    /** Default active/playing icon tint: opaque amber. */
    public static final int LYRIC_ACTIVE = 0xFFFFD54F;
}
