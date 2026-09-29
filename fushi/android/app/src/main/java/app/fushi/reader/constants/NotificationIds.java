package app.fushi.reader.constants;

/**
 * Stable notification-ID constants for Hibiki foreground services.
 *
 * <p>IDs must be unique across all notifications in the app and must never
 * change once shipped (Android associates persistent state with the ID).
 * Reserve the 9520–9539 range for Hibiki floating services.</p>
 */
public final class NotificationIds {

    private NotificationIds() {}

    /** Foreground notification for {@code FloatingDictService}. */
    public static final int FLOATING_DICT = 9528;

    /** Foreground notification for {@code FloatingLyricService}. */
    public static final int FLOATING_LYRIC = 9527;

    /** Foreground notification for {@code DownloadKeepAliveService}（互联下载保活）. */
    public static final int DOWNLOAD_KEEP_ALIVE = 9530;

    /** Foreground notification for {@code FloatingBallService}（全局悬浮球）. */
    public static final int FLOATING_BALL = 9529;

    /** Foreground notification for {@code ScreenOcrService}（截屏 OCR，mediaProjection）. */
    public static final int SCREEN_OCR = 9531;

    /** Notification channel ID for {@code FloatingBallService}. */
    public static final String CHANNEL_FLOATING_BALL = "fushi_floating_ball";

    /** Notification channel ID for {@code ScreenOcrService}. */
    public static final String CHANNEL_SCREEN_OCR = "fushi_screen_ocr";

    /** Notification channel ID for {@code DownloadKeepAliveService}（低重要度、无声）. */
    public static final String CHANNEL_DOWNLOAD_KEEP_ALIVE = "fushi_download_keep_alive";

    /** Notification channel ID for {@code FloatingDictService}. */
    public static final String CHANNEL_FLOATING_DICT = "hibiki_floating_dict";

    /** Notification channel ID for {@code FloatingLyricService}. */
    public static final String CHANNEL_FLOATING_LYRIC = "hibiki_floating_lyric";
}
