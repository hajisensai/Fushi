package app.fushi.reader;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * 「用其他应用打开 / 分享到 Fushi」收到的 {@code content://} URI 能不能替对方读
 * （BUG-4752，{@code docs/bugs/BUG-4752-open-with-confused-deputy.md}）。纯函数，不碰 Android
 * 类型，JVM 单测 {@code OpenWithUriPolicyTest} 直接覆盖；{@link OpenWithChannel} 负责从
 * PackageManager / ContentResolver 取事实再交给这里裁决。
 *
 * <h2>威胁模型（confused deputy，CWE-441）</h2>
 * {@code MainActivity} 是 exported 的，任何 app 都能用显式 intent（不受 intent-filter 的 MIME
 * 限制）把任意 {@code content://} URI 塞给 Fushi，Fushi 随后以<b>自己的身份</b>
 * {@code openInputStream} 并把字节导入书库。发起方有没有给 URI 读授权，Fushi 侧拿不到可信
 * 信号：intent 上的 {@code FLAG_GRANT_READ_URI_PERMISSION} 是发起方随手可设的位；
 * {@code checkUriPermission(uri, myPid, myUid, ...)} 又把「对方授予的 URI grant」和「Fushi
 * 自己的静态权限」混在一起，分不出来。风险在于 Fushi 自己持有、发起方没有的读能力：
 * <ul>
 *   <li>AnkiDroid {@code READ_WRITE_DATABASE} 这类 dangerous / signature 权限保护的 exported provider；</li>
 *   <li>Fushi 自己的 provider（含带用户号前缀的 {@code 0@<本包>.provider} 写法：ContentResolver 会把
 *       {@code 0@foo} 当本用户的 {@code foo} 去连，旧实现却拿带前缀的 authority 去 resolve，查不到就放行）；</li>
 *   <li>Fushi 持久化过的 URI grant（例如 SAF 目录树授权）覆盖的 URI。</li>
 * </ul>
 * 读出的字节只进 Fushi 私有缓存 / 书库并在本机打开，发起方拿不回来，所以实际后果是「把用户
 * 别处的受保护内容静默塞进书库」，不是外泄；但这条读路径本身不该替无权者开门。
 *
 * <h2>判据</h2>
 * Fushi 只在「除了对方的 URI grant 之外没有别的途径读到」时才读：此时读得到就说明发起方本来
 * 有权并把权限授给了我们（系统只允许本身有权的一方授予 URI grant）。逐条：
 * <ol>
 *   <li>authority 缺失 / 用户号前缀非法 → 拒；</li>
 *   <li>URI 落在 Fushi 自己的持久化 URI grant 下 → 拒（分不清是不是对方这次授予的）；</li>
 *   <li>provider 属于 Fushi 自己 → 拒；</li>
 *   <li>provider 查不到 → 放行：Android 11+ 包可见性下，不可见包的 provider Fushi 自己也连不上，
 *       而授予了 Fushi URI grant 的 provider 对 Fushi 可见；Fushi 持有特权读权限的 provider
 *       （AnkiDroid 在 manifest {@code <queries>} 里、系统 provider 始终可见）都查得到，会走下面的分支；</li>
 *   <li>MediaStore（{@code media}）→ 放行：公共共享存储，文件管理器 / 相册 / 下载常用它；Fushi 凭
 *       存储权限自己也读得到，但内容是用户自己共享存储里的文件、导入后只留在本机，接受这一点；</li>
 *   <li>provider 未 exported（各 app 的 FileProvider 等）→ 放行：只能靠 URI grant 读；</li>
 *   <li>exported 且该路径生效的读权限（provider 级 readPermission + 匹配该路径的 path-permission）
 *       里有 Fushi 持有的<b>非 normal</b> 权限 → 拒：Fushi 凭自己的权限就能读，分不清对方是否有权。
 *       normal 级权限任何 app 声明即得，不构成特权；</li>
 *   <li>其余（无读权限的公开 provider、{@code MANAGE_DOCUMENTS} 保护的 SAF DocumentsProvider、
 *       Fushi 没有的权限保护的 provider）→ 放行：要么人人可读、要么只能靠 grant 读。</li>
 * </ol>
 * 局限：只在代码里自查调用方权限、manifest 不声明读权限的 provider 这里看不见；已知的只有
 * MediaStore，按第 5 条接受。以后若 Fushi 新增特权读权限，判据自动覆盖（看的是「是否持有」，
 * 不是写死的权限名单）。
 */
public final class OpenWithUriPolicy {
    /** MediaStore 的 authority（{@code android.provider.MediaStore.AUTHORITY}）。 */
    static final String MEDIA_STORE_AUTHORITY = "media";

    public enum Verdict {
        ALLOW,
        REJECT_BAD_AUTHORITY,
        REJECT_SELF_PERSISTED_GRANT,
        REJECT_OWN_PROVIDER,
        REJECT_SELF_PRIVILEGED_PERMISSION,
    }

    /** Fushi 是否持有某个读权限，且它不是 normal 级（任何 app 都能自声明的不算特权）。 */
    public interface PrivilegedPermissionCheck {
        boolean selfHoldsPrivileged(@NonNull String permission);
    }

    /** 目标 provider 的事实（来自 {@code PackageManager.resolveContentProvider}）。 */
    public static final class ProviderFacts {
        @NonNull final String packageName;
        final boolean exported;
        @Nullable final String readPermission;
        /** 匹配该 URI 路径的 path-permission 的读权限（由调用方用平台 PatternMatcher 筛好）。 */
        @NonNull final List<String> matchingPathReadPermissions;

        public ProviderFacts(
                @NonNull String packageName,
                boolean exported,
                @Nullable String readPermission,
                @Nullable List<String> matchingPathReadPermissions) {
            this.packageName = packageName;
            this.exported = exported;
            this.readPermission = readPermission;
            this.matchingPathReadPermissions = matchingPathReadPermissions == null
                    ? Collections.<String>emptyList()
                    : new ArrayList<>(matchingPathReadPermissions);
        }
    }

    private OpenWithUriPolicy() {
    }

    /**
     * 去掉 {@code <userId>@} 前缀，返回真正用来查 provider 的 authority；缺失或前缀非法返回 null
     * （与 {@code ContentProvider.getAuthorityWithoutUserId} / {@code getUserIdFromAuthority} 同义）。
     */
    @Nullable
    public static String bareAuthority(@Nullable String authority) {
        if (authority == null || authority.isEmpty()) return null;
        final int at = authority.lastIndexOf('@');
        if (at < 0) return authority;
        final String user = authority.substring(0, at);
        final String bare = authority.substring(at + 1);
        if (user.isEmpty() || bare.isEmpty()) return null;
        for (int i = 0; i < user.length(); i++) {
            final char c = user.charAt(i);
            if (c < '0' || c > '9') return null;
        }
        return bare;
    }

    /** 持久化 URI grant {@code granted} 是否覆盖 {@code target}（相等或是它的子路径）。 */
    public static boolean grantCovers(@NonNull String granted, @NonNull String target) {
        if (granted.equals(target)) return true;
        final String prefix = granted.endsWith("/") ? granted : granted + "/";
        return target.startsWith(prefix);
    }

    @NonNull
    public static Verdict decide(
            @NonNull String ownPackage,
            @Nullable String bareAuthority,
            @Nullable ProviderFacts provider,
            boolean selfHasPersistedGrant,
            @NonNull PrivilegedPermissionCheck permissions) {
        if (bareAuthority == null) return Verdict.REJECT_BAD_AUTHORITY;
        if (selfHasPersistedGrant) return Verdict.REJECT_SELF_PERSISTED_GRANT;
        if (provider == null) return Verdict.ALLOW;
        if (ownPackage.equals(provider.packageName)) return Verdict.REJECT_OWN_PROVIDER;
        if (MEDIA_STORE_AUTHORITY.equals(bareAuthority)) return Verdict.ALLOW;
        if (!provider.exported) return Verdict.ALLOW;
        if (provider.readPermission != null
                && permissions.selfHoldsPrivileged(provider.readPermission)) {
            return Verdict.REJECT_SELF_PRIVILEGED_PERMISSION;
        }
        for (String perm : provider.matchingPathReadPermissions) {
            if (perm != null && permissions.selfHoldsPrivileged(perm)) {
                return Verdict.REJECT_SELF_PRIVILEGED_PERMISSION;
            }
        }
        return Verdict.ALLOW;
    }
}
