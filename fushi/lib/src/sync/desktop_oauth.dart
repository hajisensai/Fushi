import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:url_launcher/url_launcher.dart';

/// Result of a desktop loopback OAuth flow: the authorization [code] plus the
/// exact [redirectUri] that was used (token exchange must echo the same value).
class DesktopOAuthResult {
  const DesktopOAuthResult({required this.code, required this.redirectUri});
  final String code;
  final String redirectUri;
}

/// 桌面 loopback 授权**已经拉起浏览器**之后交给 UI 的句柄（BUG-2120）。
///
/// 浏览器那半程完全在 app 之外：默认浏览器可能根本没弹出来，也可能弹出来却被该机器的
/// cookie / 扩展 / 代理弄成一张 Google 通用 400 页。这些 app 都看不见，唯一能做的是把
/// **那条授权链接本身**交到用户手里，让他自己换浏览器、开无痕、或者干脆放弃——而不是
/// 让他对着转圈干等 5 分钟超时。三个动作各自只做一件事：
///   * [authUrl]：拿去复制。
///   * [reopenBrowser]：用同一条链接再拉一次默认浏览器（第一次没弹出来的场景）。
///   * [cancel]：立刻结束等待，流程以 [SyncAuthFailureKind.cancelled] 收场。
class DesktopOAuthLaunch {
  const DesktopOAuthLaunch({
    required this.authUrl,
    required Future<bool> Function() reopenBrowser,
    required void Function() cancel,
  })  : _reopenBrowser = reopenBrowser,
        _cancel = cancel;

  /// 交给浏览器的那条授权 URL，与 [runDesktopOAuthLoopback] 实际拉起的逐字节相同。
  final Uri authUrl;
  final Future<bool> Function() _reopenBrowser;
  final void Function() _cancel;

  /// 再拉一次默认浏览器。返回值同 [launchUrl]。
  Future<bool> reopenBrowser() => _reopenBrowser();

  /// 用户主动放弃：等待立即结束，不再占着回环端口。重复调用无副作用。
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
/// 建模，而不是偷懒。[observe] 用作用域保证离开 body 就还原，不会把监听器漏到下一次。
abstract final class DesktopOAuthLaunchObserver {
  static DesktopOAuthLaunchListener? _current;

  /// 在 [body] 执行期间把 [listener] 接到 [runDesktopOAuthLoopback] 上；无论 body 正常
  /// 返回还是抛出，离开时都还原成之前的监听器。
  static Future<T> observe<T>(
    DesktopOAuthLaunchListener listener,
    Future<T> Function() body,
  ) async {
    final DesktopOAuthLaunchListener? previous = _current;
    _current = listener;
    try {
      return await body();
    } finally {
      _current = previous;
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
/// [onLaunched] fires once the browser has been asked to open the auth URL,
/// handing over a [DesktopOAuthLaunch] so the UI can offer copy / reopen /
/// cancel while the flow waits (BUG-2120). Defaults to whatever
/// [DesktopOAuthLaunchObserver.observe] scoped in — the backends never pass it
/// themselves.
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
    throw SyncAuthError(
      'Failed to start local OAuth listener on port '
      '${port == 0 ? 'auto' : port}: ${e.message}',
    );
  }

  try {
    // No trailing slash: providers match the redirect URI string exactly, and
    // the browser still hits this server at path "/" regardless.
    final redirectUri = 'http://$host:${server.port}';
    final authUrl = buildAuthUrl(redirectUri);

    Future<bool> openBrowser() =>
        launchUrl(authUrl, mode: LaunchMode.externalApplication);

    if (!await openBrowser()) {
      throw SyncAuthError('Failed to launch browser for authentication');
    }

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
        completer.complete(
          DesktopOAuthResult(code: code, redirectUri: redirectUri),
        );
      } else if (error != null) {
        completer.completeError(SyncAuthError('Authorization denied: $error'));
      }
      // Ignore unrelated requests (e.g. favicon) without completing.
    });

    final DesktopOAuthLaunchListener? listener =
        onLaunched ?? DesktopOAuthLaunchObserver._current;
    listener?.call(
      DesktopOAuthLaunch(
        authUrl: authUrl,
        reopenBrowser: openBrowser,
        cancel: () {
          if (completer.isCompleted) return;
          completer.completeError(
            SyncAuthError(
              'Sign-in cancelled by user',
              kind: SyncAuthFailureKind.cancelled,
            ),
          );
        },
      ),
    );

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw SyncAuthError(
          'Timed out waiting for authorization',
          // Typed, not guessed: the message contains "authorization", which the
          // error-message mapper's `contains('auth')` branch used to swallow as
          // "sign-in expired" — telling the user to re-authenticate when the
          // real problem is that the browser callback never reached us
          // (BUG-1348).
          kind: SyncAuthFailureKind.browserTimeout,
        ),
      );
    } finally {
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
