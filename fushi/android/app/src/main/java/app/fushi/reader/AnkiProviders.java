package app.fushi.reader;

import android.content.Context;

/**
 * 按这台设备上装的是哪一份 AnkiDroid，选出对应的 {@link AnkiProvider}（BUG-2195）。
 *
 * <p>主包走 {@link AddContentApiProvider}（委托上游 AAR，与修复前逐行等价）；
 * 并行版走 {@link DirectAnkiProvider}（自己驱动 ContentResolver）。
 * 一个都没装时返回 {@code null}——调用方在此之前应该已经被
 * {@code AnkiDroidHelper.isApiAvailable} 挡住了。
 */
final class AnkiProviders {

    private AnkiProviders() {}

    static AnkiProvider forContext(Context context) {
        final AnkiDroidTarget target = AnkiDroidTarget.resolve(context);
        if (target == null) return null;
        return target.isMainBuild()
            ? new AddContentApiProvider(context)
            : new DirectAnkiProvider(context, target);
    }
}
