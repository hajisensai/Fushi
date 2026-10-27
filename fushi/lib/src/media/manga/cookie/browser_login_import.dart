import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一次「从浏览器导入登录」的阶段。
enum BrowserLoginImportPhase {
  /// 没开始 / 已取消。
  idle,

  /// 已登记、已在系统浏览器打开站点，等 Fushi 浏览器扩展把本站 cookie 送回来。
  waiting,

  /// 收到本站 cookie、登记已结束，正在写进 cookie 存储。
  importing,

  /// 收到并写进了 [BrowserLoginImport.importedCount] 条。
  imported,

  /// 收到了本站 cookie，但一条都没写进去（或写的时候出错）。
  failed,
}

/// 「从浏览器导入登录」的唯一实现：app 内浏览器、视频站点网页档、漫画源登录页共用
/// （此前三处各写一份，生命周期各不相同）。
///
/// 流程：[begin] 登记本站（[BrowserCookieImportGate]）→ 在系统浏览器打开站点 → 扩展
/// 送回 cookie → 交给调用方的 [write]（写进各自的 cookie 存储并刷新页面）。
///
/// **一次登记只导一次**：扩展在该站每次页面加载 / 每分钟心跳都会重送 cookie，登记若一直
/// 挂着，用户之后每次在系统浏览器打开这个站，都会再往 app 里灌一批 cookie 并刷新页面。
/// 所以收到第一批**本站** cookie 就在派发回调里同步结束登记（同一 nonce 之后的回传一律
/// 409），再去写。只有别站 cookie 的一批不算，接着等。等待期间调用方挂
/// [BrowserLoginImportStatusBar]（可见、可取消）。还没在浏览器登录就送来的那批也算一次：
/// 状态条文案让用户先登录再点一次导入。
class BrowserLoginImport extends ChangeNotifier {
  BrowserLoginImport({
    required Future<int> Function(List<BrowserSiteCookie> cookies) write,
    Future<void> Function(Uri url)? openExternal,
    this.onImported,
    this.onFailed,
  }) : _write = write,
       _openExternal = openExternal ?? _launchExternal;

  final Future<int> Function(List<BrowserSiteCookie> cookies) _write;
  final Future<void> Function(Uri url) _openExternal;

  /// 写进了 [count] 条（调用方提示 / 刷新页面用）。
  final void Function(int count)? onImported;

  /// 收到了本站 cookie 但没写进去。
  final VoidCallback? onFailed;

  BrowserCookieImportRequestHandle? _handle;
  BrowserLoginImportPhase _phase = BrowserLoginImportPhase.idle;
  String? _host;
  int _importedCount = 0;
  bool _disposed = false;

  BrowserLoginImportPhase get phase => _phase;

  /// 正在等 / 上一次导入的站点（归一化 host）。
  String? get host => _host;

  /// 正在等扩展送回的站点；没在等为 null。
  String? get pendingHost =>
      _phase == BrowserLoginImportPhase.waiting ? _host : null;

  bool get waiting => _phase == BrowserLoginImportPhase.waiting;

  /// 上一次导入写进的条数。
  int get importedCount => _importedCount;

  static Future<void> _launchExternal(Uri url) async {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  /// 登记 [site] 的站点并在系统浏览器打开 [open]（默认站点根 `https://<host>/`）。
  /// 已在等时重新登记（新的 nonce，旧登记作废）。
  Future<void> begin(Uri site, {Uri? open}) async {
    final String host = BrowserCookieImportGate.normalizeHost(site.host);
    _handle?.end();
    final BrowserCookieImportRequestHandle handle =
        BrowserCookieImportGate.begin(host);
    _handle = handle;
    _host = host;
    _importedCount = 0;
    _phase = BrowserLoginImportPhase.waiting;
    // 句柄 end() 关闭 deliveries，订阅随之结束，不必另存。
    handle.deliveries.listen(
      (BrowserCookieDelivery delivery) => _onDelivery(handle, delivery),
    );
    _notify();
    try {
      await _openExternal(
        open ?? Uri(scheme: 'https', host: site.host, path: '/'),
      );
    } on Object catch (e) {
      // 打不开浏览器不撤登记：用户可以自己把站点打开，扩展照样会送；状态条可取消。
      ErrorLogService.instance.log('browser_login_import', 'open: $e');
    }
  }

  /// 用户取消：撤销登记，之后扩展的回传被拒（409）。
  void cancel() {
    if (_phase != BrowserLoginImportPhase.waiting) return;
    _handle?.end();
    _handle = null;
    _phase = BrowserLoginImportPhase.idle;
    _notify();
  }

  /// [BrowserCookieImportGate.deliver] 同步派发进来：在 deliver 返回之前结束登记。
  void _onDelivery(
    BrowserCookieImportRequestHandle handle,
    BrowserCookieDelivery delivery,
  ) {
    if (!identical(_handle, handle)) return;
    final List<BrowserSiteCookie> cookies = browserSiteCookiesForSite(
      delivery.cookies,
      handle.request.host,
    );
    // 没有本站 cookie 的一批不算导入（多半是别的站的心跳），接着等。
    if (cookies.isEmpty) return;
    handle.end();
    _handle = null;
    // 登记与「在等」同步结束：状态条立刻收起，不等写完。
    _phase = BrowserLoginImportPhase.importing;
    _notify();
    unawaited(_apply(cookies));
  }

  Future<void> _apply(List<BrowserSiteCookie> cookies) async {
    int written = 0;
    try {
      written = await _write(cookies);
    } on Object catch (e) {
      ErrorLogService.instance.log('browser_login_import', 'write: $e');
    }
    if (_disposed) return;
    _importedCount = written;
    _phase = written > 0
        ? BrowserLoginImportPhase.imported
        : BrowserLoginImportPhase.failed;
    _notify();
    if (written > 0) {
      onImported?.call(written);
    } else {
      onFailed?.call();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _handle?.end();
    _handle = null;
    super.dispose();
  }
}

/// [BrowserLoginImport] 的等待状态条：等扩展送回登录时显示（可取消），其余时候收起。
/// 出现 / 消失走尺寸动画，时长取 [FushiMotion]（减弱动态效果时归零）。
class BrowserLoginImportStatusBar extends StatelessWidget {
  const BrowserLoginImportStatusBar({
    required this.import,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 4),
    super.key,
  });

  final BrowserLoginImport import;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: import,
      builder: (BuildContext context, Widget? _) {
        final String? host = import.pendingHost;
        return AnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          alignment: Alignment.topCenter,
          child: host == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: padding,
                  child: FushiInlineNotice(
                    key: const ValueKey<String>('browser-login-import-waiting'),
                    icon: FushiIcons.login,
                    message: t.login_import_pending(host: host),
                    actions: <Widget>[
                      FushiTextButton(
                        key: const ValueKey<String>(
                          'browser-login-import-cancel',
                        ),
                        onPressed: import.cancel,
                        child: Text(t.cancel),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}
