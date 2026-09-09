package app.fushi.reader;

import android.content.Context;
import android.content.pm.PackageManager;
import android.content.pm.ProviderInfo;
import android.net.Uri;

/**
 * 这台设备上**实际安装**的那个 AnkiDroid（BUG-2195）。
 *
 * <p>为什么需要它：AnkiDroid 官方除了主包 {@code com.ichi2.anki} 还发布「并行版」
 * （parallel builds），供用户同时装多份。并行版是由 gradle 的 {@code customSuffix}
 * 属性经 {@code applicationIdSuffix} 生成的，因此
 * <ul>
 *   <li>包名 = {@code com.ichi2.anki.<后缀>}</li>
 *   <li>ContentProvider authority = {@code ${applicationId}.flashcards}
 *       （上游 {@code AnkiDroid/src/main/AndroidManifest.xml} 的 provider 段）</li>
 *   <li>读写权限 = {@code ${applicationId}.permission.READ_WRITE_DATABASE}
 *       （同文件的 {@code <permission>} 声明）</li>
 * </ul>
 * 三者**都带后缀**。而我们依赖的 {@code com.github.ankidroid:Anki-Android} AAR 里，
 * {@code FlashCardsContract} 把 {@code content://com.ichi2.anki.flashcards} 和
 * {@code com.ichi2.anki.permission.READ_WRITE_DATABASE} 编译成了常量（已解包该 AAR
 * 的常量池逐一核对过），{@code AddContentApi.getAnkiDroidPackageName} 也只按那个写死
 * 的 authority 去 {@code resolveContentProvider}。
 *
 * <p>后果就是用户报的现象：装了并行版 A 的机器上
 * {@code AnkiDroidHelper.isApiAvailable} 恒 false → 权限请求在
 * {@code AnkiChannelHandler} 里直接短路成 {@code unavailable}，
 * <b>系统权限对话框一次都不会弹</b>。
 *
 * <p>本类把「装的是哪一个」变成一次显式解析：逐个候选 authority 去
 * {@link PackageManager#resolveContentProvider}，命中即得包名 / authority / 权限名
 * 三件套。每次访问都查询 PackageManager：安装、卸载或启用 API 不保证重启本进程。
 */
public final class AnkiDroidTarget {

    /** AnkiDroid 主包。并行版都是它加一个后缀。 */
    public static final String MAIN_PACKAGE = "com.ichi2.anki";

    /**
     * 候选包名，**按优先级**排列：主包永远第一（同时装了主包和并行版时行为与修复前
     * 一致），随后是官方并行版 a–e，最后是开发者自编的 debug 版。
     *
     * <p><b>后缀必须小写。</b>并行版的**显示名**是大写的（用户桌面上那个图标写着
     * {@code AnkiDroid.E}），**包名后缀却是小写的**——上游
     * {@code tools/parallel-package-release.sh} 里两者是分别传的：
     * <pre>
     *   LCBUILD=`tr '[:upper:]' '[:lower:]' &lt;&lt;&lt; $BUILD`
     *   ./gradlew ... -PcustomSuffix="$LCBUILD" -PcustomName="AnkiDroid.$BUILD"
     * </pre>
     * {@code customSuffix} 经 {@code applicationIdSuffix} 拼进 applicationId，于是包名
     * 是 {@code com.ichi2.anki.e}。Android 包名大小写敏感，照着图标名写大写后缀
     * （BUG-2195 首版就是这么写的）等于这张表里的并行版项**一条都匹配不上**——
     * 用户装着 AnkiDroid.E 却一直被告知「未安装 AnkiDroid」。上游从 v2.15.0 起
     * 一直是小写，大写后缀的并行版从未发布过，因此不保留大写候选。
     *
     * <p>上游的 {@code customSuffix} 理论上可以是任意字符串，所以这张表不可能穷尽；
     * 它覆盖的是官方实际发布的那几个。用 {@code QUERY_ALL_PACKAGES} 去穷举是不可接受
     * 的替代方案（Play 政策受限权限，且为这点功能要它属于滥用）。清单必须与
     * {@code AndroidManifest.xml} 里的 {@code <queries>} / {@code <uses-permission>}
     * 逐条对应——**只在这里加一项而忘了改 manifest，新项在 Android 11+ 上恒不可见**，
     * 有源码守卫钉这条一致性（连同后缀大小写）。
     */
    public static final String[] CANDIDATE_PACKAGES = {
        MAIN_PACKAGE,
        MAIN_PACKAGE + ".a",
        MAIN_PACKAGE + ".b",
        MAIN_PACKAGE + ".c",
        MAIN_PACKAGE + ".d",
        MAIN_PACKAGE + ".e",
        MAIN_PACKAGE + ".debug",
    };


    /** 安装包名，例如 {@code com.ichi2.anki.e}。 */
    public final String packageName;

    /** 该安装的 flashcards provider authority。 */
    public final String authority;

    /** 该安装定义的读写权限名。 */
    public final String permission;

    private AnkiDroidTarget(String packageName) {
        this.packageName = packageName;
        this.authority = authorityFor(packageName);
        this.permission = permissionFor(packageName);
    }

    public static String authorityFor(String packageName) {
        return packageName + ".flashcards";
    }

    public static String permissionFor(String packageName) {
        return packageName + ".permission.READ_WRITE_DATABASE";
    }

    /** 是不是主包。并行版无法走 AAR 的 {@code AddContentApi}（authority 写死）。 */
    public boolean isMainBuild() {
        return MAIN_PACKAGE.equals(packageName);
    }

    /**
     * 把 {@code FlashCardsContract} 里那些写死主包 authority 的 URI 换成本目标的。
     *
     * <p>只换 authority，path / query 原样保留——列名、path 段、query 参数都不带包名，
     * 是 provider 契约的一部分，与装的是哪一份无关。
     */
    public Uri rebase(Uri contractUri) {
        if (contractUri == null) return null;
        if (authority.equals(contractUri.getAuthority())) return contractUri;
        return contractUri.buildUpon().authority(authority).build();
    }

    /**
     * 解析这台设备上装的 AnkiDroid；一个都没有则返回 {@code null}。
     *
     * <p>判据是 {@link PackageManager#resolveContentProvider}——「provider 在不在」比
     * 「包在不在」更准：用户可能装了 AnkiDroid 但在它的设置里关掉了 API provider，
     * 那种情况下包查得到、provider 查不到，而我们真正需要的是后者。
     */
    public static AnkiDroidTarget resolve(Context context) {
        final PackageManager pm = context.getPackageManager();
        for (final String candidate : CANDIDATE_PACKAGES) {
            final ProviderInfo info =
                pm.resolveContentProvider(authorityFor(candidate), 0);
            if (info != null) {
                return new AnkiDroidTarget(candidate);
            }
        }
        return null;
    }
}
