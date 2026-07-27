import 'package:hibiki/src/sync/forwarded_mine_payload.dart';
import 'package:hibiki/src/sync/interconnect_post_transport.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:http/http.dart' as http;

/// 「制卡到服务端」发送器的窄接口（供 [RemoteMiningAnkiRepository] 依赖，便于单测注入假实现，
/// 不必拉起真实 HTTP + SyncRepository）。生产实现是 [HibikiRemoteMiningClient]。
abstract class RemoteMineSender {
  /// 转发一次制卡；返回服务端 `{result, message?, detail?}`，无可达候选/全失败返回 null，
  /// token 被拒抛 [SyncAuthError]。
  Future<Map<String, dynamic>?> mineForward(ForwardedMinePayload payload);

  /// 远端查重（fail-soft，异常/无候选回 false）。
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  });
}

/// 互联「制卡到服务端」的客户端发送器。传输走共享的 [InterconnectPostTransport]
/// （enabled 候选按序 fallback / `Basic base64(hibiki:token)` / https 带指纹走钉扎 client /
/// 每候选独立回收），本类只管端点 `/api/mine/forward` 与 `/api/duplicate`，以及更长的
/// 默认超时（制卡请求体带媒体字节，LAN 上可能几 MB）。
class HibikiRemoteMiningClient implements RemoteMineSender {
  HibikiRemoteMiningClient({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration mineTimeout = const Duration(seconds: 60),
    Duration duplicateTimeout = const Duration(seconds: 5),
  })  : _repo = repo,
        _transport = InterconnectPostTransport(
          repo: repo,
          httpClient: httpClient,
          pinnedClientFactory: pinnedClientFactory,
        ),
        _mineTimeout = mineTimeout,
        _duplicateTimeout = duplicateTimeout;

  final SyncRepository _repo;
  final InterconnectPostTransport _transport;
  final Duration _mineTimeout;
  final Duration _duplicateTimeout;

  /// 是否已配置可达的已配对主机（enabled 候选 + token）。用于设置页/开关判断能否远端制卡。
  Future<bool> hasTarget() async {
    final List<HibikiClientUrl> candidates = (await _repo.getHibikiClientUrls())
        .where((HibikiClientUrl u) => u.enabled)
        .toList(growable: false);
    final String? token = await _repo.getHibikiClientToken();
    return candidates.isNotEmpty && token != null && token.isNotEmpty;
  }

  /// 转发一次制卡到已配对主机。返回服务端 `{result, message?, detail?}`；
  /// 无可达候选/全部失败返回 null；token 被拒抛 [SyncAuthError]。
  @override
  Future<Map<String, dynamic>?> mineForward(ForwardedMinePayload payload) {
    return _post(
      path: '/api/mine/forward',
      body: payload.toJson(),
      timeout: _mineTimeout,
    );
  }

  /// 查重（`+`→`✓`）：命中主机 Anki 后端。fail-soft，异常/无候选一律回 false。
  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async {
    try {
      final Map<String, dynamic>? json = await _post(
        path: '/api/duplicate',
        body: <String, dynamic>{'expression': expression, 'reading': reading},
        timeout: _duplicateTimeout,
      );
      return json?['duplicate'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 制卡侧不消费 `allUnreachable`（没有失败冷却机制），只取响应体——「全不可达」
  /// 与「可达但无结果」在这里都是 null，与抽出共享传输层之前逐字一致。
  Future<Map<String, dynamic>?> _post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async {
    final InterconnectPostOutcome outcome = await _transport.post(
      path: path,
      body: body,
      timeout: timeout,
      authErrorMessage: 'Hibiki server rejected remote mining token',
    );
    return outcome.json;
  }
}
