import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/auth_io.dart' as auth_io;
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:http/http.dart' as http;

import 'package:hibiki/src/sync/desktop_oauth.dart';
import 'package:hibiki/src/sync/google_oauth_secret.dart';
import 'package:hibiki/src/sync/sync_repository.dart';

class GoogleDriveAuthError implements Exception {
  GoogleDriveAuthError(this.message);
  final String message;

  @override
  String toString() => 'GoogleDriveAuthError: $message';
}

class GoogleDriveAuth {
  GoogleDriveAuth._();
  static final GoogleDriveAuth instance = GoogleDriveAuth._();

  static bool get useMobileAuth => Platform.isAndroid || Platform.isIOS;

  // TODO-836: sync data now lives in the hidden, app-private appDataFolder
  // space (drive.appdata) instead of the user-visible Drive. The old
  // visible-Drive scope forced findOrCreateRootFolder's whole-Drive name
  // lookup to be a cross-app query → 403 insufficient_scope; drive.appdata
  // grants full access to the app's own hidden space so the appDataFolder
  // root lookup is in-scope. We REPLACE (not add) the old scope to keep the
  // grant minimal — no visible-Drive write access残留.
  static const _driveAppdataScope =
      'https://www.googleapis.com/auth/drive.appdata';
  static const _emailScope = 'https://www.googleapis.com/auth/userinfo.email';

  // 安装型应用（installed-app / PKCE）的 OAuth 凭据按 Google 设计属于非机密
  // 信息，会编译进二进制（见 HBK-AUDIT-072）。client_id 是公开标识，硬编码可接受
  // （与 Dropbox/OneDrive 后端一致）；client secret 虽同属非机密，但 GitGuardian
  // 会扫描告警，故真值移到 gitignored 的 google_oauth_secret.dart，仅作默认值引用，
  // 既不入库也不需每次构建带 flag。两者均保留 --dart-define 覆盖能力。
  static const _oauthClientId = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_ID',
    defaultValue:
        '963096957716-rmi74hd9mt8n4lvh6u32uqmkhcp2gkku.apps.googleusercontent.com',
  );
  static const _oauthClientSecret = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_SECRET',
    defaultValue: kGoogleOAuthClientSecret,
  );

  // The committed default in google_oauth_secret.dart / its .example.dart. A
  // build that still carries this value has no real desktop OAuth secret, so the
  // token exchange would fail with `invalid_client` 401 — but only AFTER the
  // user completed the browser consent flow. We detect it up front to fail fast
  // with an actionable message instead (TODO-045).
  static const _placeholderClientSecret =
      'YOUR_GOOGLE_DESKTOP_OAUTH_CLIENT_SECRET';

  /// The committed placeholder secret, exposed so tests can assert the predicate
  /// rejects exactly this value without re-hardcoding the literal (TODO-045).
  @visibleForTesting
  static const String debugPlaceholderClientSecret = _placeholderClientSecret;

  /// Pure predicate: does [secret] look like a real, usable desktop OAuth client
  /// secret (i.e. not the committed placeholder and not empty)? Split out from
  /// the [desktopCredentialsConfigured] getter so the rejection logic can be
  /// unit-tested against the placeholder string directly, instead of depending
  /// on whichever secret the running machine compiled in — a real GOCSPX- secret
  /// (any configured desktop build) would otherwise make the placeholder guard
  /// untestable (TODO-045).
  @visibleForTesting
  static bool isDesktopSecretConfigured(String secret) =>
      secret != _placeholderClientSecret && secret.isNotEmpty;

  /// True when this build shipped the placeholder OAuth secret (CI / a clone
  /// that never filled google_oauth_secret.dart). Desktop sign-in cannot work.
  static bool get desktopCredentialsConfigured =>
      isDesktopSecretConfigured(_oauthClientSecret);

  // iOS 专用 OAuth 客户端（应用类型 = iOS，Bundle ID = app.hibiki.reader）。
  // Android 不读这里：google_sign_in 在 Android 上从 google-services.json 按
  // 包名 + 签名 SHA-1 自动解析对应 client，传 null 即可。iOS 必须显式提供
  // iOS 型 clientId，且 Info.plist 需配反转 client id 的 URL scheme 作回调。
  static const _iosClientId =
      '963096957716-a9f20m4rsbenns50qn0l2cleq9cj5g0b.apps.googleusercontent.com';

  static final _desktopClientId = auth.ClientId(
    _oauthClientId,
    _oauthClientSecret,
  );

  // ── Mobile (google_sign_in) ──────────────────────────────────────

  GoogleSignIn? _googleSignIn;
  GoogleSignIn get _signIn => _googleSignIn ??= GoogleSignIn(
        clientId: Platform.isIOS ? _iosClientId : null,
        scopes: [_driveAppdataScope],
      );

  // The signed-in mobile account, populated by authenticate() or by
  // restoreMobileAuth() on launch. google_sign_in does NOT auto-restore the
  // user across a cold start — `currentUser` is null and `isSignedIn()` is
  // unreliable — so the auth state and email must be driven off this cached
  // account rather than queried lazily (BUG-047).
  GoogleSignInAccount? _mobileUser;

  // ── Desktop (googleapis_auth) ────────────────────────────────────

  auth.AuthClient? _desktopClient;
  auth.AccessCredentials? _desktopCredentials;
  SyncRepository? _cachedRepo;
  String? _desktopEmail;

  // ── Public API ───────────────────────────────────────────────────

  Future<bool> get isAuthenticated {
    // Drive off the rehydrated account, not isSignedIn(): the latter can report
    // true on a cold start while currentUser is still null (so no usable token
    // and no email), which surfaced as "已登录 / no account name" (BUG-047).
    if (useMobileAuth) return Future.value(_mobileUser != null);
    return Future.value(_desktopClient != null);
  }

  Future<String?> get currentEmail async {
    if (useMobileAuth) return _mobileUser?.email;
    return _desktopEmail;
  }

  /// Rehydrate the mobile (google_sign_in) session on launch. The plugin does
  /// not restore the signed-in user automatically, so the saved session must be
  /// revived explicitly via signInSilently() — mirroring restoreDesktopAuth on
  /// desktop. Without this the account row showed "未登录" and auto-sync never
  /// passed its isAuthenticated gate after an app restart (BUG-047). Returns
  /// whether a signed-in account was recovered.
  Future<bool> restoreMobileAuth() async {
    if (!useMobileAuth) return false;
    if (_mobileUser != null) return true;
    _mobileUser = await _signIn.signInSilently();
    return _mobileUser != null;
  }

  Future<auth.AuthClient> getAuthClient() async {
    if (useMobileAuth) {
      final client = await _signIn.authenticatedClient();
      if (client == null) throw GoogleDriveAuthError('Not authenticated');
      return client;
    }
    final client = _desktopClient;
    if (client == null) throw GoogleDriveAuthError('Not authenticated');
    return client;
  }

  Future<void> authenticate({SyncRepository? repo}) async {
    if (useMobileAuth) {
      final account = await _signIn.signIn();
      if (account == null) {
        throw GoogleDriveAuthError('Sign-in cancelled');
      }
      _mobileUser = account;
      return;
    }
    // Fail fast when the build has no real desktop OAuth secret (placeholder
    // shipped, e.g. a CI desktop build): the code exchange would otherwise
    // succeed in the browser and only then blow up with `invalid_client` 401,
    // confusing the user with a "sign-in expired" message. The marker string is
    // matched by sync_error_messages.dart to show sync_err_not_configured
    // (TODO-045).
    if (!desktopCredentialsConfigured) {
      throw GoogleDriveAuthError(
          'sync_credentials_not_configured: this build has no Google desktop '
          'OAuth client secret (placeholder shipped)');
    }
    // Desktop: drive the RFC 8252 loopback flow ourselves (same helper as the
    // Dropbox/OneDrive backends) so we fully control the authorization URL.
    // googleapis_auth's clientViaUserConsent never sends `access_type=offline`,
    // so Google returns NO refresh token and the session dies on the next app
    // restart (BUG-034). We request offline access + `prompt=consent` to
    // guarantee a durable refresh token even when the account already
    // authorized the app, then exchange the code through googleapis_auth
    // (whose refreshCredentials carries the refresh token forward).
    final verifier = _createCodeVerifier();
    final challenge = _codeChallenge(verifier);
    final baseClient = http.Client();
    try {
      final result = await runDesktopOAuthLoopback(
        buildAuthUrl: (redirectUri) => _buildDesktopAuthUrl(
          redirectUri: redirectUri,
          challenge: challenge,
        ),
      );
      final credentials = await auth_io.obtainAccessCredentialsViaCodeExchange(
        baseClient,
        _desktopClientId,
        result.code,
        redirectUrl: result.redirectUri,
        codeVerifier: verifier,
      );
      if (credentials.refreshToken == null) {
        // With access_type=offline + prompt=consent Google always returns a
        // refresh token; bail rather than persist a session that could never
        // be restored after a restart.
        throw GoogleDriveAuthError(
            'Google did not return a refresh token; cannot stay signed in');
      }

      _desktopClient?.close();
      _desktopCredentials = credentials;
      // closeUnderlyingClient: a later _desktopClient.close() must also close
      // baseClient — authenticatedClient does NOT own it by default, so without
      // this every re-auth / refresh / signOut leaks the HTTP client.
      final authClient = auth.authenticatedClient(
        baseClient,
        credentials,
        closeUnderlyingClient: true,
      );
      _desktopClient = authClient;
      _cachedRepo = repo;
      await _fetchDesktopEmail(authClient);
      if (repo != null) await _persistDesktopCredentials(repo);
    } catch (e, st) {
      baseClient.close();
      // Log the raw failure so the real root cause — invalid_client /
      // redirect_uri_mismatch / access_denied / a blocked-direct-connection
      // timeout — is visible instead of a friendly-mapped or bare HTTP error.
      developer.log(
        'Desktop Google OAuth failed: ${e.runtimeType}: $e',
        error: e,
        stackTrace: st,
        name: 'GoogleDriveAuth',
      );
      rethrow;
    }
  }

  // ── Desktop authorization URL + PKCE ─────────────────────────────

  static Uri _buildDesktopAuthUrl({
    required String redirectUri,
    required String challenge,
  }) =>
      Uri.https('accounts.google.com', 'o/oauth2/v2/auth', {
        'client_id': _oauthClientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'scope': [_driveAppdataScope, _emailScope].join(' '),
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        // Required for Google to issue a refresh token; without it the desktop
        // session cannot survive an app restart (BUG-034).
        'access_type': 'offline',
        // Force the consent screen so a refresh token is returned even when the
        // account previously authorized the app; offer the account chooser so
        // multi-account users can pick which Google account to use.
        'prompt': 'consent select_account',
      });

  static String _createCodeVerifier() {
    final rng = Random.secure();
    final bytes = List<int>.generate(64, (_) => rng.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _codeChallenge(String verifier) {
    final digest = sha256.convert(ascii.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  /// Whether [error] means Google actually rejected the refresh token
  /// (invalid_grant / revoked / disabled → HTTP 400/401/403), as opposed to a
  /// transient failure (offline, a blocked/timed-out direct connection, a 5xx).
  /// Only a true rejection should drop the saved desktop session (BUG-034).
  static bool _isCredentialsRejected(Object error) {
    if (error is auth.AccessDeniedException) return true;
    return error is auth.ServerRequestFailedException &&
        (error.statusCode == 400 ||
            error.statusCode == 401 ||
            error.statusCode == 403);
  }

  @visibleForTesting
  static Uri debugBuildDesktopAuthUrl(String redirectUri) =>
      _buildDesktopAuthUrl(
        redirectUri: redirectUri,
        challenge: 'test-challenge',
      );

  @visibleForTesting
  static bool debugIsCredentialsRejected(Object error) =>
      _isCredentialsRejected(error);

  Future<bool> restoreDesktopAuth(SyncRepository repo) async {
    if (useMobileAuth) return false;

    final saved = await repo.getDesktopCredentials();
    if (saved == null) return false;

    final http.Client baseClient = http.Client();
    try {
      final credentials = _deserializeCredentials(saved);
      if (credentials.refreshToken == null) {
        baseClient.close();
        return false;
      }

      final refreshed = await auth_io.refreshCredentials(
        _desktopClientId,
        credentials,
        baseClient,
      );

      _desktopClient?.close();
      _desktopCredentials = refreshed;
      final authClient = auth.authenticatedClient(
        baseClient,
        refreshed,
        closeUnderlyingClient: true,
      );
      _desktopClient = authClient;
      _cachedRepo = repo;
      await _fetchDesktopEmail(authClient);
      await _persistDesktopCredentials(repo);
      return true;
    } catch (e, st) {
      baseClient.close();
      developer.log(
        'Failed to restore desktop auth: ${e.runtimeType}: $e',
        error: e,
        stackTrace: st,
        name: 'GoogleDriveAuth',
      );
      // Only drop the saved credentials when Google actually rejected the
      // refresh token. A transient failure — offline at startup, a
      // blocked/timed-out direct connection (common on restrictive networks),
      // a 5xx — must NOT wipe a still-valid session, or the next launch is a
      // spurious sign-out (BUG-034).
      if (_isCredentialsRejected(e)) {
        await repo.clearDesktopSession();
      }
      return false;
    }
  }

  Future<void> refreshAuth() async {
    if (useMobileAuth) {
      _mobileUser =
          await _signIn.signInSilently(reAuthenticate: true) ?? _mobileUser;
      return;
    }

    final creds = _desktopCredentials;
    if (creds == null || creds.refreshToken == null) {
      developer.log(
        'Cannot refresh: no credentials cached',
        name: 'GoogleDriveAuth',
      );
      return;
    }

    final baseClient = http.Client();
    try {
      final refreshed = await auth_io.refreshCredentials(
        _desktopClientId,
        creds,
        baseClient,
      );
      _desktopCredentials = refreshed;
      _desktopClient?.close();
      _desktopClient = auth.authenticatedClient(
        baseClient,
        refreshed,
        closeUnderlyingClient: true,
      );
      final repo = _cachedRepo;
      if (repo != null) await _persistDesktopCredentials(repo);
    } catch (e) {
      baseClient.close();
      developer.log(
        'Desktop token refresh failed',
        error: e,
        name: 'GoogleDriveAuth',
      );
    }
  }

  Future<void> signOut({SyncRepository? repo}) async {
    if (useMobileAuth) {
      await _signIn.signOut();
      _mobileUser = null;
      return;
    }
    _desktopClient?.close();
    _desktopClient = null;
    _desktopCredentials = null;
    _desktopEmail = null;
    _cachedRepo = null;
    if (repo != null) await repo.clearDesktopSession();
  }

  // ── Desktop user info ─────────────────────────────────────────────

  static const _userinfoUrl = 'https://www.googleapis.com/oauth2/v2/userinfo';

  Future<void> _fetchDesktopEmail(http.Client client) async {
    try {
      final response = await client.get(Uri.parse(_userinfoUrl));
      if (response.statusCode == 200) {
        final info = jsonDecode(response.body) as Map<String, dynamic>;
        _desktopEmail = info['email'] as String?;
      }
    } catch (e) {
      developer.log(
        'Failed to fetch user email',
        error: e,
        name: 'GoogleDriveAuth',
      );
    }
  }

  // ── Credential serialization ─────────────────────────────────────

  Future<void> _persistDesktopCredentials(SyncRepository repo) async {
    final creds = _desktopCredentials;
    if (creds == null) return;
    await repo.setDesktopCredentials(_serializeCredentials(creds));
  }

  static String _serializeCredentials(auth.AccessCredentials creds) {
    return jsonEncode({
      'type': creds.accessToken.type,
      'data': creds.accessToken.data,
      'expiry': creds.accessToken.expiry.toIso8601String(),
      'refreshToken': creds.refreshToken,
      'scopes': creds.scopes.toList(),
    });
  }

  static auth.AccessCredentials _deserializeCredentials(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    return auth.AccessCredentials(
      auth.AccessToken(
        map['type'] as String,
        map['data'] as String,
        DateTime.parse(map['expiry'] as String),
      ),
      map['refreshToken'] as String?,
      (map['scopes'] as List?)?.cast<String>() ?? [_driveAppdataScope],
    );
  }
}
