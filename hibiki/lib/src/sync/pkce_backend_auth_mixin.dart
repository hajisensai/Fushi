import 'dart:convert';

import 'package:hibiki/src/sync/pkce_oauth.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:meta/meta.dart';

/// Dropbox / OneDrive 共用的 OAuth 2.0 PKCE 认证外壳（与
/// [SyncBackendFileTrioMixin] / [SyncFolderCache] 同款模式：挂在具体后端的
/// `with` 列表，`SyncBackend` 接口零变化——测试 fake 用 `implements SyncBackend`
/// 不受影响）。
///
/// handleAuthCode / 授权码兑换 / restoreAuth / refreshAuth / Bearer 授权头在
/// 两个后端曾逐字重复，收敛到这里一份；真实分叉——client id / token endpoint /
/// authorize URL / scopes / token 持久化键 / 用户信息端点——留在各后端，经
/// 下面的抽象成员注入。isAuthenticated / signOut（Dropbox 先 revoke，OneDrive
/// 不 revoke）/ 各自的 HTTP 错误映射不在此列，仍由各后端自持。
mixin PkceBackendAuthMixin on SyncBackend {
  /// 当前访问令牌（只存内存，不持久化）。子类的 HTTP 授权头、
  /// isAuthenticated、signOut 直接读写。
  @protected
  String? accessToken;

  /// 当前刷新令牌——持久化的唯一内容。
  @protected
  String? refreshToken;

  String? _pendingVerifier;
  SyncRepository? _pendingRepo;

  // ── 分叉点（各后端注入）───────────────────────────────────────────

  /// 该后端的 PKCE token 交换器（client id / token endpoint / 刷新附加参数）。
  @protected
  PkceOAuthFlow get oauthFlow;

  /// 移动端 custom-scheme redirect URI；兑换时必须与授权请求里发出的值一致。
  @protected
  String get mobileRedirectUri;

  /// 从 [repo] 读回持久化的 token JSON（各后端各自的偏好键）。
  @protected
  Future<String?> readStoredToken(SyncRepository repo);

  /// 把 token JSON 写进 [repo]（各后端各自的偏好键）。
  @protected
  Future<void> writeStoredToken(SyncRepository repo, String tokenJson);

  /// 拉取用户 email 供 UI 展示（各后端各自的用户信息端点；失败非致命，
  /// 由实现自吞）。
  @protected
  Future<void> fetchUserEmail();

  // ── 测试注入 ─────────────────────────────────────────────────────

  /// 测试注入点：非 null 时替换 [oauthFlow] 完成 fake 兑换（不打网络）。
  /// 生产路径恒为 null，不改变语义。
  @visibleForTesting
  PkceOAuthFlow? debugOAuthFlowOverride;

  PkceOAuthFlow get _effectiveOAuthFlow => debugOAuthFlowOverride ?? oauthFlow;

  /// 测试复位：清空令牌、未完成授权流与测试注入（后端是单例，跨测试隔离用）。
  @visibleForTesting
  void debugResetAuthState() {
    accessToken = null;
    refreshToken = null;
    _pendingVerifier = null;
    _pendingRepo = null;
    debugOAuthFlowOverride = null;
  }

  // ── 共享认证外壳 ─────────────────────────────────────────────────

  /// 清掉未完成的移动端授权流（authenticate 开始时防串台）。
  @protected
  void clearPendingAuth() {
    _pendingVerifier = null;
    _pendingRepo = null;
  }

  /// 记录移动端授权流的 verifier / repo，等浏览器带 code 回跳后由
  /// [handleAuthCode] 消费。
  @protected
  @visibleForTesting
  void setPendingAuth({
    required String verifier,
    required SyncRepository repo,
  }) {
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

    await exchangeAuthCode(
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
  Future<void> exchangeAuthCode({
    required String code,
    required String verifier,
    required String redirectUri,
    required SyncRepository repo,
  }) async {
    final PkceTokens tokens = await _effectiveOAuthFlow.exchangeCode(
      code: code,
      redirectUri: redirectUri,
      verifier: verifier,
    );
    accessToken = tokens.accessToken;
    refreshToken = tokens.refreshToken;

    await fetchUserEmail();
    await writeStoredToken(repo, jsonEncode({'refresh_token': refreshToken}));
  }

  @override
  Future<bool> restoreAuth(SyncRepository repo) async {
    final String? stored = await readStoredToken(repo);
    if (stored == null) return false;

    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
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
    if (refreshToken == null) {
      throw SyncAuthError('No refresh token available');
    }

    final PkceTokens tokens =
        await _effectiveOAuthFlow.refreshTokens(refreshToken: refreshToken!);
    accessToken = tokens.accessToken;
    // The provider may or may not return a new refresh token.
    if (tokens.refreshToken != null) {
      refreshToken = tokens.refreshToken;
    }
  }

  /// Bearer 授权头（JSON API 调用共用；上传/下载等自拼请求头的路径不经此）。
  @protected
  Map<String, String> get authHeaders => {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };
}
