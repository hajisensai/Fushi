// 旧的独立窗口宿主档 profile（`WebVideoWebView2-4k`）里的站点登录一次性迁进共享 cookie 罐。
//
// 2026-11 之前原生播放器页网页档（窗口宿主 4K 档）住在自己的 user data folder（浏览器参数带
// 哨兵、与 app 内浏览器不同 → 只能分目录）。现在它与浏览器共用 [MangaWebViewEnvironment] 的
// 目录，旧目录里用户已有的 Netflix / YouTube 等登录不迁的话，升级后播放页就掉登录。
//
// 只补缺：共享罐里已有同名同域同路径的 cookie 不覆盖（那是用户在浏览器里的登录，较新）；
// 旧目录原样留着不删（迁移失败可下次重试，用户也能手动回退）。全部写成（或重试满
// [kWebVideoLegacyLoginMaxAttempts] 次）后在旧目录写标记文件。写入与浏览器导入登录同一条路
// （[writeBrowserSiteCookies]：host-only 不带 domain），不另写一份 setCookie。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 旧目录里迁移完成的标记文件名。
const String kWebVideoLegacyLoginMigratedMarker = 'fushi_login_migrated';

/// 旧目录里记已尝试次数的文件名（有 cookie 没写进去时下次启动重试，最多
/// [kWebVideoLegacyLoginMaxAttempts] 次，免得一条永远被拒的 cookie 让每次启动都开一遍旧 profile）。
const String kWebVideoLegacyLoginAttemptsFile =
    'fushi_login_migration_attempts';

const int kWebVideoLegacyLoginMaxAttempts = 3;

/// 这一轮迁移之后算不算迁完（写标记、不再重试；纯函数）：要写的都写成了，或已试满
/// [kWebVideoLegacyLoginMaxAttempts] 次（[attempt] 从 1 起）。
bool webVideoLegacyLoginMigrationSettled({
  required int toWrite,
  required int written,
  required int attempt,
}) => written >= toWrite || attempt >= kWebVideoLegacyLoginMaxAttempts;

/// 旧窗口宿主档 profile 的目录（纯函数）：旧实现是可捕获档目录 + `-4k`；
/// `FUSHI_WEB_VIDEO_4K_USER_DATA_FOLDER` 覆盖时现在它就是共享罐本身，没有可迁的旧目录 → null。
String? webVideoLegacyWindowedUserDataFolder({
  required Map<String, String> environment,
  required String capturableFolder,
}) {
  final String? override = environment['FUSHI_WEB_VIDEO_4K_USER_DATA_FOLDER'];
  if (override != null && override.isNotEmpty) return null;
  return '$capturableFolder-4k';
}

/// 迁移判据（纯函数）：旧目录里确有 WebView2 profile（`EBWebView`）、还没迁过、且不是共享罐
/// 本身（Windows 路径大小写不敏感）。
bool webVideoLegacyLoginNeedsMigration({
  required String? legacyFolder,
  required String sharedFolder,
  required bool legacyProfileExists,
  required bool markerExists,
}) {
  if (legacyFolder == null || !legacyProfileExists || markerExists) {
    return false;
  }
  return legacyFolder.toLowerCase() != sharedFolder.toLowerCase();
}

/// cookie 的身份键：同名同域同路径才算同一条（域去掉前导点、小写）。
String webVideoCookieKey(Cookie cookie) {
  final String domain = (cookie.domain ?? '').toLowerCase();
  final String bare = domain.startsWith('.') ? domain.substring(1) : domain;
  return '${cookie.name}|$bare|${cookie.path ?? '/'}';
}

/// 旧罐里要写进共享罐的那些（纯函数）：共享罐没有同键的、值非空、有域名的。
List<Cookie> webVideoLegacyCookiesToMigrate({
  required List<Cookie> legacy,
  required List<Cookie> shared,
}) {
  final Set<String> present = <String>{
    for (final Cookie c in shared) webVideoCookieKey(c),
  };
  return <Cookie>[
    for (final Cookie c in legacy)
      if (c.name.isNotEmpty &&
          c.value.toString().isNotEmpty &&
          (c.domain ?? '').isNotEmpty &&
          !present.contains(webVideoCookieKey(c)))
        c,
  ];
}

/// 本进程内只迁一次（首个窗口宿主档开页时等它）；失败下次启动再试。
Future<void>? _migration;

/// 把旧窗口宿主档目录里的登录迁进共享罐 [shared]（[sharedFolder] 是它的目录）。只在 Windows
/// 上由 `webVideoWindowedEnvironment` 调；尽力而为，任何失败只记日志、不挡开页。
Future<void> migrateWebVideoLegacyLogin({
  required WebViewEnvironment shared,
  required String sharedFolder,
  required String capturableFolder,
}) {
  return _migration ??= _migrate(
    shared: shared,
    sharedFolder: sharedFolder,
    capturableFolder: capturableFolder,
  );
}

@visibleForTesting
void debugResetWebVideoLegacyLoginMigration() => _migration = null;

Future<void> _migrate({
  required WebViewEnvironment shared,
  required String sharedFolder,
  required String capturableFolder,
}) async {
  final String? legacyFolder = webVideoLegacyWindowedUserDataFolder(
    environment: Platform.environment,
    capturableFolder: capturableFolder,
  );
  if (legacyFolder == null) return;
  final File marker = File(
    '$legacyFolder${Platform.pathSeparator}$kWebVideoLegacyLoginMigratedMarker',
  );
  if (!webVideoLegacyLoginNeedsMigration(
    legacyFolder: legacyFolder,
    sharedFolder: sharedFolder,
    legacyProfileExists: Directory(
      '$legacyFolder${Platform.pathSeparator}EBWebView',
    ).existsSync(),
    markerExists: marker.existsSync(),
  )) {
    return;
  }
  WebViewEnvironment? legacy;
  try {
    // 旧目录此时没有别的环境在用（新代码不再开它），参数随意；给与共享罐相同的自动播放参数，
    // 不带哨兵。
    legacy = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: legacyFolder,
        additionalBrowserArguments: MangaWebViewEnvironment.kAutoplayArgument,
      ),
    );
    final List<Cookie> legacyCookies = await CookieManager.instance(
      webViewEnvironment: legacy,
    ).getAllCookies();
    final CookieManager dst = CookieManager.instance(
      webViewEnvironment: shared,
    );
    final List<BrowserSiteCookie> toWrite = <BrowserSiteCookie>[
      for (final Cookie c in webVideoLegacyCookiesToMigrate(
        legacy: legacyCookies,
        shared: await dst.getAllCookies(),
      ))
        ?BrowserSiteCookie.fromWebViewCookie(c),
    ];
    final int written = await writeBrowserSiteCookies(dst, toWrite);
    final File attempts = File(
      '$legacyFolder${Platform.pathSeparator}$kWebVideoLegacyLoginAttemptsFile',
    );
    final int attempt =
        (attempts.existsSync()
            ? int.tryParse((await attempts.readAsString()).trim()) ?? 0
            : 0) +
        1;
    if (!webVideoLegacyLoginMigrationSettled(
      toWrite: toWrite.length,
      written: written,
      attempt: attempt,
    )) {
      // 有 cookie 没写进去：不写标记，下次启动只补还缺的那些（已写成的共享罐里已有）。
      await attempts.writeAsString('$attempt');
      ErrorLogService.instance.log(
        'web_video',
        'legacy login migration attempt $attempt: wrote $written of '
            '${toWrite.length}, will retry',
      );
      return;
    }
    await marker.writeAsString(
      'migrated ${legacyCookies.length} cookies, wrote $written of '
      '${toWrite.length} into $sharedFolder (attempt $attempt) at '
      '${DateTime.now().toIso8601String()}\n',
    );
  } catch (e, stack) {
    ErrorLogService.instance.log('web_video.legacyLoginMigration', e, stack);
    // 不写标记：下次启动重试；本进程不再试（_migration 已定）。
  } finally {
    try {
      await legacy?.dispose();
    } catch (e) {
      ErrorLogService.instance.log('web_video', 'legacy env dispose: $e');
    }
  }
}
