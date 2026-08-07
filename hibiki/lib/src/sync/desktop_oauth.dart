import 'dart:async';
import 'dart:io';

import 'package:fushi/src/sync/sync_backend.dart';
import 'package:url_launcher/url_launcher.dart';

/// Result of a desktop loopback OAuth flow: the authorization [code] plus the
/// exact [redirectUri] that was used (token exchange must echo the same value).
class DesktopOAuthResult {
  const DesktopOAuthResult({required this.code, required this.redirectUri});
  final String code;
  final String redirectUri;
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
Future<DesktopOAuthResult> runDesktopOAuthLoopback({
  required Uri Function(String redirectUri) buildAuthUrl,
  int port = 0,
  String host = 'localhost',
  Duration timeout = const Duration(minutes: 5),
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

    if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
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
        completer
            .complete(DesktopOAuthResult(code: code, redirectUri: redirectUri));
      } else if (error != null) {
        completer.completeError(SyncAuthError('Authorization denied: $error'));
      }
      // Ignore unrelated requests (e.g. favicon) without completing.
    });

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
  final title =
      success ? 'Hibiki — Sign-in complete' : 'Hibiki — Sign-in failed';
  final body = success
      ? 'You can close this tab and return to Hibiki.'
      : 'Authorization failed${error != null ? ': $error' : ''}. '
          'You can close this tab and try again in Hibiki.';
  return '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '<title>$title</title></head>'
      '<body style="font-family:sans-serif;text-align:center;padding:48px">'
      '<h2>$title</h2><p>$body</p></body></html>';
}
