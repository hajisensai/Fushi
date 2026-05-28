package app.hibiki.reader.constants;

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

    /** Notification channel ID for {@code FloatingDictService}. */
    public static final String CHANNEL_FLOATING_DICT = "hibiki_floating_dict";

    /** Notification channel ID for {@code FloatingLyricService}. */
    public static final String CHANNEL_FLOATING_LYRIC = "hibiki_floating_lyric";
}
