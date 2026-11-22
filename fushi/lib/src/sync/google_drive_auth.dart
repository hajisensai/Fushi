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

import 'package:fushi/src/sync/desktop_oauth.dart';
import 'package:fushi/src/sync/google_drive_sync_space.dart';
import 'package:fushi/src/sync/google_oauth_secret.dart';
import 'package:fushi/src/sync/sync_backend.dart'
    show SyncAuthError, SyncAuthFailureKind;
import 'package:fushi/src/sync/sync_http.dart';
import 'package:fushi/src/sync/sync_repository.dart';

class GoogleDriveAuthError implements Exception {
  GoogleDriveAuthError(this.message, {this.cancelled = false});
  final String message;

  /// 用户自己取消了登录（移动端账号选择器点了返回）。与桌面 loopback 的
  /// `SyncAuthFailureKind.cancelled` 同一语义：不是错误，UI 静默（BUG-2120）。
  final bool cancelled;

  @override
  String toString() => 'GoogleDriveAuthError: $message';
}

class GoogleDriveAuth {
  GoogleDriveAuth._();
  static final GoogleDriveAuth instance = GoogleDriveAuth._();

  static bool get useMobileAuth => Platform.isAndroid || Platform.isIOS;

  // Drive 同步有两种存储空间（[GoogleDriveSyncSpace]），OAuth scope 随之切换：
  // - 默认 appData：`drive.appdata`——app 私有的隐藏空间，别的 app 看不到，历史
  //   默认（TODO-836：曾从可见 Drive scope 换来，避免全盘按名查触发跨 app 403）。
  // - Hoshi 兼容 ttuShared：完整 `drive`——才能读到 Hoshi 在可见 My Drive 建的
  //   文件（`drive.file` 只覆盖本 app 自己建的文件）。这是「与 Hoshi 共享」的必然
  //   代价，切换开关时强制重新授权（scope 在 consent 时固定，refresh 不能加 scope）。
  // scope 的真值源是 [GoogleDriveSyncSpace.scope]；此处仅保留 email scope 常量。
  static const _emailScope = 'https://www.googleapis.com/auth/userinfo.email';

  /// 当前 Drive 存储空间 + scope。默认隐藏 appDataFolder；开启「Hoshi 兼容模式」后
  /// 由 [GoogleDriveSyncBackend] 依偏好切到 [GoogleDriveSyncSpace.ttuShared]。
  GoogleDriveSyncSpace _space = GoogleDriveSyncSpace.appData;

  GoogleDriveSyncSpace get syncSpace => _space;

  /// 切换存储空间。scope 在 google_sign_in 客户端构造时固定，换 space 必须丢弃缓存的
  /// `_googleSignIn` 让下次 signIn 用新 scope。移动端已登录账号 [_mobileUser] 由调用方
  /// signOut 清理（scope 变更本就需要重新授权）。
  void setSyncSpace(GoogleDriveSyncSpace space) {
    if (space.id == _space.id) return;
    _space = space;
    _googleSignIn = null;
    _dropMobileClient();
  }

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

  // iOS 专用 OAuth 客户端（应用类型 = iOS，Bundle ID = app.fushi.reader）。
  // Android 不读这里：google_sign_in 在 Android 上从 google-services.json 按
  // 包名 + 签名 SHA-1 自动解析对应 client，传 null 即可。iOS 必须显式提供
  // iOS 型 clientId，且 Info.plist 需配反转 client id 的 URL scheme 作回调。
  static const _iosClientId =
      '963096957716-a5iep3fd7jqsef4vdb2c4nq7mm7i3rnn.apps.googleusercontent.com';

  static final _desktopClientId = auth.ClientId(
    _oauthClientId,
    _oauthClientSecret,
  );

  // ── Mobile (google_sign_in) ──────────────────────────────────────

  GoogleSignIn? _googleSignIn;
  GoogleSignIn get _signIn => _googleSignIn ??= GoogleSignIn(
    clientId: Platform.isIOS ? _iosClientId : null,
    scopes: [_space.scope],
  );

  // The signed-in mobile account, populated by authenticate() or by
  // restoreMobileAuth() on launch. google_sign_in does NOT auto-restore the
  // user across a cold start — `currentUser` is null and `isSignedIn()` is
  // unreliable — so the auth state and email must be driven off this cached
  // account rather than queried lazily (BUG-047).
  GoogleSignInAccount? _mobileUser;

  // 当前令牌对应的移动端 AuthClient（BUG-5169）。扩展的 `authenticatedClient()` 每调一次
  // 就新建一个 client，所以这里按令牌缓存：刷新 / 换账号 / 换 scope 才换新的，调用方
  // 拿到的 client 身份不变就说明令牌没换过。
  late final GoogleDriveMobileClientCache _mobileClients =
      GoogleDriveMobileClientCache(() => _signIn.authenticatedClient());
  Future<void>? _mobileRefreshInFlight;

  // ── Desktop (googleapis_auth) ────────────────────────────────────

  // 桌面会话的底层 HTTP 连接（BUG-5169）。整个会话只有这一个，令牌刷新只换外面那层
  // [_desktopClient] 包装（`authenticatedClient` 默认不拥有底层 client），绝不关它：
  // 同步各通道是并行跑的，刷新时别的通道手里的请求还在用这条连接。以前每次刷新都新建
  // 底层 client 并 `close()` 旧包装（closeUnderlyingClient: true），并发的 401 各自刷新、
  // 互相关掉对方刚换上的连接，handler 缓存下来的 DriveApi 指向已关闭的 client，之后每轮
  // 同步全部报「Client is already closed」直到重启。只在换会话（登录 / 恢复）与登出时关。
  http.Client? _desktopBaseClient;
  auth.AuthClient? _desktopClient;
  auth.AccessCredentials? _desktopCredentials;
  Future<void>? _desktopRefreshInFlight;
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

  /// 当前令牌对应的 AuthClient。令牌没换过时两次调用返回同一个实例；刷新后返回新实例
  /// ——调用方不要长期缓存它，每次发请求前取（BUG-5169）。
  Future<auth.AuthClient> getAuthClient() async {
    if (useMobileAuth) return _mobileClients.get();
    final client = _desktopClient;
    if (client == null) throw GoogleDriveAuthError('Not authenticated');
    return client;
  }

  /// 丢弃缓存的移动端 client（换令牌 / 账号 / scope 时），见 [GoogleDriveMobileClientCache.drop]。
  void _dropMobileClient() => _mobileClients.drop();

  /// 装入一个新的桌面会话（登录 / 恢复）。上一个会话的底层连接在这里关——这是换会话，
  /// 不是刷新令牌。
  auth.AuthClient _installDesktopSession(
    http.Client baseClient,
    auth.AccessCredentials credentials,
  ) {
    final http.Client? previousBase = _desktopBaseClient;
    _desktopBaseClient = baseClient;
    _desktopCredentials = credentials;
    final auth.AuthClient authClient = auth.authenticatedClient(
      baseClient,
      credentials,
    );
    _desktopClient = authClient;
    if (previousBase != null && !identical(previousBase, baseClient)) {
      previousBase.close();
    }
    return authClient;
  }

  /// 测试用：不走 OAuth，直接用（假的）[baseClient] 与 [credentials] 装一个桌面会话。
  @visibleForTesting
  auth.AuthClient debugInstallDesktopSession(
    http.Client baseClient,
    auth.AccessCredentials credentials,
  ) => _installDesktopSession(baseClient, credentials);

  Future<void> authenticate({SyncRepository? repo}) async {
    if (useMobileAuth) {
      final account = await _signIn.signIn();
      if (account == null) {
        throw GoogleDriveAuthError('Sign-in cancelled', cancelled: true);
      }
      _mobileUser = account;
      _dropMobileClient();
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
        'OAuth client secret (placeholder shipped)',
      );
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
    final http.Client baseClient = await createSyncHttpClient();
    bool installed = false;
    try {
      final result = await runDesktopOAuthLoopback(
        // 回环 **IP** 而非 `localhost`：Google 的桌面客户端接受任意回环 redirect（无需
        // 在 Console 预注册精确 URI），所以这里可以直接用 RFC 8252 §7.3 推荐的字面 IP，
        // 绕开「`localhost` 先解析到 ::1」和「全局代理 bypass 列表不含 localhost 就把回调
        // 转发给代理」这两条会让授权码永远回不来的路（BUG-1348 日志里 2 次 loopback
        // 超时）。Dropbox / Entra 注册的是 `localhost` 字符串，仍走默认值。
        host: '127.0.0.1',
        buildAuthUrl: (redirectUri) => _buildDesktopAuthUrl(
          redirectUri: redirectUri,
          challenge: challenge,
          scope: _space.scope,
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
          'Google did not return a refresh token; cannot stay signed in',
        );
      }

      // baseClient 从此归会话所有，下次换会话 / 登出时关；令牌刷新不关它（BUG-5169）。
      final authClient = _installDesktopSession(baseClient, credentials);
      installed = true;
      _cachedRepo = repo;
      await _fetchDesktopEmail(authClient);
      if (repo != null) await _persistDesktopCredentials(repo);
    } catch (e, st) {
      if (!installed) baseClient.close();
      // 用户在等待对话框里自己取消的（BUG-2120）：不是失败，不记带栈的失败日志。
      if (e is SyncAuthError && e.kind == SyncAuthFailureKind.cancelled) {
        rethrow;
      }
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
    required String scope,
  }) => Uri.https('accounts.google.com', 'o/oauth2/v2/auth', {
    'client_id': _oauthClientId,
    'response_type': 'code',
    'redirect_uri': redirectUri,
    'scope': [scope, _emailScope].join(' '),
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
  static Uri debugBuildDesktopAuthUrl(
    String redirectUri, {
    String scope = 'https://www.googleapis.com/auth/drive.appdata',
  }) => _buildDesktopAuthUrl(
    redirectUri: redirectUri,
    challenge: 'test-challenge',
    scope: scope,
  );

  @visibleForTesting
  static bool debugIsCredentialsRejected(Object error) =>
      _isCredentialsRejected(error);

  Future<bool> restoreDesktopAuth(SyncRepository repo) async {
    if (useMobileAuth) return false;

    final saved = await repo.getDesktopCredentials();
    if (saved == null) return false;

    final http.Client baseClient = await createSyncHttpClient();
    bool installed = false;
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

      final authClient = _installDesktopSession(baseClient, refreshed);
      installed = true;
      _cachedRepo = repo;
      await _fetchDesktopEmail(authClient);
      await _persistDesktopCredentials(repo);
      return true;
    } catch (e, st) {
      if (!installed) baseClient.close();
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

  /// 刷新访问令牌。
  ///
  /// [rejected] 是被服务端拒掉（401）的那个 client：它已经不是当前 client，说明别的
  /// 请求已经刷新过，直接返回，调用方重取 [getAuthClient] 重试即可。并发调用共用同一次
  /// 刷新（单飞），不会各自换一遍令牌（BUG-5169）。
  Future<void> refreshAuth({auth.AuthClient? rejected}) {
    if (useMobileAuth) {
      if (rejected != null && !identical(rejected, _mobileClients.current)) {
        return Future<void>.value();
      }
      return _mobileRefreshInFlight ??= _refreshMobile().whenComplete(
        () => _mobileRefreshInFlight = null,
      );
    }
    if (rejected != null && !identical(rejected, _desktopClient)) {
      return Future<void>.value();
    }
    return _desktopRefreshInFlight ??= _refreshDesktop().whenComplete(
      () => _desktopRefreshInFlight = null,
    );
  }

  Future<void> _refreshMobile() async {
    _mobileUser =
        await _signIn.signInSilently(reAuthenticate: true) ?? _mobileUser;
    _dropMobileClient();
  }

  Future<void> _refreshDesktop() async {
    final creds = _desktopCredentials;
    final http.Client? baseClient = _desktopBaseClient;
    if (creds == null || creds.refreshToken == null || baseClient == null) {
      developer.log(
        'Cannot refresh: no credentials cached',
        name: 'GoogleDriveAuth',
      );
      return;
    }

    try {
      // 用会话自己的底层连接换令牌，不新建、不关闭任何 client（BUG-5169）。
      final refreshed = await auth_io.refreshCredentials(
        _desktopClientId,
        creds,
        baseClient,
      );
      // 刷新途中会话被登出 / 换成新会话：这份令牌属于旧会话，丢弃。
      if (!identical(baseClient, _desktopBaseClient)) return;
      _desktopCredentials = refreshed;
      // 旧包装不 close：它不拥有底层连接，close 释放不了任何资源，只会让并行通道里
      // 还拿着它的请求失败。
      _desktopClient = auth.authenticatedClient(baseClient, refreshed);
      final repo = _cachedRepo;
      if (repo != null) await _persistDesktopCredentials(repo);
    } catch (e) {
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
      _dropMobileClient();
      return;
    }
    _desktopBaseClient?.close();
    _desktopBaseClient = null;
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
      (map['scopes'] as List?)?.cast<String>() ??
          <String>[GoogleDriveSyncSpace.appData.scope],
    );
  }
}

/// 移动端按令牌缓存的 AuthClient（BUG-5169）。
///
/// - 并发首调共用一次构造（缓存 in-flight future）。
/// - 构造失败（未登录返回 null、`getTokens` 抛网络 / PlatformException 等）**不留缓存**：
///   失败的 future 一旦钉住，之后每次请求都复读同一个错误，401 刷新路径也走不到，
///   同步卡死到重启——正是 BUG-5169 要消灭的那类症状。
/// - [drop] 之后才完成的旧构造不会回写成 [current]，否则迟到的 401 会拿旧 client 与
///   它比对成功、白白再刷新一次。
class GoogleDriveMobileClientCache {
  GoogleDriveMobileClientCache(this._create);

  final Future<auth.AuthClient?> Function() _create;
  Future<auth.AuthClient>? _pending;
  auth.AuthClient? _current;

  /// 当前缓存的 client（构造完成后才有）；[GoogleDriveAuth.refreshAuth] 用它判断
  /// 被拒的 client 是否已被换掉。
  auth.AuthClient? get current => _current;

  Future<auth.AuthClient> get() {
    final Future<auth.AuthClient>? cached = _pending;
    if (cached != null) return cached;
    final Future<auth.AuthClient> created = _build();
    _pending = created;
    // 先于调用方的 await 注册：调用方拿到 client 时 [current] 已经指向它。
    created.then<void>(
      (auth.AuthClient client) {
        if (identical(_pending, created)) _current = client;
      },
      onError: (Object _) {
        if (identical(_pending, created)) _pending = null;
      },
    );
    return created;
  }

  Future<auth.AuthClient> _build() async {
    final auth.AuthClient? client = await _create();
    if (client == null) throw GoogleDriveAuthError('Not authenticated');
    return client;
  }

  /// 丢弃缓存。不 close 旧 client：并行通道里的在途请求可能还在用它，没有引用后自然回收。
  void drop() {
    _pending = null;
    _current = null;
  }
}
