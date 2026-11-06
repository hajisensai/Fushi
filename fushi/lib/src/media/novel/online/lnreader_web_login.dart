import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/mihon/mihon_web_login_page.dart';
import 'package:fushi/src/media/novel/online/lnreader_cloudflare.dart';
import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 小说源能不能在 app 里登录，以及登录页要打开哪个地址；不能则返回 null。
///
/// LNReader 插件的请求全部经宿主的 [LnReaderFetchBridge] 发出，桥给每个请求带上
/// 小说源自己的持久 jar（[LnReaderCloudflare.jar]）里匹配的 cookie。所以登录 =
/// 在 WebView 里登录源站、把整站 cookie 写进这份 jar——与漫画源桌面 sidecar 同一套
/// 登录页（[MihonWebLoginPage]），只是 jar 换成小说源的。
///
/// 两个条件缺一不可：有 jar（[cloudflare] 非空；单测构造的 manager 没有），以及
/// 插件的 `site` 能解析出 host。
Uri? lnReaderLoginTarget({
  required LnReaderCloudflare? cloudflare,
  required String site,
}) {
  if (cloudflare == null) return null;
  final Uri? parsed = Uri.tryParse(site.trim());
  if (parsed == null || parsed.host.isEmpty) return null;
  if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;
  return parsed;
}

/// 小说源的登录页：漫画源同一个 [MihonWebLoginPage]，jar 换成小说源自己的。
///
/// - UA 用桥的 [LnReaderFetchBridge.defaultUserAgent]：站点把会话或
///   `cf_clearance` 绑在 UA 上时，换了 UA 的请求不认这份会话。
/// - 「从浏览器导入」只在有 Fushi 浏览器扩展的平台（桌面）给。
///
/// 写进 [jar] 即生效：[jar] 是出站桥唯一的 cookie 存储，登完（含「从浏览器导入」
/// 后直接关页）下一个请求就带新会话，不依赖登录页怎么关。
MihonWebLoginPage buildLnReaderWebLoginPage({
  required LnReaderInstalledPlugin plugin,
  required Uri target,
  required MangaCookieJar jar,
  required bool isDesktop,
  @visibleForTesting Future<List<Cookie>> Function(WebUri url)? cookieReader,
  @visibleForTesting Widget Function(BuildContext context)? webViewBuilder,
  @visibleForTesting Future<WebViewEnvironment?> Function()? environmentFactory,
}) => MihonWebLoginPage(
  sourceName: plugin.name,
  baseUrl: target,
  jar: jar,
  userAgent: LnReaderFetchBridge.defaultUserAgent,
  browserImportAvailable: browserExtensionSupportedOn(isDesktop: isDesktop),
  cookieReader: cookieReader,
  webViewBuilder: webViewBuilder,
  environmentFactory: environmentFactory,
);

/// 推一页登录页并等用户登录完；返回 true = 用户点了「完成」、会话已写进小说源
/// 的 jar（调用方据此提示并重新加载）。
Future<bool> openLnReaderWebLogin(
  BuildContext context, {
  required LnReaderManager manager,
  required LnReaderInstalledPlugin plugin,
  @visibleForTesting bool? isDesktop,
  @visibleForTesting Future<List<Cookie>> Function(WebUri url)? cookieReader,
  @visibleForTesting Widget Function(BuildContext context)? webViewBuilder,
  @visibleForTesting Future<WebViewEnvironment?> Function()? environmentFactory,
}) async {
  final LnReaderCloudflare? cloudflare = manager.cloudflare;
  final Uri? target = lnReaderLoginTarget(
    cloudflare: cloudflare,
    site: plugin.site,
  );
  if (cloudflare == null || target == null) return false;
  final bool? saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      // 路由层中和界面整体缩放，WebView 才按真实视口栅格化（BUG-2522）。
      builder: (BuildContext _) => FushiAppUiScaleNeutralizer(
        child: buildLnReaderWebLoginPage(
          plugin: plugin,
          target: target,
          jar: cloudflare.jar,
          isDesktop: isDesktop ?? DesktopLookupService.isDesktop,
          cookieReader: cookieReader,
          webViewBuilder: webViewBuilder,
          environmentFactory: environmentFactory,
        ),
      ),
    ),
  );
  return saved == true;
}

/// 小说源「登录」：登录页 + 成功提示，源列表菜单与错误区按钮共用。
Future<bool> loginToLnReaderSource(
  BuildContext context, {
  required LnReaderManager manager,
  required LnReaderInstalledPlugin plugin,
}) async {
  final bool saved = await openLnReaderWebLogin(
    context,
    manager: manager,
    plugin: plugin,
  );
  if (saved) FushiToast.show(msg: t.mihon_source_login_saved);
  return saved;
}

/// 加载失败时给的「登录」按钮（小说浏览页、作品页错误区）。
///
/// 插件没登录时的表现各不相同（抛错、空列表、站点提示页），判不出「是不是因为没
/// 登录」，所以不猜：只要该源能在 app 里登录就在错误旁边给入口，不能则不占位。
class LnReaderLoginAction extends StatelessWidget {
  const LnReaderLoginAction({
    required this.manager,
    required this.plugin,
    required this.onLoggedIn,
    super.key,
  });

  final LnReaderManager manager;
  final LnReaderInstalledPlugin plugin;

  /// 登录成功后调用（页面据此重新加载）。
  final Future<void> Function() onLoggedIn;

  Future<void> _login(BuildContext context) async {
    final bool saved = await loginToLnReaderSource(
      context,
      manager: manager,
      plugin: plugin,
    );
    if (saved) await onLoggedIn();
  }

  @override
  Widget build(BuildContext context) {
    if (lnReaderLoginTarget(
          cloudflare: manager.cloudflare,
          site: plugin.site,
        ) ==
        null) {
      return const SizedBox.shrink();
    }
    return FushiFilledButton.tonalIcon(
      key: ValueKey<String>('novel_source_login_${plugin.id}'),
      onPressed: () => unawaited(_login(context)),
      icon: const FushiIcon(FushiIcons.login),
      label: Text(t.mihon_source_login),
    );
  }
}
