import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:url_launcher/url_launcher.dart';

/// Result of a desktop loopback OAuth flow: the authorization [code] plus the
/// exact [redirectUri] that was used (token exchange must echo the same value).
class DesktopOAuthResult {
  const DesktopOAuthResult({required this.code, required this.redirectUri});
  final String code;
  final String redirectUri;
}

/// 桌面 loopback 授权的等待期句柄，交给 UI（BUG-2120）。
///
/// 浏览器那半程完全在 app 之外：默认浏览器可能根本没弹出来，也可能弹出来却被该机器的
/// cookie / 扩展 / 代理弄成一张 Google 通用 400 页。这些 app 都看不见，唯一能做的是把
/// **那条授权链接本身**交到用户手里，让他自己换浏览器、开无痕、或者干脆放弃——而不是
/// 让他对着转圈干等 5 分钟超时。
///
/// 句柄在回环端口 **bind 完成、浏览器尚未拉起** 时就交出：拉起失败恰恰是最需要链接的
/// 场景，不能等拉起成功才给。三个动作各自只做一件事：
///   * [authUrl]：拿去复制。
///   * [reopenBrowser]：用同一条链接再拉一次默认浏览器。
///   * [cancel]：立刻结束等待，流程以 [SyncAuthFailureKind.cancelled] 收场。
/// 两个信号：
///   * [browserOpened]：第一次拉起的结果，false 时 UI 该提示「请复制链接」。
///   * [finished]：回环等待结束（授权码到达 / 拒绝 / 超时 / 取消），UI 据此关闭——之后
///     是 token 交换，「等浏览器」已经过去，重开和取消都不再有意义。
class DesktopOAuthLaunch {
  const DesktopOAuthLaunch({
    required this.authUrl,
    required this.browserOpened,
    required this.finished,
    required Future<bool> Function() reopenBrowser,
    required void Function() cancel,
  })  : _reopenBrowser = reopenBrowser,
        _cancel = cancel;

  /// 交给浏览器的那条授权 URL，与 [runDesktopOAuthLoopback] 实际拉起的逐字节相同。
  final Uri authUrl;

  /// 第一次拉起默认浏览器是否成功。插件在 ShellExecute / xdg-open 失败时抛
  /// `PlatformException` 而不是回 false，这里已统一收成 false。
  final Future<bool> browserOpened;

  /// 回环等待结束即完成，永不抛错（错误由 [runDesktopOAuthLoopback] 本身抛给调用方）。
  final Future<void> finished;

  final Future<bool> Function() _reopenBrowser;
  final void Function() _cancel;

  /// 再拉一次默认浏览器。false = 没拉起来（含插件异常）。
  Future<bool> reopenBrowser() => _reopenBrowser();

  /// 用户主动放弃：等待立即结束，不再占着回环端口。回环已结束后调用无副作用。
  void cancel() => _cancel();
}

typedef DesktopOAuthLaunchListener = void Function(DesktopOAuthLaunch launch);

/// 进程级的「谁在看这次桌面授权」槽位。
///
/// 三个 OAuth 后端（Google Drive / Dropbox / OneDrive）都在各自 `authenticate()` 深处
/// 调 [runDesktopOAuthLoopback]，而想展示「复制链接 / 重开 / 取消」的是设置页。把监听器
/// 穿过 `SyncBackend.authenticate` 的签名意味着 10 个实现里 7 个无关后端（FTP / SFTP /
/// WebDAV / 互联…）都要接一个自己永远不用的参数；桌面授权同一时刻只可能有一条（UI 在
/// 等待期间禁用登录按钮，helper 还独占一个回环端口），一个进程级槽位是对现实的如实
/// 建模。槽位是一个栈而不是「记住上一个再还原」：用户在拉起浏览器的窗口期关掉设置页
/// 再回来重新登录，两次 observe 会**交错**结束——先结束的那次只能把自己从栈里剔掉，
/// 既不能抹掉后来者，也不能在后来者结束时把自己这个已经死掉的监听器还原回去。
abstract final class DesktopOAuthLaunchObserver {
  static final List<DesktopOAuthLaunchListener> _stack =
      <DesktopOAuthLaunchListener>[];

  static DesktopOAuthLaunchListener? get _current =>
      _stack.isEmpty ? null : _stack.last;

  /// 在 [body] 执行期间把 [listener] 接到 [runDesktopOAuthLoopback] 上；无论 body 正常
  /// 返回还是抛出，离开时都只移除自己。
  static Future<T> observe<T>(
    DesktopOAuthLaunchListener listener,
    Future<T> Function() body,
  ) async {
    _stack.add(listener);
    try {
      return await body();
    } finally {
      for (int i = _stack.length - 1; i >= 0; i--) {
        if (identical(_stack[i], listener)) {
          _stack.removeAt(i);
          break;
        }
      }
    }
  }

  @visibleForTesting
  static DesktopOAuthLaunchListener? get debugCurrent => _current;
}

/// Whether the current platform uses the desktop loopback OAuth flow instead
/// of a mobile custom-URI-scheme redirect.
bool get isDesktopOAuthPlatform =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Run the RFC 8252 loopback redirect OAuth flow for desktop platforms.
///
/// Binds a one-shot HTTP server on `127.0.0.1`, hands the resulting
/// `http://localhost:<port>/` redirect URI to [buildAuthUrl], opens the system
/// browser, and resolves with the authorization code captured from the
/// redirect. The server is always torn down before returning.
///
/// [port] of 0 binds an ephemeral port (use when the provider accepts any
/// loopback port, e.g. Microsoft Entra). Pass a fixed port for providers that
/// require an exact redirect-URI match (e.g. Dropbox).
///
/// [host] is the hostname written into the redirect URI. The server always
/// binds the IPv4 loopback interface, so `127.0.0.1` (RFC 8252 §7.3's
/// recommended form) is the honest, literal description of where the browser
/// must land. `localhost` — the default, kept because Dropbox and Entra have
/// that exact string registered — is a *name* that has to survive resolution
/// and proxy routing first: on Windows it usually resolves to `::1` before
/// `127.0.0.1`, and a proxy in global mode whose bypass list omits it will
/// happily forward the callback to the proxy instead of to this server. Either
/// way the code never arrives and the flow dies on [timeout] (BUG-1348).
/// Providers that accept any loopback redirect (Google desktop clients) should
/// pass `127.0.0.1`.
///
/// [onLaunched] receives the [DesktopOAuthLaunch] handle as soon as the
/// loopback port is bound — before the browser launch is awaited — so the UI
/// can offer copy / reopen / cancel even when the browser never opens
/// (BUG-2120). Defaults to whatever [DesktopOAuthLaunchObserver.observe]
/// scoped in; the backends never pass it themselves. With a listener attached a
/// failed browser launch is **not** fatal (the user holds the link); without one
/// it still throws as before.
Future<DesktopOAuthResult> runDesktopOAuthLoopback({
  required Uri Function(String redirectUri) buildAuthUrl,
  int port = 0,
  String host = 'localhost',
  Duration timeout = const Duration(minutes: 5),
  DesktopOAuthLaunchListener? onLaunched,
}) async {
  final HttpServer server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  } on SocketException catch (e) {
    throw SyncAuthError('Failed to start local OAuth listener on port '
        '${port == 0 ? 'auto' : port}: ${e.message}');
  }

  try {
    // No trailing slash: providers match the redirect URI string exactly, and
    // the browser still hits this server at path "/" regardless.
    final redirectUri = 'http://$host:${server.port}';
    final authUrl = buildAuthUrl(redirectUri);

    // 本仓钉的 url_launcher_windows / _linux 在 ShellExecuteW ≤ 32（含默认浏览器
    // 关联损坏）/ xdg-open 失败时抛 PlatformException 而不是回 false；两种都收成
    // false，让「浏览器没打开」成为一个可展示的状态而不是未捕获异常。
    Future<bool> openBrowser() async {
      try {
        return await launchUrl(authUrl, mode: LaunchMode.externalApplication);
      } on PlatformException {
        return false;
      }
    }

    // 所有收场（授权码 / 拒绝 / 超时 / 取消）都经由同一个 completer，句柄的 finished
    // 才能可靠地跟着结束——`.timeout()` 会另起一个 future 而让 completer 悬着。
    final completer = Completer<DesktopOAuthResult>();
    final subscription = server.listen((HttpRequest request) async {
      final code = request.uri.queryParameters['code'];
      final error = request.uri.queryParameters['error'];

      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(_resultPage(success: code != null, error: error));
      await request.response.close();

      if (completer.isCompleted) return;
      if (code != null) {
        completer
            .complete(DesktopOAuthResult(code: code, redirectUri: redirectUri));
      } else if (error != null) {
        completer.completeError(SyncAuthError('Authorization denied: $error'));
      }
      // Ignore unrelated requests (e.g. favicon) without completing.
    });
    final Timer timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      completer.completeError(SyncAuthError(
        'Timed out waiting for authorization',
        // Typed, not guessed: the message contains "authorization", which the
        // error-message mapper's `contains('auth')` branch used to swallow as
        // "sign-in expired" — telling the user to re-authenticate when the
        // real problem is that the browser callback never reached us
        // (BUG-1348).
        kind: SyncAuthFailureKind.browserTimeout,
      ));
    });

    try {
      final DesktopOAuthLaunchListener? listener =
          onLaunched ?? DesktopOAuthLaunchObserver._current;
      final Future<bool> opened = openBrowser();
      listener?.call(DesktopOAuthLaunch(
        authUrl: authUrl,
        browserOpened: opened,
        finished: completer.future
            .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
        reopenBrowser: openBrowser,
        cancel: () {
          if (completer.isCompleted) return;
          completer.completeError(SyncAuthError(
            'Sign-in cancelled by user',
            kind: SyncAuthFailureKind.cancelled,
          ));
        },
      ));
      if (!await opened && listener == null) {
        throw SyncAuthError('Failed to launch browser for authentication');
      }
      return await completer.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  } finally {
    await server.close(force: true);
  }
}

String _resultPage({required bool success, String? error}) {
  final title = success ? 'Fushi — Sign-in complete' : 'Fushi — Sign-in failed';
  final body = success
      ? 'You can close this tab and return to Hibiki.'
      : 'Authorization failed${error != null ? ': $error' : ''}. '
          'You can close this tab and try again in Hibiki.';
  return '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '<title>$title</title></head>'
      '<body style="font-family:sans-serif;text-align:center;padding:48px">'
      '<h2>$title</h2><p>$body</p></body></html>';
}
