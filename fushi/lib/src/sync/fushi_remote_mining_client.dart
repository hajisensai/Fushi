import 'package:fushi/src/sync/forwarded_mine_payload.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:http/http.dart' as http;

/// BUG-1185：远端查重的三态结果。查重是「用户据此决定要不要再制一张卡」的信息，
/// 所以**「没查成」必须与「查过了、不重复」分开**：token 被对端拒绝时把结果压成
/// 「不重复」，用户看到的是 ➕（可制卡）——他会以为这张卡没做过，而实际上根本没查。
///
/// 可重试的失败（无可达候选 / 超时 / 连接被拒 / 坏响应体）仍按既有 fail-soft 语义
/// 降级为 [notDuplicate]，绝不让远端抖动阻断查词——那是有意的降级，不是错误答案。
enum RemoteDuplicateCheck {
  /// 主机确认已有同词卡。
  duplicate,

  /// 主机确认没有同词卡，**或**可重试失败后的 fail-soft 降级。
  notDuplicate,

  /// token 被主机拒绝（401）——查重根本没执行，答案未知，不得当成 [notDuplicate]。
  authRejected,
}

/// 「制卡到服务端」发送器的窄接口（供 [RemoteMiningAnkiRepository] 依赖，便于单测注入假实现，
/// 不必拉起真实 HTTP + SyncRepository）。生产实现是 [FushiRemoteMiningClient]。
abstract class RemoteMineSender {
  /// 转发一次制卡；返回服务端 `{result, message?, detail?}`，无可达候选/全失败返回 null，
  /// token 被拒抛 [SyncAuthError]。
  Future<Map<String, dynamic>?> mineForward(ForwardedMinePayload payload);

  /// 远端查重。三态：命中 / 未命中 / token 被拒（见 [RemoteDuplicateCheck]）。
  /// 可重试失败仍 fail-soft 降级为 [RemoteDuplicateCheck.notDuplicate]。
  Future<RemoteDuplicateCheck> isDuplicate({
    required String expression,
    required String reading,
  });
}

/// 互联「制卡到服务端」的客户端发送器。传输走共享的 [InterconnectPostTransport]
/// （enabled 候选按序 fallback / `Basic base64(hibiki:token)` / https 带指纹走钉扎 client /
/// 每候选独立回收），本类只管端点 `/api/mine/forward` 与 `/api/duplicate`，以及更长的
/// 默认超时（制卡请求体带媒体字节，LAN 上可能几 MB）。
class FushiRemoteMiningClient implements RemoteMineSender {
  FushiRemoteMiningClient({
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
    final List<FushiClientUrl> candidates = (await _repo.getFushiClientUrls())
        .where((FushiClientUrl u) => u.enabled)
        .toList(growable: false);
    // BUG-1550：凭据可能落在地址行上（per-peer token），也可能只有旧的全局键；
    // 任一候选拿得出凭据就算有目标。
    final String? fallbackToken = await _repo.getFushiClientToken();
    return candidates.any(
        (FushiClientUrl u) => interconnectTokenFor(u, fallbackToken) != null);
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

  /// 查重（`+`→`✓`）：命中主机 Anki 后端。
  ///
  /// BUG-1185：可重试失败（无可达候选 / 超时 / 非 2xx / 坏 JSON）仍 fail-soft 降级为
  /// [RemoteDuplicateCheck.notDuplicate]，绝不让远端抖动阻断查词；但 token 被主机拒绝
  /// （[SyncAuthError]，与 [mineForward] 同一条 401 契约）时**不再压成「不重复」**——
  /// 那是把「没查成」冒充成「查过了、没有」，用户会据此重复制卡。
  @override
  Future<RemoteDuplicateCheck> isDuplicate({
    required String expression,
    required String reading,
  }) async {
    try {
      final Map<String, dynamic>? json = await _post(
        path: '/api/duplicate',
        body: <String, dynamic>{'expression': expression, 'reading': reading},
        timeout: _duplicateTimeout,
      );
      return json?['duplicate'] == true
          ? RemoteDuplicateCheck.duplicate
          : RemoteDuplicateCheck.notDuplicate;
    } on SyncAuthError {
      return RemoteDuplicateCheck.authRejected;
    } catch (_) {
      return RemoteDuplicateCheck.notDuplicate;
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
      authErrorMessage: 'Fushi server rejected remote mining token',
    );
    return outcome.json;
  }
}
