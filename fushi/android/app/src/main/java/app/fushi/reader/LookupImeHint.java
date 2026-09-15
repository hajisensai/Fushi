package app.fushi.reader;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.LocaleList;
import android.widget.TextView;

import app.fushi.reader.constants.PreferenceKeys;

/**
 * 查词输入框的输入法语言（Android 侧）。
 *
 * <p>Android 不允许应用切换系统输入法——能做的只有 {@code EditorInfo.hintLocales}
 * 这个「提示」（API 24+）：装了对应语言的 Gboard 之类会据此切过去，别的键盘可能只
 * 是把该语言排到前面，也可能忽略。这是应用侧的上限，不是实现没做到位。
 *
 * <p>Flutter 的 {@code TextField} 有 {@code hintLocales} 参数，所以 Flutter 查词页面
 * 直接传就行；但悬浮词典（{@link FloatingDictService}）和弹窗词典
 * （{@code PopupDictActivity}）的搜索框是**原生 EditText**，吃不到那个参数，只能从
 * 这里读用户选的语言。
 *
 * <p>之所以经 SharedPreferences 而不是 Intent extra：这两个 surface 都可能在任何
 * Flutter 查词页面打开之前就被拉起（通知栏磁贴、系统 PROCESS_TEXT、剪贴板监听），
 * 那时没有活着的 Dart 侧可问。
 */
public final class LookupImeHint {

    private LookupImeHint() {}

    /** Flutter 侧在偏好变更时与启动时各存一次。空串 = 用户没选，别发任何提示。 */
    public static void store(Context context, String tag) {
        SharedPreferences prefs = context.getSharedPreferences(
                PreferenceKeys.FILE_LOOKUP_IME, Context.MODE_PRIVATE);
        prefs.edit().putString(
                PreferenceKeys.LOOKUP_IME_LANGUAGE, tag == null ? "" : tag).apply();
    }

    /** 当前存着的 BCP-47 标签；没存过返回空串。 */
    public static String stored(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(
                PreferenceKeys.FILE_LOOKUP_IME, Context.MODE_PRIVATE);
        return prefs.getString(PreferenceKeys.LOOKUP_IME_LANGUAGE, "");
    }

    /**
     * 把语言提示挂到一个原生输入框上。用户没选过就什么都不做——**不要**设成空的
     * LocaleList：那在 Android 的契约里是「明确不要任何提示」，比不设更强，会压掉
     * 输入法自己记住的语言。
     */
    public static void applyTo(Context context, TextView field) {
        if (field == null) {
            return;
        }
        String tag = stored(context);
        if (tag.isEmpty()) {
            return;
        }
        LocaleList locales = LocaleList.forLanguageTags(tag);
        if (locales.isEmpty()) {
            return;
        }
        field.setImeHintLocales(locales);
    }
}
