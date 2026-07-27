import 'dart:convert';

import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/tls/hibiki_pinning_http.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';
import 'package:http/http.dart' as http;

/// 互联客户端的 JSON POST 传输层：**唯一**一份「已启用候选按序 fallback +
/// `Basic base64(hibiki:token)` 鉴权 + https 带指纹强制走钉扎 client + 每候选独立
/// 回收」的实现。
///
/// **为什么抽出来**——这套逻辑此前被逐行复制过多份：
/// `hibiki_remote_lookup_client.dart` 的 `_postLookup`、
/// `hibiki_remote_mining_client.dart` 的 `_post`（它的类注释自己就写着「传输契约与
/// [HibikiRemoteLookupClient] 完全同构」），
/// 另有 `interconnect_manga_ocr_client.dart` 的 GET 版 `probe` 和
/// `InterconnectSyncBackend` 走 `WebDavOps` 的第四份。每加一个互联端点就再抄一遍，
/// 而钉扎、401 语义、socket 回收这些安全相关的细节一旦有一份抄漏就是真事故
/// （TODO-961 gap①：注入的 keep-alive client 不得旁路证书钉扎）。
///
/// 现在新增一个互联端点 = 调一次 [post]，不再复制传输代码。
class InterconnectPostTransport {
  InterconnectPostTransport({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
  })  : _repo = repo,
        _httpClient = httpClient ?? http.Client(),
        _pinnedClientFactory = pinnedClientFactory ?? _defaultPinnedClient;

  final SyncRepository _repo;

  /// 明文 http 候选共用的 client（生产由 AppModel 注入 keep-alive client 复用连接，
  /// TODO-744）。**绝不**用于带指纹的 https 候选——那必须走钉扎 client
  /// （TODO-961 gap①：注入生产 client 不得旁路证书钉扎）。
  final http.Client _httpClient;

  /// https 候选的钉扎 client 工厂（每候选一个、用完即关）。默认真钉扎
  /// [createPinnedHttpPackageClient]；测试注入 MockClient 工厂即可拦截。
  final http.Client Function(String expectedFingerprint) _pinnedClientFactory;

  static http.Client _defaultPinnedClient(String expectedFingerprint) =>
      createPinnedHttpPackageClient(expectedFingerprint: expectedFingerprint);

  /// 向所有已启用候选按序 POST [body] 到 [path]，返回第一个拿到的可用 JSON 响应。
  ///
  /// 候选级语义（与抽出前逐字一致）：
  /// - 401 → 抛 [SyncAuthError]（消息由 [authErrorMessage] 给，各调用方保留自己的文案）；
  ///   所有候选共用一个 token，一次拒绝即全部失败，不再试下一个。
  /// - 404 / 405 → 该候选是旧版 host（无此端点），换下一个候选。
  /// - 其它非 2xx、响应体不是 JSON 对象 → 换下一个候选。
  /// - 传输层失败（连接拒绝 / 超时 / DNS）→ 换下一个候选。
  ///
  /// 返回的 `allUnreachable` 仅当「至少发起过一次请求，且所有候选都没拿到**任何**
  /// HTTP 响应」时为 true——未配对 / 无 token / 候选 URL 全畸形都**不**算不可达。
  /// 这条区分是音频源失败冷却（BUG-575）的依据：设备可达但没这个词 ≠ 设备死了。
  Future<InterconnectPostOutcome> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
    required String authErrorMessage,
  }) async {
    final List<HibikiClientUrl> candidates = (await _repo.getHibikiClientUrls())
        .where((HibikiClientUrl u) => u.enabled)
        .toList(growable: false);
    final String? token = await _repo.getHibikiClientToken();
    if (candidates.isEmpty || token == null || token.isEmpty) {
      // 未配对/未启用/无 token：不是「设备不可达」，按「无结果」处理。
      return (json: null, allUnreachable: false);
    }

    bool attempted = false;
    bool anyResponse = false;
    for (final HibikiClientUrl candidate in candidates) {
      final Uri? uri = interconnectEndpointUri(candidate.url, path);
      if (uri == null) continue;
      // TODO-961 M1/gap①: https 带指纹的候选**始终**走钉扎 client，与是否注入了
      // 外部 client 无关（注入的 keep-alive client 只服务明文 http 候选）。
      final String? fp = candidate.fingerprintSha256;
      final bool usePinned =
          uri.isScheme('https') && fp != null && fp.isNotEmpty;
      final http.Client client =
          usePinned ? _pinnedClientFactory(fp) : _httpClient;
      attempted = true;
      try {
        final http.Response response = await client
            .post(
              uri,
              headers: <String, String>{
                'Authorization':
                    'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body),
            )
            .timeout(timeout);
        // 拿到任何 HTTP 响应（含 401/404/405/非 2xx/坏 JSON 体）都算「可达」；
        // 传输层失败（连接拒绝/超时/DNS）根本走不到这一行，落在 catch 里。
        anyResponse = true;
        if (response.statusCode == 401) {
          throw SyncAuthError(authErrorMessage);
        }
        if (response.statusCode == 404 || response.statusCode == 405) {
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          return (json: decoded, allUnreachable: false);
        }
        if (decoded is Map) {
          return (
            json: Map<String, dynamic>.from(decoded),
            allUnreachable: false,
          );
        }
      } on SyncAuthError {
        rethrow;
      } catch (_) {
        continue;
      } finally {
        // 每候选独立 pinned client 用完即关，所有出口（return/continue/throw）统一
        // 经 finally 回收，不泄漏 socket；共享 _httpClient 绝不在此关闭。
        if (usePinned) client.close();
      }
    }
    // 走到这里没有任何候选给出可用结果；只有「试过且一个响应都没拿到」才算
    // 全部不可达（传输层失败），可达但无结果仍是普通 null。
    return (json: null, allUnreachable: attempted && !anyResponse);
  }
}

/// [InterconnectPostTransport.post] 的结局：`json` 为拿到并解析成功的响应体；
/// `allUnreachable` 的语义见 [InterconnectPostTransport.post] 的文档。
typedef InterconnectPostOutcome = ({
  Map<String, dynamic>? json,
  bool allUnreachable
});

/// 把候选基址 [baseUrl] 与端点 [path] 拼成请求 URI；基址畸形返回 null（调用方跳过
/// 该候选）。查询串一律清空——互联端点的入参全部走 JSON 请求体。
Uri? interconnectEndpointUri(String baseUrl, String path) {
  try {
    final Uri base = Uri.parse(WebDavOps.normalizeUrl(baseUrl));
    return base.replace(path: path, queryParameters: const <String, String>{});
  } catch (_) {
    return null;
  }
}
