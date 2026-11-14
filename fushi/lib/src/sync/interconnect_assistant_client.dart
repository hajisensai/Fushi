/// 互联「AI 助手会话」客户端（`/api/assistant`）：手机把一句话交给已配对的电脑，
/// 由电脑的 AI 与下载管线去办；手机只收快照、发动作。
library;

import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart' show AiAgentSessionSummary;
import 'package:fushi_engine/ai/agent/agent_session_archive.dart'
    show kAiAgentRemoteScene;
import 'package:fushi_engine/sync/assistant/agent_assistant_host.dart'
    show
        kHostAssistantAgentHistoryKey,
        kHostAssistantAgentHistoryVersion,
        kHostAssistantReasonsKey;
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:http/http.dart' as http;

/// 一台已配对 host 的助手能力。
class HostAssistantTarget {
  const HostAssistantTarget({
    required this.baseUrl,
    required this.deviceName,
    required this.features,
    this.reason,
    this.reasons = const <String, String>{},
    this.fingerprintSha256,
    this.agentHistoryVersion = 0,
    this.pairedToken = false,
    this.host,
  });

  /// 这台 host 的身份（client 产出的 target 一律带上）。null = 调用方直接构造的
  /// 老形状 target，按 [baseUrl] 认（见 [hostRef]）。
  final InterconnectHostRef? host;

  /// 请求按它选路 / 取凭据 / 钉扎，而不是按 [baseUrl] 那一条地址：会话期间同一台
  /// host 换了可达地址（LAN 断了、改走 IPv6 / 组网 / P2P）照样续得上。
  InterconnectHostRef get hostRef =>
      host ?? InterconnectHostRef.legacyUrl(interconnectPersistedUrl(baseUrl));

  /// 这台 host 的持久代表地址（`p2p://` 而非本次的本地转发口）。
  final String baseUrl;
  final String? deviceName;

  /// 当前能开的会话种类（[kHostAssistantFeatureVideoAcquire] …）。
  final List<String> features;

  /// 开不了时 host 给的短码（`no_provider` / `not_ready` / `disabled`）；老 host 根本
  /// 没有 `assistant` 能力位时是 [kHostAssistantReasonUnsupported]。
  final String? reason;

  /// 按 feature 的不可用短码（host 宣告多种会话时：AI 下视频能开、AI 助手没指派
  /// 提供商…）。老 host 没有这个字段。
  final Map<String, String> reasons;
  final String? fingerprintSha256;

  /// host 宣告的远端会话历史协议版本（能力位 `agentHistory`，BUG-4067）；0 = 老 host /
  /// 没有存档，不发 `history` 路由、不发 `resume`。
  final int agentHistoryVersion;

  /// 这台设备用的是 host 派给它的 per-peer 口令（不是老版本的共享口令）。host 按
  /// 口令认设备、按设备列会话历史；共享口令认不出是谁，历史路由一律 403。
  final bool pairedToken;

  /// 这台 host 能列 / 续接 / 改名 / 删除这台设备发起的 AI 助手会话。
  bool get supportsAgentHistory =>
      pairedToken && agentHistoryVersion >= kHostAssistantAgentHistoryVersion;

  String get label => deviceName ?? baseUrl;

  bool supports(String feature) => features.contains(feature);

  /// [feature] 开不了的原因：先看按 feature 的短码，再退回顶层 [reason]；都没有
  /// （老 host 只宣告了别的 feature）按 [kHostAssistantReasonUnsupported]。
  String reasonFor(String feature) =>
      reasons[feature] ?? reason ?? kHostAssistantReasonUnsupported;
}

/// 老 host（没有 `assistant` 能力位）的本地短码。
const String kHostAssistantReasonUnsupported = 'unsupported';

/// host 回的一份会话信封。
class HostAssistantEnvelope {
  const HostAssistantEnvelope({
    required this.id,
    required this.revision,
    required this.view,
  });

  factory HostAssistantEnvelope.fromJson(Map<String, dynamic> json) {
    final Object? view = json['view'];
    return HostAssistantEnvelope(
      id: '${json['id'] ?? ''}',
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      view: view is Map
          ? view.map(
              (Object? key, Object? value) =>
                  MapEntry<String, Object?>('$key', value),
            )
          : const <String, Object?>{},
    );
  }

  final String id;
  final int revision;
  final Map<String, Object?> view;
}

class HostAssistantException implements Exception {
  const HostAssistantException(this.code, [this.detail]);

  /// `http_<status>`，或通道的 `no_host` / `unreachable` / `auth_rejected` /
  /// `certificate_mismatch` / `cancelled`；409 时 [detail] 是 host 给的 reason 短码。
  final String code;
  final String? detail;

  bool get sessionGone => code == 'http_404';

  /// 再试也不会好：凭据被拒 / 证书不符 / 已不在配对表 / host 拒绝（401、403）。
  bool get permanent => const <String>{
    'auth_rejected',
    'certificate_mismatch',
    'no_host',
    'http_401',
    'http_403',
  }.contains(code);

  /// 本机 client 已关闭（调用方 dispose），不是 host 的问题。
  bool get cancelled => code == 'cancelled';

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

/// AI 助手 client。传输层（选路、凭据、钉扎、整段超时、client 生命周期、错误
/// 分型）全部走 [InterconnectHostChannel]，每台 host 一条通道、复用到 [close]。
class InterconnectAssistantClient {
  InterconnectAssistantClient({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration probeTimeout = const Duration(seconds: 4),
    Duration requestTimeout = const Duration(seconds: 30),
  }) : _repo = repo,
       _borrowedPlain = httpClient,
       _pinnedClientFactory = pinnedClientFactory,
       _probeTimeout = probeTimeout,
       _requestTimeout = requestTimeout;

  final SyncRepository _repo;

  /// 借用的明文 client（测试缝 / 调用方共享）：本 client 不关它。
  final http.Client? _borrowedPlain;

  /// 没借到时自建、各通道共用，[close] 时关。
  http.Client? _ownedPlain;
  final http.Client Function(String expectedFingerprint)? _pinnedClientFactory;
  final Duration _probeTimeout;
  final Duration _requestTimeout;
  final Map<String, InterconnectHostChannel> _channels =
      <String, InterconnectHostChannel>{};
  bool _closed = false;

  /// 长轮询一次等多久（host 侧另有 25 秒上限）。
  static const Duration longPollWait = Duration(seconds: 20);

  InterconnectHostChannel _channel(InterconnectHostRef host) {
    if (_closed) {
      throw const InterconnectChannelException(
        InterconnectChannelFailure.cancelled,
      );
    }
    return _channels.putIfAbsent(
      host.key,
      () => InterconnectHostChannel(
        repo: _repo,
        host: host,
        plainClient: _borrowedPlain ?? (_ownedPlain ??= http.Client()),
        pinnedClientFactory: _pinnedClientFactory,
      ),
    );
  }

  /// 关掉全部通道与自建的明文 client；在途与之后的请求抛
  /// `HostAssistantException('cancelled')`。（叫 dispose 而不是 close：[close]
  /// 早就是「关 host 上的会话」那条请求。）
  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final InterconnectHostChannel c in _channels.values) {
      c.close();
    }
    _channels.clear();
    _ownedPlain?.close();
    _ownedPlain = null;
  }

  /// 只探这一台（「下载执行设备」点名的那台）。不在配对清单里 / 连不上 → null；
  /// 连得上但老 host 没有助手能力位 → reason = [kHostAssistantReasonUnsupported]。
  /// 要失败原因用 [probeUrlOutcome]。
  Future<HostAssistantTarget?> probeUrl(String url) async {
    final InterconnectCapabilityOutcome<HostAssistantTarget> outcome =
        await probeUrlOutcome(url);
    return outcome is InterconnectCapabilityAvailable<HostAssistantTarget>
        ? outcome.target
        : null;
  }

  /// [url] 认的是「那台 host」而不是那一条地址：偏好里存的是用户当初选中时的地址
  /// （在家可能是 LAN），出门后同一台 host 仍可经 IPv6 / 组网 / P2P 到达，由通道
  /// 在组内选路。[url] 不在配对清单里 → notPaired。
  Future<InterconnectCapabilityOutcome<HostAssistantTarget>> probeUrlOutcome(
    String url,
  ) async {
    final InterconnectHostRef? host = interconnectHostRefForUrl(
      await _repo.getFushiClientUrls(),
      url,
    );
    if (host == null) {
      return InterconnectCapabilityUnavailable<HostAssistantTarget>(
        host: InterconnectHostRef.legacyUrl(interconnectPersistedUrl(url)),
        label: url,
        failure: InterconnectHostFailure.notPaired,
      );
    }
    return probeHost(host);
  }

  /// 探一台 host 的助手能力。老 host（200 但没有 `assistant` 能力位）按原语义给
  /// Available + reason = [kHostAssistantReasonUnsupported]。
  Future<InterconnectCapabilityOutcome<HostAssistantTarget>> probeHost(
    InterconnectHostRef host,
  ) async {
    final List<FushiClientUrl> rows = await _repo.getFushiClientUrls();
    String? pin;
    String? rawName;
    for (final FushiClientUrl u in rows) {
      if (!host.matches(u)) continue;
      final String? fp = u.fingerprintSha256;
      if (pin == null && fp != null && fp.isNotEmpty) pin = fp;
      final String? name = u.deviceName;
      if (rawName == null && name != null && name.isNotEmpty) rawName = name;
    }
    final String? groupPin = pin;
    final String? groupName = rawName;
    // per-peer 口令按组内代表行判定（配对时同步给全组），不看这次碰巧走的那条。
    final bool pairedToken =
        (interconnectPeerRepresentativeOf(rows, host.anchorUrl)?.token ?? '')
            .isNotEmpty;
    return probeInterconnectCapability<HostAssistantTarget>(
      _channel(host),
      label: interconnectHostLabel(rows, host),
      timeout: _probeTimeout,
      parse: (Map<String, dynamic> caps, FushiClientUrl via) {
        final String? deviceName = via.deviceName ?? groupName;
        final Object? assistant = caps['assistant'];
        if (assistant is! Map) {
          return HostAssistantTarget(
            host: host,
            baseUrl: host.anchorUrl,
            deviceName: deviceName,
            features: const <String>[],
            reason: kHostAssistantReasonUnsupported,
            fingerprintSha256: groupPin,
          );
        }
        final Object? features = assistant['features'];
        final Object? reasons = assistant[kHostAssistantReasonsKey];
        return HostAssistantTarget(
          host: host,
          baseUrl: host.anchorUrl,
          deviceName: deviceName,
          features: assistant['supported'] == true && features is List
              ? features.map((Object? f) => '$f').toList(growable: false)
              : const <String>[],
          reason: assistant['reason']?.toString(),
          reasons: reasons is Map
              ? <String, String>{
                  for (final MapEntry<Object?, Object?> e in reasons.entries)
                    '${e.key}': '${e.value}',
                }
              : const <String, String>{},
          fingerprintSha256: groupPin,
          agentHistoryVersion:
              (assistant[kHostAssistantAgentHistoryKey] as num?)?.toInt() ?? 0,
          pairedToken: pairedToken,
        );
      },
    );
  }

  /// 开会话；[resume] 非空 = 续接 host 上这场存档会话（只在
  /// [HostAssistantTarget.supportsAgentHistory] 时发：老 host 不认这个字段，会静默
  /// 开一场新的）。
  Future<HostAssistantEnvelope> open(
    HostAssistantTarget target, {
    required String feature,
    required String locale,
    String? resume,
  }) async {
    if (resume != null && !target.supportsAgentHistory) {
      throw const HostAssistantException('history_unsupported');
    }
    return HostAssistantEnvelope.fromJson(
      await _call(
        target,
        'POST',
        '/api/assistant/sessions',
        jsonBody: <String, Object?>{
          'feature': feature,
          'locale': locale,
          'resume': ?resume,
        },
      ),
    );
  }

  /// 这台设备在 [target] 上发起的 [feature] 会话（最近更新的在前）。
  Future<List<AiAgentSessionSummary>> listHistory(
    HostAssistantTarget target, {
    required String feature,
  }) async {
    _requireHistory(target);
    final Map<String, dynamic> body = await _call(
      target,
      'GET',
      '/api/assistant/history',
      query: <String, String>{'feature': feature},
    );
    final Object? sessions = body['sessions'];
    int intOf(Object? v) => (v as num?)?.toInt() ?? 0;
    return <AiAgentSessionSummary>[
      if (sessions is List)
        for (final Object? s in sessions)
          if (s is Map && s['id'] is String)
            AiAgentSessionSummary(
              id: s['id'] as String,
              title: '${s['title'] ?? ''}',
              scene: kAiAgentRemoteScene,
              profileUid: '',
              totalTokens: intOf(s['tokens']),
              createdAt: intOf(s['createdAt']),
              updatedAt: intOf(s['updatedAt']),
            ),
    ];
  }

  Future<void> renameHistory(
    HostAssistantTarget target,
    String id, {
    required String feature,
    required String title,
  }) async {
    _requireHistory(target);
    await _call(
      target,
      'PATCH',
      '/api/assistant/history/${Uri.encodeComponent(id)}',
      jsonBody: <String, Object?>{'feature': feature, 'title': title},
    );
  }

  Future<void> deleteHistory(
    HostAssistantTarget target,
    String id, {
    required String feature,
  }) async {
    _requireHistory(target);
    await _call(
      target,
      'DELETE',
      '/api/assistant/history/${Uri.encodeComponent(id)}',
      query: <String, String>{'feature': feature},
    );
  }

  static void _requireHistory(HostAssistantTarget target) {
    if (!target.supportsAgentHistory) {
      throw const HostAssistantException('history_unsupported');
    }
  }

  /// 长轮询：快照越过 [after] 或等满 [wait] 就返回。
  Future<HostAssistantEnvelope> read(
    HostAssistantTarget target,
    String id, {
    int? after,
    Duration wait = Duration.zero,
  }) async => HostAssistantEnvelope.fromJson(
    await _call(
      target,
      'GET',
      '/api/assistant/sessions/${Uri.encodeComponent(id)}',
      query: <String, String>{
        if (after != null) 'after': '$after',
        if (wait > Duration.zero) 'wait': '${wait.inSeconds}',
      },
      timeout: _requestTimeout + wait,
    ),
  );

  Future<HostAssistantEnvelope> act(
    HostAssistantTarget target,
    String id,
    Map<String, Object?> action,
  ) async => HostAssistantEnvelope.fromJson(
    await _call(
      target,
      'POST',
      '/api/assistant/sessions/${Uri.encodeComponent(id)}/actions',
      jsonBody: action,
    ),
  );

  /// 关 host 上的会话。
  ///
  /// 必须是真正的 `Future<void>`：若直接 `=> _call(...)`，运行时拿到的是
  /// `Future<Map<String, dynamic>>`，调用方挂的 `catchError` 处理器返回
  /// void 会在断线时反抛 `ArgumentError`（onError 返回值不符 future 类型）。
  Future<void> close(HostAssistantTarget target, String id) async {
    await _call(
      target,
      'DELETE',
      '/api/assistant/sessions/${Uri.encodeComponent(id)}',
    );
  }

  Future<Map<String, dynamic>> _call(
    HostAssistantTarget target,
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
    Map<String, String> query = const <String, String>{},
    Duration? timeout,
  }) async {
    final InterconnectChannelResponse r;
    try {
      r = await _channel(target.hostRef).send(
        method,
        path,
        query: query,
        body: jsonBody == null ? null : InterconnectRequestBody.json(jsonBody),
        timeout: timeout ?? _requestTimeout,
      );
    } on InterconnectChannelException catch (e) {
      throw HostAssistantException(e.code);
    }
    if (r.statusCode >= 400) {
      // 错误体按本路由原来的字段取（`{reason}`），非 JSON 原样带回。
      throw HostAssistantException(
        'http_${r.statusCode}',
        r.jsonString('reason') ?? r.text,
      );
    }
    return r.jsonObject ?? <String, dynamic>{};
  }
}
