package app.hibiki.reader.constants;

public final class ChannelNames {
    private ChannelNames() {}

    public static final String PREFIX = "app.hibiki.reader";
    public static final String SPLASH = PREFIX + "/splash";
    public static final String ANKI = PREFIX + "/anki";
    public static final String POPUP = PREFIX + "/popup";
    public static final String TTS = PREFIX + "/tts";
    public static final String UPDATE = PREFIX + "/update";
    public static final String VOLUME_KEYS = PREFIX + "/volume_keys";
    public static final String FLOATING_LYRIC = PREFIX + "/floating_lyric";
    public static final String FLOATING_DICT = PREFIX + "/floating_dict";
    public static final String LIFECYCLE = PREFIX + "/lifecycle";
    public static final String FONTS = PREFIX + "/fonts";
    public static final String SAF = PREFIX + "/saf";
    public static final String ICON_SWITCH = PREFIX + "/icon_switch";
    public static final String SCREEN_BRIGHTNESS = PREFIX + "/screen_brightness";
    public static final String SELECTION_ACTIONS = PREFIX + "/selection_actions";
    // TODO-1232 A3: render-backend toggle (persist the "disable Impeller / use
    // Skia" experiment flag; applied at next launch via MainActivity's
    // getFlutterShellArgs override).
    public static final String RENDER = PREFIX + "/render";
    // Hibiki→Fushi 跨包名迁移（改名迁移计划 P1-3/P1-4）：探测/拉起新包、
    // 发起卸载、注销 PROCESS_TEXT 系统入口。
    public static final String MIGRATION = PREFIX + "/migration";
}
