import 'dart:convert';

import 'package:flutter/foundation.dart' show protected;
import 'package:fushi/src/sync/desktop_oauth.dart';
import 'package:fushi/src/sync/pkce_oauth.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:url_launcher/url_launcher.dart';

/// OAuth 2.0 PKCE 后端（Dropbox / OneDrive）共用的认证外壳。
///
/// [PkceOAuthFlow] 只负责 token 端点的两次交换；这层再往上——桌面 loopback /
/// 移动 custom-scheme 两条授权流、pending verifier 的持有与消费、refresh token
/// 落库与恢复、过期刷新、Bearer 头拼装——两个后端原本各写一份逐字相同的实现
/// （2026-07-24 审查 §三-1）。这里收成一份，后端只剩真正因 provider 而异的部分：
/// 授权 URL 的查询参数、token 在 [SyncRepository] 里的存取键、用户邮箱的 API、
/// 以及 Dropbox 独有的登出 revoke。
///
/// 语义与抽出前逐字一致：
/// * 恢复时刷新失败要把两个 token 都清掉，让 `isAuthenticated` 如实报 false，
///   而不是带着过期 token 进同步再在不可重试的 401 上打转（HBK-AUDIT-159）。
/// * 刷新响应缺 `refresh_token` 时保留旧值（provider 可能不回新的）。
mixin PkceOAuthBackendMixin on SyncBackend {
  // ── provider 差异钩子 ──────────────────────────────────────────────

  /// 本 provider 的 token 交换（client id / token endpoint / 刷新额外参数）。
  @protected
  PkceOAuthFlow get oauth;

  /// 错误文案里的 provider 名（`Dropbox` / `OneDrive`）。
  @protected
  String get providerName;

  /// 移动端 custom-scheme 回跳地址；桌面端的 loopback 地址由
  /// [runDesktopOAuthLoopback] 生成后经 [buildAuthUrl] 传回。
  @protected
  String get mobileRedirectUri;

  /// 桌面 loopback 固定端口；0 = 临时端口。Dropbox 要求回跳地址精确匹配，
  /// 必须固定；OneDrive 允许任意 localhost 端口。
  @protected
  int get desktopLoopbackPort => 0;

  /// 授权页 URL；`code_challenge` 已按 S256 算好，其余查询参数各 provider 自定。
  @protected
  Uri buildAuthUrl(String challenge, String redirectUri);

  /// 读 / 写落库的 token JSON（`{"refresh_token": ...}`）；`null` = 清除。
  @protected
  Future<String?> readStoredToken(SyncRepository repo);
  @protected
  Future<void> writeStoredToken(SyncRepository repo, String? token);

  /// 取当前账号邮箱写进 [email]。**不得抛出**——邮箱只作展示，失败非致命。
  @protected
  Future<void> fetchUserEmail();

  // ── 共享状态 ────────────────────────────────────────────────────────

  @protected
  String? accessToken;
  @protected
  String? refreshToken;
  @protected
  String? email;

  String? _pendingVerifier;
  SyncRepository? _pendingRepo;

  @override
  Future<bool> get isAuthenticated async => accessToken != null;

  @override
  Future<String?> get currentEmail async => email;

  /// `Authorization: Bearer` + JSON 内容类型，普通 API 调用的默认头。
  @protected
  Map<String, String> get bearerJsonHeaders => <String, String>{
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  // ── 授权流 ──────────────────────────────────────────────────────────

  @override
  Future<void> authenticate({required SyncRepository repo}) async {
    if (oauth.clientId.startsWith('YOUR_')) {
      throw SyncAuthError('$providerName integration not configured');
    }
    _pendingVerifier = null;
    _pendingRepo = null;

    final String verifier = PkceOAuthFlow.generateCodeVerifier();
    final String challenge = PkceOAuthFlow.codeChallenge(verifier);

    // Desktop: loopback HTTP redirect (RFC 8252), exchange inline.
    if (isDesktopOAuthPlatform) {
      final DesktopOAuthResult result = await runDesktopOAuthLoopback(
        buildAuthUrl: (String redirectUri) =>
            buildAuthUrl(challenge, redirectUri),
        port: desktopLoopbackPort,
      );
      await exchangeCode(
        code: result.code,
        verifier: verifier,
        redirectUri: result.redirectUri,
        repo: repo,
      );
      return;
    }

    // Mobile: custom-URI-scheme redirect handled later by [handleAuthCode].
    final Uri authUrl = buildAuthUrl(challenge, mobileRedirectUri);
    if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
      throw SyncAuthError('Failed to launch browser for $providerName auth');
    }

    _pendingVerifier = verifier;
    _pendingRepo = repo;
  }

  /// Called when the app receives the redirect URI with an auth code (mobile
  /// custom-scheme flow).
  Future<void> handleAuthCode(String code) async {
    final String? verifier = _pendingVerifier;
    final SyncRepository? repo = _pendingRepo;
    if (verifier == null || repo == null) {
      throw SyncAuthError('No pending auth flow');
    }
    _pendingVerifier = null;
    _pendingRepo = null;

    await exchangeCode(
      code: code,
      verifier: verifier,
      redirectUri: mobileRedirectUri,
      repo: repo,
    );
  }

  /// Exchange an authorization code for tokens. [redirectUri] must match the
  /// value sent in the authorization request (custom scheme on mobile, the
  /// loopback URL on desktop).
  @protected
  Future<void> exchangeCode({
    required String code,
    required String verifier,
    required String redirectUri,
    required SyncRepository repo,
  }) async {
    final PkceTokens tokens = await oauth.exchangeCode(
      code: code,
      redirectUri: redirectUri,
      verifier: verifier,
    );
    accessToken = tokens.accessToken;
    refreshToken = tokens.refreshToken;

    await fetchUserEmail();
    await writeStoredToken(repo, jsonEncode({'refresh_token': refreshToken}));
  }

  /// 清 token 与邮箱、清文件夹缓存、删落库 token。有 revoke 步骤的 provider
  /// 先 revoke 再 `super.signOut`。
  @override
  Future<void> signOut({required SyncRepository repo}) async {
    accessToken = null;
    refreshToken = null;
    email = null;
    clearCache();
    await writeStoredToken(repo, null);
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    final String? stored = await readStoredToken(repo);
    if (stored == null) return false;

    try {
      final Map<String, dynamic> json =
          jsonDecode(stored) as Map<String, dynamic>;
      refreshToken = json['refresh_token'] as String?;
      if (refreshToken == null) return false;

      await refreshAuth();
      await fetchUserEmail();
      return true;
    } catch (_) {
      // Refresh failed — drop the stale tokens so isAuthenticated reports
      // false instead of letting sync proceed with an expired token and loop
      // on non-retryable 401s (HBK-AUDIT-159).
      accessToken = null;
      refreshToken = null;
      return false;
    }
  }

  @override
  Future<void> refreshAuth() async {
    final String? current = refreshToken;
    if (current == null) {
      throw SyncAuthError('No refresh token available');
    }

    final PkceTokens tokens = await oauth.refreshTokens(refreshToken: current);
    accessToken = tokens.accessToken;
    // The provider may or may not return a new refresh token.
    if (tokens.refreshToken != null) {
      refreshToken = tokens.refreshToken;
    }
  }
}
