import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/manga/cookie/browser_login_import.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 视频站点网页档的「从浏览器导入登录」接入点：网页工具条的导入按钮 + 工具条下方的等待
/// 状态条共用这一个对象。实现仍是共用的 [BrowserLoginImport]（与 app 内浏览器、漫画源
/// 登录页同一份），这里只决定「导哪个站」与「何时建 / 何时拆」：
///
/// - 导入的站点取**当前页面地址**（站内跳到登录子域后仍按当前页），还没导航过时退回会话的
///   起始地址（[webVideoLoginImportSite]）；
/// - 第一次按下时才建 [BrowserLoginImport]，之后复用（再按一次 = 新登记、旧 nonce 作废）；
/// - 页面拆网页会话时 [dispose]，撤掉仍挂着的登记。
class WebVideoLoginImport extends ChangeNotifier {
  WebVideoLoginImport({
    required ({String currentUrl, String pageUrl})? Function() urls,
    required Future<int> Function(List<BrowserSiteCookie> cookies) write,
    required void Function(int count) onImported,
    required VoidCallback onFailed,
    Future<void> Function(Uri url)? openExternal,
  }) : _urls = urls,
       _write = write,
       _onImported = onImported,
       _onFailed = onFailed,
       _openExternal = openExternal;

  final ({String currentUrl, String pageUrl})? Function() _urls;
  final Future<int> Function(List<BrowserSiteCookie> cookies) _write;
  final void Function(int count) _onImported;
  final VoidCallback _onFailed;
  final Future<void> Function(Uri url)? _openExternal;

  BrowserLoginImport? _import;
  bool _disposed = false;

  /// 已经按过导入时的共用实现；没按过为 null。
  BrowserLoginImport? get import => _import;

  /// 正在等扩展把本站 cookie 送回来。
  bool get waiting => _import?.waiting ?? false;

  /// 登记当前站点并在系统浏览器里打开它。没有可导入的站点（会话未就绪 / 地址无 host）时
  /// 什么都不做。
  Future<void> begin() async {
    if (_disposed) return;
    final ({String currentUrl, String pageUrl})? urls = _urls();
    if (urls == null) return;
    final Uri? site = webVideoLoginImportSite(
      currentUrl: urls.currentUrl,
      pageUrl: urls.pageUrl,
    );
    if (site == null) return;
    BrowserLoginImport? import = _import;
    if (import == null) {
      import = BrowserLoginImport(
        write: _write,
        openExternal: _openExternal,
        onImported: _onImported,
        onFailed: _onFailed,
      )..addListener(_notify);
      _import = import;
      _notify();
    }
    await import.begin(site);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _import?.removeListener(_notify);
    _import?.dispose();
    _import = null;
    super.dispose();
  }
}

/// 网页档要导入登录的站点：当前页面地址优先，空时退回会话起始地址；解析不了或没有 host
/// 时为 null。
Uri? webVideoLoginImportSite({
  required String currentUrl,
  required String pageUrl,
}) {
  final Uri? page = Uri.tryParse(currentUrl.isNotEmpty ? currentUrl : pageUrl);
  if (page == null || page.host.isEmpty) return null;
  return page;
}

/// 网页工具条上的「从浏览器导入登录」按钮：等待中换成同步图标。
class WebVideoLoginImportButton extends StatelessWidget {
  const WebVideoLoginImportButton({required this.controller, super.key});

  final WebVideoLoginImport controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) => FushiIconButtonControl(
        key: const ValueKey<String>('video-web-login-import'),
        tooltip: t.web_video_login_import,
        icon: FushiIcon(
          controller.waiting ? FushiIcons.sync : FushiIcons.login,
        ),
        onPressed: () => unawaited(controller.begin()),
      ),
    );
  }
}

/// 网页工具条下方的等待状态条（可取消）；还没按过导入时不占位。
class WebVideoLoginImportStatusBar extends StatelessWidget {
  const WebVideoLoginImportStatusBar({required this.controller, super.key});

  final WebVideoLoginImport controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final BrowserLoginImport? import = controller.import;
        if (import == null) return const SizedBox.shrink();
        return BrowserLoginImportStatusBar(import: import);
      },
    );
  }
}
