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
        // 豁免判定与路由分发看同一份规范化路径（[canonicalRequestPath]），且只对
        // [_kPublicRoutes] 里登记的方法豁免；路径命中但方法不在表里的请求照常走 Basic。
        // 解不出规范化路径（`%FF` 这类非法 UTF-8 转义）的请求无从路由，也无从判豁免：
        // 在这里统一回 400，不让它在鉴权前变成 500、也不进路由。
        final String path;
        try {
          path = canonicalRequestPath(request);
        } on FormatException {
          return shelf.Response(400, body: 'Malformed request path');
        }
        final String method = request.method.toUpperCase();
        for (final _PublicRoute route in _kPublicRoutes) {
          if (!route.matches(path) || !route.methods.contains(method)) {
            continue;
          }
          switch (route.gate) {
            case _PublicGate.none:
              return innerHandler(request);
            case _PublicGate.dictionaryMediaQuery:
              // 无效 / 缺省的 query token 落到下方 Basic（app 内 / Basic 客户端照常用）。
              if (_dictionaryMediaTokenValid(request)) {
                return innerHandler(request);
              }
          }
          break;
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
      // TODO-961 M1b：再比对任一未吊销的 per-peer token（含 legacy- 行，BUG-4282）。
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
  /// server token nor a `legacy-` row token (BUG-4282: same rights as the
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
  /// 原盘会话、查词音频 id）据此记签发者（BUG-4282）。
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

/// 公开路由放行前还要过的额外门。
enum _PublicGate {
  /// 无额外门：handler 自己校验（配对窗口 / 流 token / 会话 token / 短时 id），或本就公开。
  none,

  /// query 里带有效的词典媒体凭据才放行，否则落到 Basic。
  dictionaryMediaQuery,
}

/// 「免 Basic」路由表的一条：规范化路径（[canonicalRequestPath]，带前导 `/`、已解码）
/// 命中 [matches] **且**方法在 [methods] 里才豁免；方法集与对应 handler 受理的方法一致，
/// 别的方法照常要 Basic。
class _PublicRoute {
  const _PublicRoute(
    this.methods,
    this.matches, [
    this.gate = _PublicGate.none,
  ]);

  /// 豁免的方法（大写）。
  final Set<String> methods;
  final bool Function(String canonicalPath) matches;
  final _PublicGate gate;
}

/// 互联 host 唯一的「免 Basic」路由表。新增一条就是新开一个不带 Authorization 也能进
/// handler 的面：handler 必须自己有门（token / 配对窗口），方法集只写 handler 受理的。
const List<_PublicRoute> _kPublicRoutes = <_PublicRoute>[
  // 配对：client 还没有 token——这正是它在获取的东西。门是 handler 里的配对窗口 /
  // PIN proof + host 人工确认（TODO-961 M1）。
  _PublicRoute(<String>{'POST'}, _isPairPath),
  // TODO-963 M2：无鉴权轻量探测（配对前确认地址可达 + 取能力 / 指纹做 TOFU），只读。
  _PublicRoute(<String>{'GET'}, _isPingPath),
  // 视频流 / HLS / 蓝光码流：media_kit 拿裸 URL 播放，门是 URL 里的短时 token。
  _PublicRoute(<String>{'GET'}, _isVideoStreamPath),
  // 远端原盘的盘目录：libbluray / libdvdnav 在 libmpv 里直接取文件，带不了
  // Authorization；门是路径里的会话 token（handler 内校验、按空闲过期）。
  _PublicRoute(<String>{'GET'}, isDiscShareSessionPath),
  // 查词音频文件交给平台播放器裸 GET；门是 RemoteLookupRoutes 里的短时不透明 id。
  _PublicRoute(<String>{'GET', 'HEAD'}, _isLookupAudioFilePath),
  // TODO-1215：词典媒体由网页 <img src> 取，带不了 Authorization，改用 query 凭据。
  _PublicRoute(
    <String>{'GET', 'HEAD'},
    _isDictionaryMediaPath,
    _PublicGate.dictionaryMediaQuery,
  ),
];

bool _isPairPath(String path) =>
    path == '/api/pair' ||
    path == '/api/pair/v2' ||
    path == '/api/pair/v2/confirm';

bool _isPingPath(String path) => path == '/api/ping';

/// 判断规范化路径 [path] 是否为视频流路径
/// （`/api/library/videos/<id>/<stream|hls.m3u8|hlsseg.ts|bdclip.m2ts>`，id 非空，id 可含 `/`）。
///
/// 两条 hls 子路径与 `/stream` 同待遇：播放器拿到 playlist 后会自己去取每个分段，
/// 那些请求同样是裸 GET，不带 Authorization。它们的门是 URL 里的短时 token
/// （handler 内校验），与 `/stream` 是同一套。
bool _isVideoStreamPath(String path) {
  const String prefix = '/api/library/videos/';
  if (!path.startsWith(prefix)) return false;
  for (final String suffix in _kVideoStreamSuffixes) {
    if (!path.endsWith(suffix)) continue;
    final String idPart = path.substring(
      prefix.length,
      path.length - suffix.length,
    );
    if (idPart.isNotEmpty) return true;
  }
  return false;
}

/// 豁免 Basic 的视频子路径后缀。新增一条就是新开一个「谁拿到 URL 谁能取」的面，
/// 所以它们的 handler 必须各自校验 token。
const List<String> _kVideoStreamSuffixes = <String>[
  '/stream',
  '/hls.m3u8',
  '/$kTranscodeSegmentPathSuffix',
  '/$kBlurayClipPathSuffix',
];

bool _isLookupAudioFilePath(String path) => path == '/api/lookup/audio/file';

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

bool _isDictionaryMediaPath(String path) => path == '/api/media/dictionary';
