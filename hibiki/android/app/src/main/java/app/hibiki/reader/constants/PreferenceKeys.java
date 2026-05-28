package app.hibiki.reader.constants;

/**
 * SharedPreferences file names and key constants for Hibiki services.
 *
 * <p><strong>Do not rename these values.</strong> They are persisted to disk;
 * renaming without a migration will silently lose stored data on existing
 * installs.</p>
 */
public final class PreferenceKeys {

    private PreferenceKeys() {}

    // ── SharedPreferences file names ─────────────────────────────────────────

    /** Prefs file used by {@code FloatingDictService} and its {@code BaseFloatingService} base. */
    public static final String FILE_FLOATING_DICT = "floating_dict_prefs";

    /** Prefs file used by {@code FloatingLyricService} and its {@code BaseFloatingService} base. */
    public static final String FILE_FLOATING_LYRIC = "floating_lyric_prefs";

    /** Prefs file used by {@code MainActivity} for splash/theme persistence. */
    public static final String FILE_SPLASH = "hibiki_splash";

    // ── BaseFloatingService position keys ────────────────────────────────────

    /** Saved X position of a floating overlay window. */
    public static final String POS_X = "posX";

    /** Saved Y position of a floating overlay window (default baseline). */
    public static final String POS_Y = "posY";

    /**
     * Saved Y position for {@code FloatingLyricService}.
     * Uses a distinct key for backward compatibility with older installs that
     * stored the lyric position under this name before the base class was introduced.
     */
    public static final String POS_Y_TOP = "posYTop";

    // ── Splash / theme keys (MainActivity) ───────────────────────────────────

    /** Stored background colour as a packed ARGB int. */
    public static final String SPLASH_BG_COLOR = "bg_color";

    /** Stored dark-mode flag. */
    public static final String SPLASH_IS_DARK = "is_dark";
}
