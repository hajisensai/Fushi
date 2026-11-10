/// 互联「代下载」客户端（`/api/downloads`，设计 §3.3）：把磁链交给已配对 host，
/// 由 host 下到它自己的库里；之后经既有远程库路径流播。
library;

import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:http/http.dart' as http;

class HostDownloadTarget {
  const HostDownloadTarget({
    required this.baseUrl,
    required this.deviceName,
    required this.backend,
    this.kinds = const <String>['video'],
    this.fingerprintSha256,
    this.peerUrls = const <String>{},
    this.deleteFilesParam = false,
    this.host,
  });

  /// 这台 host 的身份（client 产出的 target 一律带上）。null = 调用方直接构造的
  /// 老形状 target，按 [baseUrl] 认（见 [hostRef]）。
  final InterconnectHostRef? host;

  /// 请求按它选路 / 取凭据 / 钉扎，而不是按 [baseUrl] 那一条地址。
  InterconnectHostRef get hostRef =>
      host ?? InterconnectHostRef.legacyUrl(interconnectPersistedUrl(baseUrl));

  /// host 的 `DELETE /api/downloads/<id>` 认不认 `deleteFiles` 参数（能力位
  /// `downloads.deleteFilesParam`，BUG-3437）。false = 老 host：删不删文件由它的
  /// 历史缺省决定（app 当 host 保留、无头服务端连数据一起删），客户端无从选择。
  final bool deleteFilesParam;

  /// 这台 host 的持久代表地址（`p2p://` 而非本次的本地转发口）。
  final String baseUrl;

  /// 这台 host 在候选列表里的全部地址（含 [baseUrl]）。「下载执行设备」偏好存的是
  /// 某一条地址，而选路可能经另一条（LAN / IPv6 / 组网 / P2P）到达同一台 host；
  /// 判「是不是偏好里那台」用 [isPeer]，不按 URL 字面比。
  final Set<String> peerUrls;

  /// [url] 是否指向这台 host。
  bool isPeer(String? url) =>
      url != null && (url == baseUrl || peerUrls.contains(url));
  final String? deviceName;

  /// `qbittorrent` / `embedded`。
  final String backend;

  /// host 宣告能收的内容域：`video` 加上它能按域入库的发现页域（`novel` /
  /// `manga` / `audiobook` / `game`）。老 host 不带这个字段 = 只收视频。
  final List<String> kinds;
  final String? fingerprintSha256;

  String get label => deviceName ?? baseUrl;

  /// [discoveryKind] = `DiscoveryMediaKind.name`；null 表示视频。
  bool supportsKind(String? discoveryKind) =>
      discoveryKind == null || kinds.contains(discoveryKind);
}

/// host 上的一条下载任务（`videoDownloadJobToWire` 的镜像）。
class HostDownloadJob {
  const HostDownloadJob({
    required this.jobId,
    required this.title,
    required this.lifecycle,
    required this.stage,
    required this.stageProgress,
    required this.updatedAt,
    this.lastError,
  });

  factory HostDownloadJob.fromJson(Map<String, dynamic> json) =>
      HostDownloadJob(
        jobId: json['jobId'].toString(),
        title: (json['title'] ?? '').toString(),
        lifecycle: (json['lifecycle'] ?? '').toString(),
        stage: (json['stage'] ?? '').toString(),
        stageProgress: (json['stageProgress'] as num?)?.toDouble() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
        lastError: json['lastError']?.toString(),
      );

  final String jobId;
  final String title;
  final String lifecycle;
  final String stage;
  final double stageProgress;
  final int updatedAt;
  final String? lastError;
}

class HostDownloadException implements Exception {
  const HostDownloadException(this.code, [this.detail]);
  final String code;
  final String? detail;

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

/// 代下载 client。传输层（选路、凭据、钉扎、整段超时、client 生命周期、错误
/// 分型）全部走 [InterconnectHostChannel]，每台 host 一条通道、复用到 [close]。
class InterconnectDownloadClient {
  InterconnectDownloadClient({
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
  /// `HostDownloadException('cancelled')`。
  void close() {
    if (_closed) return;
    _closed = true;
    for (final InterconnectHostChannel c in _channels.values) {
      c.close();
    }
    _channels.clear();
    _ownedPlain?.close();
    _ownedPlain = null;
  }

  /// 第一台宣告 `downloads.supported` 的已配对 host（按配对清单顺序，各台并发探）。
  Future<HostDownloadTarget?> probe() async {
    for (final InterconnectCapabilityOutcome<HostDownloadTarget> o
        in await probeAllOutcomes()) {
      if (o is InterconnectCapabilityAvailable<HostDownloadTarget>) {
        return o.target;
      }
    }
    return null;
  }

  /// 只探这一台（用户在「下载执行设备」里选定的那台）；不在配对清单里 / 没宣告
  /// 能力 / 探不到 → null，**不**退而求其次换别的 host——用户点名的设备连不上要
  /// 如实告诉他，而不是悄悄下到另一台机器上。
  ///
  /// [baseUrl] 认的是「那台 host」而不是那一条地址：偏好里存的是用户当初选中时的
  /// 地址（在家可能是 LAN），出门后同一台 host 仍可经 IPv6 / 组网 / P2P 到达，
  /// 由通道在组内选路。
  Future<HostDownloadTarget?> probeUrl(String baseUrl) async {
    final InterconnectHostRef? host = interconnectHostRefForUrl(
      await _repo.getFushiClientUrls(),
      baseUrl,
    );
    if (host == null) return null;
    final InterconnectCapabilityOutcome<HostDownloadTarget> outcome =
        await probeHost(host);
    return outcome is InterconnectCapabilityAvailable<HostDownloadTarget>
        ? outcome.target
        : null;
  }

  /// 全部宣告能力的已配对 host（资源搜索页的「下载到」下拉要列出来让用户挑）。
  /// 每台 host 只产出一个目标。
  Future<List<HostDownloadTarget>> probeAll() async => <HostDownloadTarget>[
    for (final InterconnectCapabilityOutcome<HostDownloadTarget> o
        in await probeAllOutcomes())
      if (o is InterconnectCapabilityAvailable<HostDownloadTarget>) o.target,
  ];

  /// 每台已启用 host 的探测结局（含失败原因），并发探、按配对清单的组序返回。
  Future<List<InterconnectCapabilityOutcome<HostDownloadTarget>>>
  probeAllOutcomes() async {
    final List<InterconnectHostRef> hosts = interconnectPairedHostRefs(
      await _repo.getFushiClientUrls(),
    );
    return Future.wait(
      <Future<InterconnectCapabilityOutcome<HostDownloadTarget>>>[
        for (final InterconnectHostRef h in hosts) probeHost(h),
      ],
    );
  }

  /// 探一台 host 的代下载能力（`downloads.supported`）。
  Future<InterconnectCapabilityOutcome<HostDownloadTarget>> probeHost(
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
    return probeInterconnectCapability<HostDownloadTarget>(
      _channel(host),
      label: interconnectHostLabel(rows, host),
      timeout: _probeTimeout,
      parse: (Map<String, dynamic> caps, FushiClientUrl via) {
        final Object? downloads = caps['downloads'];
        if (downloads is! Map || downloads['supported'] != true) return null;
        final Object? kinds = downloads['kinds'];
        return HostDownloadTarget(
          host: host,
          baseUrl: host.anchorUrl,
          deviceName: via.deviceName ?? groupName,
          backend: (downloads['backend'] ?? '').toString(),
          kinds: kinds is List
              ? kinds.map((Object? k) => k.toString()).toList(growable: false)
              : const <String>['video'],
          fingerprintSha256: groupPin,
          deleteFilesParam: downloads['deleteFilesParam'] == true,
          peerUrls: <String>{
            for (final FushiClientUrl u in interconnectPeerAddressesOf(
              rows,
              host.anchorUrl,
            ))
              u.url,
          },
        );
      },
    );
  }

  /// [discoveryKind] = `DiscoveryMediaKind.name`（非视频域，host 按域入库）；
  /// null = 视频，此时 [mediaKind] 才有意义。
  Future<String> addMagnet(
    HostDownloadTarget target, {
    required String magnetUri,
    required String title,
    String mediaKind = 'movie',
    String? discoveryKind,
  }) async {
    final Map<String, dynamic> body = await _call(
      target,
      'POST',
      '/api/downloads',
      jsonBody: <String, Object?>{
        'magnet': magnetUri,
        'title': title,
        'mediaKind': mediaKind,
        if (discoveryKind != null) 'discoveryKind': discoveryKind,
      },
    );
    return body['jobId'].toString();
  }

  Future<List<HostDownloadJob>> listJobs(HostDownloadTarget target) async {
    final Map<String, dynamic> body = await _call(
      target,
      'GET',
      '/api/downloads',
    );
    final List<dynamic> jobs =
        body['jobs'] as List<dynamic>? ?? const <dynamic>[];
    return jobs
        .whereType<Map>()
        .map((Map e) => HostDownloadJob.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  Future<void> cancel(HostDownloadTarget target, String jobId) => _call(
    target,
    'POST',
    '/api/downloads/${Uri.encodeComponent(jobId)}/cancel',
  );

  Future<void> retry(HostDownloadTarget target, String jobId) => _call(
    target,
    'POST',
    '/api/downloads/${Uri.encodeComponent(jobId)}/retry',
  );

  /// [deleteFiles] 只在 host 宣告 [HostDownloadTarget.deleteFilesParam] 时才发出；
  /// 对老 host 传它会被静默忽略，所以调用方给了却 host 不认时直接报错，而不是
  /// 让用户以为自己的选择生效了。null = 不表态（host 按历史缺省）。
  Future<void> delete(
    HostDownloadTarget target,
    String jobId, {
    bool? deleteFiles,
  }) {
    if (deleteFiles != null && !target.deleteFilesParam) {
      throw const HostDownloadException('delete_files_unsupported');
    }
    return _call(
      target,
      'DELETE',
      '/api/downloads/${Uri.encodeComponent(jobId)}',
      query: deleteFiles == null
          ? const <String, String>{}
          : <String, String>{'deleteFiles': '$deleteFiles'},
    );
  }

  Future<Map<String, dynamic>> _call(
    HostDownloadTarget target,
    String method,
    String path, {
    Map<String, Object?>? jsonBody,
    Map<String, String> query = const <String, String>{},
  }) async {
    final InterconnectChannelResponse r;
    try {
      r = await _channel(target.hostRef).send(
        method,
        path,
        query: query,
        body: jsonBody == null ? null : InterconnectRequestBody.json(jsonBody),
        timeout: _requestTimeout,
      );
    } on InterconnectChannelException catch (e) {
      throw HostDownloadException(e.code);
    }
    if (r.statusCode >= 400) {
      // 错误体按本路由原来的字段取（`{message}`），非 JSON 原样带回。
      throw HostDownloadException(
        'http_${r.statusCode}',
        r.jsonString('message') ?? r.text,
      );
    }
    return r.jsonObject ?? <String, dynamic>{};
  }
}
