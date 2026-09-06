part of '../fushi_sync_server.dart';

/// 认证域（B3 按域拆出）：auth 中间件、host token / peer token / Basic 校验、peer token 缓存。
/// 公开入口（start / stop / invalidatePeerTokenCache）留在 [FushiSyncServer] 本体；
/// 方法逐字搬自 FushiSyncServer，共享库私有作用域。
extension _FushiSyncServerAuth on FushiSyncServer {
  shelf.Middleware _authMiddleware() {
    return (shelf.Handler innerHandler) {
      return (shelf.Request request) async {
        if (request.method == 'OPTIONS') return innerHandler(request);
        // Pairing is the one unauthenticated route: the client has no token
        // yet — that is exactly what it is fetching. Gating is done by the
        // pairing window inside _handlePair, not by Basic auth.
        if (request.url.path == 'api/pair') return innerHandler(request);
        // TODO-961 M1: v2 配对（含 confirm）同样无 token——这正是 client 在获取的
        // 东西。门控由 PIN proof + host 人工确认完成，不靠 Basic auth。
        if (request.url.path == 'api/pair/v2' ||
            request.url.path == 'api/pair/v2/confirm') {
          return innerHandler(request);
        }
        // TODO-963 M2: /api/ping 是无鉴权的轻量探测端点——手动输入 IP 的 client 在
        // 配对前（还没有 token）用它确认地址可达 + 取 host 能力/指纹做 TOFU。只读、
        // 不泄漏数据，与 /api/pair 同属配对前公开面。
        if (request.url.path == 'api/ping') return innerHandler(request);
        // Video stream paths are exempted from Basic auth to allow media_kit
        // to play via a plain URL. Token validation happens inside the handler.
        // Only the /stream sub-path is exempted; /streamurl, /subtitle, and the
        // video list still require Basic auth.
        if (_isVideoStreamPath(request.url.path)) return innerHandler(request);
        // Remote lookup audio file URLs are handed to platform audio players,
        // which issue a bare GET without Authorization. The lookup endpoint
        // stays authenticated; the file endpoint is guarded by an opaque,
        // short-lived in-memory id in _handleAudioFile.
        if (_isLookupAudioFilePath(request.url.path)) {
          return innerHandler(request);
        }
        // TODO-1215: the dictionary media endpoint is fetched by a web page
        // <img src> GET, which carries no Authorization header (same as
        // /api/lookup/audio/file). It authenticates via a ?token= query
        // param instead; a valid token passes here, an invalid/absent one
        // falls through to the Basic check below (in-app / Basic clients
        // still work) and ultimately 401s.
        if (_isDictionaryMediaPath(request.url.path) &&
            _dictionaryMediaTokenValid(request)) {
          return innerHandler(request);
        }
        final auth = request.headers['authorization'];
        if (auth == null || !await _validateAuth(auth)) {
          return shelf.Response(401,
              headers: {'WWW-Authenticate': 'Basic realm="Fushi Sync"'});
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
      // TODO-961 M1b：再比对任一未吊销的 per-peer token。惰性加载 + 缓存，避免每请求
      // 打库；配对/吊销经 [invalidatePeerTokenCache] 清缓存促重载。
      final Set<String> peerTokens = await _peerTokens();
      final Uint8List pw = Uint8List.fromList(utf8.encode(password));
      for (final String peerToken in peerTokens) {
        if (_constantTimeEquals(
            pw, Uint8List.fromList(utf8.encode(peerToken)))) {
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
  /// server token.
  Future<bool> _validatePeerAuth(String? header) async {
    if (header == null) return false;
    final String? password = _basicPassword(header);
    if (password == null) return false;
    final Uint8List supplied = Uint8List.fromList(utf8.encode(password));
    for (final String peerToken in await _peerTokens()) {
      if (_constantTimeEquals(
        supplied,
        Uint8List.fromList(utf8.encode(peerToken)),
      )) {
        return true;
      }
    }
    return false;
  }

  /// 当前有效 per-peer token 集合（惰性加载 + 缓存）。无 provider 时为空集——只认
  /// 共享 [_token]。
  Future<Set<String>> _peerTokens() async {
    final Set<String>? cached = _cachedPeerTokens;
    if (cached != null) return cached;
    final Future<Set<String>> Function()? provider = pairedPeerTokensProvider;
    final Set<String> loaded = provider == null ? <String>{} : await provider();
    _cachedPeerTokens = loaded;
    return loaded;
  }
}

// ── 本域私有的顶层 helper（原 FushiSyncServer 的 private static；extension 体内看不到
//    宿主类的 static，故提到库顶层）。

/// 判断 [urlPath]（即 request.url.path，不含前导 `/`）是否为视频流路径
/// （`api/library/videos/<id>/stream`，id 非空，id 可含 `/`）。
bool _isVideoStreamPath(String urlPath) {
  const String prefix = 'api/library/videos/';
  const String suffix = '/stream';
  if (!urlPath.startsWith(prefix)) return false;
  if (!urlPath.endsWith(suffix)) return false;
  final String idPart =
      urlPath.substring(prefix.length, urlPath.length - suffix.length);
  return idPart.isNotEmpty;
}

bool _isLookupAudioFilePath(String urlPath) =>
    urlPath == 'api/lookup/audio/file';

String? _basicPassword(String header) {
  if (!header.startsWith('Basic ')) return null;
  try {
    final String decoded =
        utf8.decode(base64Decode(header.substring('Basic '.length)));
    final int colonIdx = decoded.indexOf(':');
    return colonIdx < 0 ? null : decoded.substring(colonIdx + 1);
  } catch (_) {
    return null;
  }
}

bool _isDictionaryMediaPath(String urlPath) =>
    urlPath == 'api/media/dictionary';
