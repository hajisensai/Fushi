import 'package:fushi/src/lookup/browser_default_detector.dart';
import 'package:fushi/src/lookup/browser_extension_installer.dart';
import 'package:fushi/src/lookup/browser_extension_setup.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/utils.dart';
import 'package:url_launcher/url_launcher.dart';

/// 桌面「浏览器扩展」页（`BrowserExtensionPage`，安装助手）在控制通道上的条目。
///
/// 页面上的设置只有「Fushi API 服务器」开关与 API 密钥，它们已在 schema 里
/// （`local_services.fushi_api_server` / `local_services.fushi_api_key`），这里只声明页面独有的动作：
///
/// - `status`：服务 / 端口 / 是否已有 token / 内置与浏览器实际加载的扩展版本 /
///   最近连接时间 / 是否已连接 / 试用页地址；
/// - `prepare`：开服务 + 解压扩展，返回扩展目录（页面会顺手复制到剪贴板）；
/// - `verify`：轮询等待扩展连上（`--arg timeout=秒`）；
/// - `open_test_page` / `open_extensions_page`：在浏览器里打开试用页 / 扩展管理页。
///
/// 业务与页面同一份：`browser_extension_setup.dart`。
const String kCtlBrowserExtensionIdPrefix = 'lookup.browser_extension.cli.';

String _id(String name) => '$kCtlBrowserExtensionIdPrefix$name';

List<CtlBodyPage> buildCtlBrowserExtensionBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: '${t.settings_destination_lookup} › ${t.nav_browser_extension}',
    visible: (SettingsContext _) => DesktopLookupService.isDesktop,
    items: <SettingsItem>[
      _action(
        id: 'status',
        title: t.browser_extension_version_label,
        cli: const SettingsCliAction(run: browserExtensionStatusForCli),
      ),
      _action(
        id: 'prepare',
        title: t.browser_extension_prepare_button,
        subtitle: t.browser_extension_prepare_hint,
        cli: const SettingsCliAction(run: _prepare),
      ),
      _action(
        id: 'verify',
        title: t.browser_extension_verify_button,
        subtitle: t.browser_extension_step_verify,
        cli: const SettingsCliAction(
          run: _verify,
          params: <SettingsCliParam>[
            SettingsCliParam(
              'timeout',
              help: '最多等待秒数（1–120，默认 8）',
              required: false,
            ),
          ],
        ),
      ),
      _action(
        id: 'open_test_page',
        title: t.browser_extension_test_page_action,
        subtitle: t.browser_extension_test_page_action_desc,
        cli: const SettingsCliAction(run: _openTestPage),
      ),
      _action(
        id: 'open_extensions_page',
        title: t.browser_extension_step_open_page,
        cli: SettingsCliAction(
          run: _openExtensionsPage,
          params: <SettingsCliParam>[
            SettingsCliParam(
              'browser',
              help:
                  '${BrowserKind.values.map((BrowserKind k) => k.name).join(' | ')}'
                  '；省略 = 系统默认浏览器',
              required: false,
            ),
          ],
        ),
      ),
    ],
  ),
];

SettingsActionItem _action({
  required String id,
  required String title,
  required SettingsCliAction cli,
  String? subtitle,
}) {
  final SettingsCliRun? run = cli.run;
  return SettingsActionItem(
    id: _id(id),
    title: title,
    subtitle: subtitle,
    cli: cli,
    onTap: (SettingsContext c) async {
      if (run != null) await run(c, const <String, String>{});
    },
  );
}

/// `status` 的应答（也供测试断言）。不含 token 本身，只给「有没有」。
Future<Object?> browserExtensionStatusForCli(
  SettingsContext c,
  Map<String, String> _,
) async {
  final AppModel app = c.appModel;
  final DateTime? seen = app.browserExtensionLastSeenAt;
  final String? bundled = app.browserExtensionBuild;
  final String? reported = app.browserExtensionReportedBuild.value;
  return <String, Object?>{
    'serverEnabled': app.fushiApiServerEnabled,
    'port': app.fushiApiPort,
    'hasToken': app.fushiApiKey.isNotEmpty,
    'connected': isBrowserExtensionRecentlySeen(seen),
    'lastSeenAt': seen?.toIso8601String(),
    'bundledBuild': bundled,
    'browserBuild': reported,
    'needsReload': bundled != null && reported != null && bundled != reported,
    'testPageUrl': app.browserExtensionTestPageUrl,
  };
}

Future<Object?> _prepare(SettingsContext c, Map<String, String> _) async {
  final BrowserExtensionPrepareResult result =
      await prepareBrowserExtensionForInstall(c.appModel);
  return <String, Object?>{
    'directory': result.directory,
    'serverEnabled': result.serverEnabled,
    'hasToken': result.hasToken,
    'port': result.port,
    'portConflict': result.portConflict,
  };
}

Future<Object?> _verify(SettingsContext c, Map<String, String> args) async {
  final String? raw = args['timeout']?.trim();
  int seconds = 8;
  if (raw != null && raw.isNotEmpty) {
    final int? parsed = int.tryParse(raw);
    if (parsed == null || parsed < 1 || parsed > 120) {
      throw ArgumentError('timeout 要 1–120 的整数秒，收到「$raw」');
    }
    seconds = parsed;
  }
  final AppModel app = c.appModel;
  final bool connected = await waitForBrowserExtensionConnection(
    lastSeen: () => app.browserExtensionLastSeenAt,
    timeout: Duration(seconds: seconds),
  );
  return <String, Object?>{
    'connected': connected,
    'lastSeenAt': app.browserExtensionLastSeenAt?.toIso8601String(),
    'message': connected
        ? t.browser_extension_verify_connected
        : t.browser_extension_verify_not_detected,
  };
}

Future<Object?> _openTestPage(SettingsContext c, Map<String, String> _) async {
  final AppModel app = c.appModel;
  if (!app.fushiApiServerEnabled) {
    throw StateError(t.browser_extension_test_page_server_off);
  }
  final String url = app.browserExtensionTestPageUrl;
  final bool opened = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
  if (!opened) throw StateError('无法打开浏览器：$url');
  return <String, Object?>{'url': url};
}

Future<Object?> _openExtensionsPage(
  SettingsContext _,
  Map<String, String> args,
) async {
  final String? raw = args['browser']?.trim().toLowerCase();
  BrowserKind? kind;
  if (raw != null && raw.isNotEmpty) {
    kind = BrowserKind.values
        .where((BrowserKind k) => k.name == raw)
        .firstOrNull;
    if (kind == null) {
      throw ArgumentError(
        '未知浏览器「$raw」，可选：'
        '${BrowserKind.values.map((BrowserKind k) => k.name).join(' / ')}',
      );
    }
  } else {
    kind = await detectDefaultBrowserKind();
    if (kind == null) {
      throw StateError('系统默认浏览器不是受支持的 Chromium 系浏览器，请用 browser=<名> 指定');
    }
  }
  final String url = browserExtensionsPageUrl(kind);
  final bool opened = await tryOpenBrowserExtensionsPage(kind);
  if (!opened) throw StateError('${t.browser_extension_open_page_failed}：$url');
  return <String, Object?>{'browser': kind.name, 'url': url};
}
