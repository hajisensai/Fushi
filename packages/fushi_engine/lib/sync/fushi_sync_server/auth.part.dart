part of '../fushi_sync_server.dart';

/// 认证域（B3 按域拆出）：auth 中间件、host token / peer token / Basic 校验、peer token 缓存。
/// 公开入口（start / stop / invalidatePeerTokenCache）留在 [FushiSyncServer] 本体；
/// 方法逐字搬自 FushiSyncServer，共享库私有作用域。
extension _FushiSyncServerAuth on FushiSyncServer {
  shelf.Middleware _authMiddleware() {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) async {
        // CORS 预检不带凭据，照旧直接放行。
        if (request.method == 'OPTIONS') return innerHandler(request);
        // 豁免判定与路由分发看同一张端点表、同一份规范化路径（[canonicalRequestPath]）：只有命中的那条
        // 路由（路径 × 方法）声明了免 Basic 的信任级才豁免；路径命中但方法不受理的请求照常走 Basic。
        // 解不出规范化路径（`%FF` 这类非法 UTF-8 转义）的请求无从路由，也无从判豁免：
        // 在这里统一回 400，不让它在鉴权前变成 500、也不进路由。
        final String path;
        try {
          path = canonicalRequestPath(request);
        } on FormatException {
          return shelf.Response(400, body: 'Malformed request path');
        }
        final InterconnectRouteLookup hit = _modules.lookup(
          path,
          request.method.toUpperCase(),
        );
        if (hit is InterconnectRouteHit) {
          switch (hit.route.trust) {
            case InterconnectCredentialTrust():
              break;
            case InterconnectPairingBootstrapTrust():
            case InterconnectProbeTrust():
            case InterconnectUrlTicketTrust():
              return innerHandler(request);
            case InterconnectQueryTicketTrust(:final validate):
              // 无效 / 缺省的 query 凭据落到下方 Basic。
              if (await validate(request)) return innerHandler(request);
          }
        }
        final auth = request.headers['authorization'];
        if (auth == null || !await _validateAuth(auth)) {
          return shelf.Response(
            401,
            headers: {'WWW-Authenticate': 'Basic realm="Fushi Sync"'},
          );
        }
        return innerHandler(request);
      };
    };
  }

  Future<bool> _validateAuth(String header) async {
    final String? password = _basicPassword(header);
    if (password == null) return false;
    try {
      // 兼容路径：共享 [_token] 仍受理（未重新配对的老设备继续可用，Never break
      // userspace）。常量时间比较防计时侧信道泄漏 token 前缀。
      if (_constantTimeEquals(
        Uint8List.fromList(utf8.encode(password)),
        Uint8List.fromList(utf8.encode(_token)),
      )) {
        return true;
      }
      // TODO-961 M1b：再比对任一未吊销的 per-peer token（含 legacy- 行，BUG-4393）。
      // 惰性加载 + 缓存，避免每请求打库；配对/吊销经 [invalidatePeerTokenCache]
      // 清缓存促重载。
      final _CredentialSnapshot credentials = await _credentialSnapshot();
      final Uint8List pw = Uint8List.fromList(utf8.encode(password));
      for (final String peerToken in <String>[
        ...credentials.peerTokens,
        ...credentials.legacyPeerTokens,
      ]) {
        if (_constantTimeEquals(
          pw,
          Uint8List.fromList(utf8.encode(peerToken)),
        )) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Sensitive service configuration is stricter than ordinary library APIs:
  /// it accepts only a currently paired device token, never the legacy shared
  /// server token nor a `legacy-` row token (BUG-4393: same rights as the
  /// shared token it replaces).
  Future<bool> _validatePeerAuth(String? header) async {
    if (header == null) return false;
    final String? password = _basicPassword(header);
    if (password == null) return false;
    final Uint8List supplied = Uint8List.fromList(utf8.encode(password));
    final _CredentialSnapshot credentials = await _credentialSnapshot();
    for (final String peerToken in credentials.peerTokens) {
      if (_constantTimeEquals(
        supplied,
        Uint8List.fromList(utf8.encode(peerToken)),
      )) {
        return true;
      }
    }
    return false;
  }

  /// 当前有效凭据快照（惰性加载 + 缓存 + 单飞）。无 provider 时 peer 集合为空——
  /// 只认共享 [_token]。
  ///
  /// 代际语义：加载期间若发生过 [invalidatePeerTokenCache]，这份结果读于吊销之前，
  /// 丢弃并按新代际重读；绝不把它写回缓存。加载失败照样抛给本次调用方，且不留在
  /// 单飞槽里，下一个请求重新读。
  Future<_CredentialSnapshot> _credentialSnapshot() async {
    while (true) {
      final _CredentialSnapshot? cached = _credentials;
      if (cached != null) return cached;
      final int gen = _credentialGeneration;
      final Future<_CredentialSnapshot> loading = _credentialsLoading ??=
          _loadCredentials();
      final _CredentialSnapshot loaded;
      try {
        loaded = await loading;
      } catch (_) {
        if (identical(_credentialsLoading, loading)) _credentialsLoading = null;
        rethrow;
      }
      if (gen == _credentialGeneration) {
        _credentials = loaded;
        if (identical(_credentialsLoading, loading)) _credentialsLoading = null;
        return loaded;
      }
    }
  }

  /// 优先 [FushiSyncServer.pairedPeerCredentialsProvider]（按 peerId 前缀把 legacy-
  /// 行分出去）；没接它时退回 [FushiSyncServer.pairedPeerTokensProvider]，全部当
  /// 已配对设备 token。
  Future<_CredentialSnapshot> _loadCredentials() async {
    final Future<Map<String, String>> Function()? credentials =
        pairedPeerCredentialsProvider;
    final Set<String> peerTokens = <String>{};
    final Set<String> legacyPeerTokens = <String>{};
    if (credentials != null) {
      for (final MapEntry<String, String> e in (await credentials()).entries) {
        (e.key.startsWith(kFushiLegacyPeerIdPrefix)
                ? legacyPeerTokens
                : peerTokens)
            .add(e.value);
      }
    } else {
      final Future<Set<String>> Function()? provider = pairedPeerTokensProvider;
      if (provider != null) peerTokens.addAll(await provider());
    }
    return _CredentialSnapshot(
      sharedToken: _token,
      peerTokens: peerTokens,
      legacyPeerTokens: legacyPeerTokens,
    );
  }

  /// 本请求 Basic 凭据的指纹；没有 / 解不出密码时 null。派生凭据（视频流 token、
  /// 原盘会话、查词音频 id）据此记签发者（BUG-4393）。
  String? _requestCredentialFingerprint(shelf.Request request) {
    final String? header = request.headers['authorization'];
    final String? password = header == null ? null : _basicPassword(header);
    return password == null ? null : _credentialFingerprint(password);
  }

  /// 签发者指纹仍在当前凭据快照里（共享 token 恒在；peer / legacy 行被吊销即不在）。
  Future<bool> _issuerStillValid(String? issuer) async =>
      issuer != null &&
      (await _credentialSnapshot()).fingerprints.contains(issuer);
}

// ── 本域私有的顶层 helper（原 FushiSyncServer 的 private static；extension 体内看不到
//    宿主类的 static，故提到库顶层）。

String? _basicPassword(String header) {
  if (!header.startsWith('Basic ')) return null;
  try {
    final String decoded = utf8.decode(
      base64Decode(header.substring('Basic '.length)),
    );
    final int colonIdx = decoded.indexOf(':');
    return colonIdx < 0 ? null : decoded.substring(colonIdx + 1);
  } catch (_) {
    return null;
  }
}
