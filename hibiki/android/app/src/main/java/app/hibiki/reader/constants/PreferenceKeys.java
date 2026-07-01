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

    public static final String LYRIC_FONT_SIZE = "lyricFontSize";
    public static final String LYRIC_TEXT_COLOR = "lyricTextColor";
    public static final String LYRIC_BG_COLOR = "lyricBgColor";
    public static final String LYRIC_BUTTON_TEXT_COLOR = "lyricButtonTextColor";
    public static final String LYRIC_BUTTON_BG_COLOR = "lyricButtonBgColor";
    public static final String LYRIC_HIGHLIGHT_COLOR = "lyricHighlightColor";
    public static final String LYRIC_ACTIVE_COLOR = "lyricActiveColor";
    // TODO-708 P2: 悬浮字幕圆角半径（dp，0=直角原生观感）+ 宽度（dp，0=MATCH_PARENT 撑满）。
    public static final String LYRIC_CORNER_RADIUS = "lyricCornerRadius";
    public static final String LYRIC_WIDTH = "lyricWidth";
    public static final String LYRIC_LOCKED = "lyricLocked";
    public static final String LYRIC_CLICK_LOOKUP_ENABLED = "lyricClickLookupEnabled";

    /**
     * Last lyric/subtitle line pushed from Dart, persisted so a freshly created
     * {@code FloatingLyricService} can render the current line on its first frame.
     *
     * <p>Android starts the overlay via {@code startForegroundService}, which
     * returns before {@code onCreate} runs. Dart pushes the current cue text
     * immediately after {@code show}, so the live service instance does not yet
     * exist and the text would otherwise be dropped — leaving the current line
     * blank until the next cue (BUG-400 / TODO-711, the "opened but nothing
     * appears" half of TODO-707). Mirrors the style-persistence path so the
     * overlay replays state from prefs instead of assuming native readiness.</p>
     */
    public static final String LYRIC_CURRENT_TEXT = "lyricCurrentText";

    /** Last playback state pushed from Dart, replayed on service startup. */
    public static final String LYRIC_PLAYING = "lyricPlaying";

    // ── Splash / theme keys (MainActivity) ───────────────────────────────────

    /** Stored background colour as a packed ARGB int. */
    public static final String SPLASH_BG_COLOR = "bg_color";

    /** Stored dark-mode flag. */
    public static final String SPLASH_IS_DARK = "is_dark";
}
