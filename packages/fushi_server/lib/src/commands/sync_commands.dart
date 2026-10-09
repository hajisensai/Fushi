/// `fushi_server sync …`：服务端**作为互联 client** 去同步另一台 host。
///
/// 范围：只做聚合维度（学习统计 + 收藏词 / 收藏句，`/api/library/aggregate`）。
/// 书 / 视频 / 合集 / 标签等维度的 client 侧编排（`InterconnectSyncBackend` +
/// `SyncOrchestrator`，含合集基线 `SyncRepository`）全在 `fushi/` 里，无头服务端
/// 用不了；聚合维度的通道无关核心 `AggregateSyncService` 在引擎里，这里只补传输。
///
/// 凭据（服务端此前没有「作为 client 已配对」的存储）：
/// - `sync pair <url> --fingerprint <sha256>`：走引擎的 v2 配对（`FushiPairV2Client`，
///   指纹钉扎、PIN 只过 HMAC proof，需要 host 上的人点同意），拿到的 per-peer token
///   落 `<support>/interconnect_client/peers.json`（0600，**不进偏好表**——偏好表会被
///   备份 / Profile 迁移带出机器）；
/// - 或者跳过配对，用环境变量 `FUSHI_SYNC_TOKEN` 直接给 token（不进 argv）。
///
/// TLS：https 端点一律钉扎证书指纹（`createPinnedHttpClient`），没有指纹就拒绝，
/// 不做盲 TOFU。明文 http 必须显式 `--allow-http`（token 会明文过线）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_v2_client.dart';
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/credential_http_proxy.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;

const int _exitOk = 0;
const int _exitFailure = 1;
const int _exitUsage = 64;
const int _exitUnavailable = 69;

/// 直接给 token 的环境变量（优先于已配对记录）。
const String kSyncTokenEnv = 'FUSHI_SYNC_TOKEN';

/// 互联 Basic 鉴权的固定用户名（与 app `InterconnectSyncBackend` 同值）。
const String _interconnectUser = 'hibiki';

const Duration _requestTimeout = Duration(seconds: 60);

/// 归一化 host 根地址：只收 http / https、有 host、无 path / query；去尾斜杠。
/// 不合法返回 null。
Uri? normalizeSyncPeerUrl(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return null;
  if (uri.query.isNotEmpty || uri.fragment.isNotEmpty) return null;
  final String path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (path.isNotEmpty) return null;
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
}

/// 一台已配对 host 的凭据。
class SyncPeerCredential {
  const SyncPeerCredential({required this.url, required this.token, this.fingerprint, this.pairedAt = 0});

  factory SyncPeerCredential.fromJson(Map<String, Object?> j) => SyncPeerCredential(
    url: j['url']! as String,
    token: j['token']! as String,
    fingerprint: j['fingerprint'] as String?,
    pairedAt: (j['pairedAt'] as num?)?.toInt() ?? 0,
  );

  final String url;
  final String token;
  final String? fingerprint;
  final int pairedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'token': token,
    if (fingerprint != null) 'fingerprint': fingerprint,
    'pairedAt': pairedAt,
  };
}

/// `<support>/interconnect_client/peers.json`：服务端作为 client 的配对凭据。
class SyncPeerCredentialStore {
  SyncPeerCredentialStore(this.file);

  factory SyncPeerCredentialStore.under(Directory support) =>
      SyncPeerCredentialStore(File(p.join(support.path, 'interconnect_client', 'peers.json')));

  final File file;

  /// 文件坏了抛 [FormatException]（不静默当空——那会让下一次 [save] 抹掉其余凭据）。
  Future<List<SyncPeerCredential>> load() async {
    if (!await file.exists()) return <SyncPeerCredential>[];
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['peers'] is! List) {
      throw FormatException('凭据文件形状不对: ${file.path}');
    }
    return <SyncPeerCredential>[
      for (final Object? row in decoded['peers'] as List<Object?>)
        if (row is Map) SyncPeerCredential.fromJson(row.cast<String, Object?>()),
    ];
  }

  Future<SyncPeerCredential?> find(String url) async {
    for (final SyncPeerCredential c in await load()) {
      if (c.url == url) return c;
    }
    return null;
  }

  Future<void> save(List<SyncPeerCredential> peers) async {
    await file.parent.create(recursive: true);
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'peers': <Object?>[for (final SyncPeerCredential c in peers) c.toJson()],
      }),
      flush: true,
    );
    if (!Platform.isWindows) {
      // token 等同密码：只给属主读写。chmod 失败就不落盘（宁可报错也不留可读的凭据）。
      final ProcessResult r = await Process.run('chmod', <String>['600', tmp.path]);
      if (r.exitCode != 0) {
        await tmp.delete();
        throw FileSystemException('chmod 600 失败: ${r.stderr}', tmp.path);
      }
    }
    await tmp.rename(file.path);
  }

  Future<void> upsert(SyncPeerCredential credential) async {
    final List<SyncPeerCredential> peers =
        (await load()).where((SyncPeerCredential c) => c.url != credential.url).toList()..add(credential);
    await save(peers);
  }

  Future<bool> remove(String url) async {
    final List<SyncPeerCredential> peers = await load();
    final List<SyncPeerCredential> kept = peers.where((SyncPeerCredential c) => c.url != url).toList();
    if (kept.length == peers.length) return false;
    await save(kept);
    return true;
  }
}

/// 传输层失败，带建议退出码。
class SyncRemoteException implements Exception {
  const SyncRemoteException(this.exitCode, this.message);

  final int exitCode;
  final String message;

  @override
  String toString() => message;
}

/// host 聚合端点的读写。
abstract class AggregateRemote {
  /// host 的聚合快照 JSON；老 host 无端点（404）返回 null。
  Future<Object?> fetch();

  Future<void> push(Object json);

  void close();
}

/// 经 dart:io 直连 host：https 用钉扎客户端，http（已显式允许）用裸客户端。
class HttpAggregateRemote implements AggregateRemote {
  HttpAggregateRemote({required this.baseUrl, required String token, String? fingerprint})
    : _auth = 'Basic ${base64Encode(utf8.encode('$_interconnectUser:$token'))}',
      // 每个请求都带 host token：明文 / 回环目标恒直连，https 才跟随环境代理（CONNECT
      // 隧道 + 指纹钉扎，代理读不到 token），见 credential_http_proxy.dart。
      _client = withCredentialProxyPolicy(
        fingerprint == null
            ? (HttpClient()..connectionTimeout = const Duration(seconds: 15))
            : createPinnedHttpClient(expectedFingerprint: fingerprint, connectionTimeout: const Duration(seconds: 15)),
      );

  final Uri baseUrl;
  final String _auth;
  final HttpClient _client;

  Uri get _endpoint => baseUrl.replace(path: '/api/library/aggregate');

  Future<HttpClientResponse> _send(String method, {Object? body}) async {
    try {
      final HttpClientRequest req = await _client.openUrl(method, _endpoint).timeout(_requestTimeout);
      req.headers.set(HttpHeaders.authorizationHeader, _auth);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      return await req.close().timeout(_requestTimeout);
    } on TlsException catch (e) {
      throw SyncRemoteException(_exitUnavailable, 'TLS 握手失败（证书指纹不符或链路被拦）: ${e.message}');
    } on SocketException catch (e) {
      throw SyncRemoteException(_exitUnavailable, '连不上 $baseUrl: ${e.message}');
    } on TimeoutException {
      throw SyncRemoteException(_exitUnavailable, '请求 $baseUrl 超时');
    }
  }

  void _checkStatus(HttpClientResponse res, String what) {
    if (res.statusCode == HttpStatus.unauthorized || res.statusCode == HttpStatus.forbidden) {
      throw SyncRemoteException(_exitUnavailable, '$what 被拒（${res.statusCode}）：token 无效或已被吊销，重新 sync pair');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SyncRemoteException(_exitFailure, '$what 失败: HTTP ${res.statusCode}');
    }
  }

  @override
  Future<Object?> fetch() async {
    final HttpClientResponse res = await _send('GET');
    if (res.statusCode == HttpStatus.notFound) {
      await res.drain<void>();
      return null;
    }
    _checkStatus(res, 'GET /api/library/aggregate');
    return jsonDecode(await utf8.decodeStream(res));
  }

  @override
  Future<void> push(Object json) async {
    final HttpClientResponse res = await _send('PUT', body: json);
    await res.drain<void>();
    _checkStatus(res, 'PUT /api/library/aggregate');
  }

  @override
  void close() => _client.close(force: true);
}

/// 一份快照里各家族的条数（输出用）。
Map<String, int> aggregateSnapshotCounts(AggregateSnapshot s) => <String, int>{
  'studySegments': s.studySegments.length,
  'studySegmentTombstones': s.studySegmentTombstones.length,
  'readingStats': s.readingStats.length,
  'videoStats': s.videoStats.length,
  'miningStats': s.miningStats.length,
  'lookupMiningCounters': s.lookupMiningCounters.length,
  'favoriteWords': s.favoriteWords.length,
  'favoriteSentences': s.favoriteSentences.length,
};

/// 跑一次聚合同步。默认只拉（host 快照折进本机 DB，只增不减、幂等，不写 host）；
/// [push] 时走与 app 互联通道同一个 [AggregateSyncService.syncOverClient]
/// （拉 → 并集 → 写回本机 → 合并结果推回 host）。
///
/// 老 host 无聚合端点时抛 [SyncRemoteException]（69）——只拉的命令没有可退化的路径。
Future<Map<String, Object?>> runAggregatePull(
  FushiDatabase db,
  AggregateRemote remote, {
  bool push = false,
  bool stats = true,
  bool favorites = true,
}) async {
  final AggregateSyncService service = AggregateSyncService(db);
  if (push) {
    Object? fetched;
    bool pushed = false;
    await service.syncOverClient(
      fetchRemote: () async => fetched = await remote.fetch(),
      pushMerged: (Object json) async {
        await remote.push(json);
        pushed = true;
      },
      shareStats: stats,
      shareFavorites: favorites,
    );
    return <String, Object?>{
      'mode': 'push',
      'hostHasEndpoint': fetched != null,
      'pulled': fetched == null
          ? null
          : aggregateSnapshotCounts(AggregateSnapshot.fromJson(fetched).select(stats: stats, favorites: favorites)),
      'pushed': pushed,
    };
  }
  final Object? json = await remote.fetch();
  if (json == null) {
    throw const SyncRemoteException(_exitUnavailable, 'host 没有 /api/library/aggregate 端点（版本过旧），无法拉取');
  }
  final AggregateSnapshot incoming = AggregateSnapshot.fromJson(json).select(stats: stats, favorites: favorites);
  await service.foldIntoLocal(incoming);
  return <String, Object?>{
    'mode': 'pull',
    'hostHasEndpoint': true,
    'pulled': aggregateSnapshotCounts(incoming),
    'pushed': false,
  };
}

/// 解析出的同步目标。
typedef SyncTarget = ({Uri url, String token, String? fingerprint});

/// 由命令行 + 环境变量 + 已配对记录解出目标；失败返回 (null, 退出码, 原因)。
Future<(SyncTarget?, int, String)> resolveSyncTarget({
  required String rawUrl,
  required String? fingerprintArg,
  required bool allowHttp,
  required String? envToken,
  required SyncPeerCredentialStore store,
}) async {
  final Uri? url = normalizeSyncPeerUrl(rawUrl);
  if (url == null) return (null, _exitUsage, '不是合法的 host 根地址: $rawUrl（形如 https://192.168.1.5:38765）');
  final SyncPeerCredential? saved = await store.find(url.toString());
  final String? fingerprint = (fingerprintArg != null && fingerprintArg.trim().isNotEmpty)
      ? fingerprintArg.trim()
      : saved?.fingerprint;
  if (url.scheme == 'https') {
    if (fingerprint == null || fingerprint.isEmpty) {
      return (null, _exitUsage, 'https 互联端点是自签证书，必须用 --fingerprint <sha256> 钉扎（host 的配对页 / status 里有）');
    }
    final String? savedFp = saved?.fingerprint;
    if (savedFp != null && !fingerprintEquals(savedFp, fingerprint)) {
      return (null, _exitFailure, '--fingerprint 与已配对记录的指纹不符；确认 host 换过证书后先 sync forget 再重新配对');
    }
  } else {
    if (!allowHttp) return (null, _exitUsage, '明文 http 会让 token 明文过线；确认在可信网络里再加 --allow-http');
    if (fingerprintArg != null) return (null, _exitUsage, 'http 端点没有证书，--fingerprint 无意义');
  }
  final String? token = (envToken != null && envToken.isNotEmpty) ? envToken : saved?.token;
  if (token == null || token.isEmpty) {
    return (null, _exitUnavailable, '没有 $url 的凭据：先 sync pair $url --fingerprint …，或设置环境变量 $kSyncTokenEnv');
  }
  return ((url: url, token: token, fingerprint: url.scheme == 'https' ? fingerprint : null), _exitOk, '');
}

/// 配对失败原因 → (退出码, 说明)。
(int, String) describePairFailure(String reason) => switch (reason) {
  'pin' => (_exitFailure, 'PIN 不对'),
  'declined' => (_exitFailure, 'host 上拒绝了配对'),
  'cancelled' => (_exitFailure, '已取消'),
  'unavailable' => (_exitUnavailable, 'host 没有配对审批界面（无头 host / 旧版本），无法配对'),
  'rate_limited' => (_exitUnavailable, 'PIN 连错太多次，host 暂时锁定了这个来源，稍后再试'),
  'tls' => (_exitUnavailable, 'TLS 握手失败：证书指纹不符或链路被拦'),
  'timeout' => (_exitUnavailable, '等待 host 应答超时（host 上的人没点同意？）'),
  _ => (_exitUnavailable, '配对失败（$reason）'),
};

class SyncModule extends CliModule {
  const SyncModule({this.out, this.err, this.env, this.remoteFactory, this.readPin});

  final StringSink? out;
  final StringSink? err;

  /// 测试注入点：环境变量表 / 传输 / PIN 输入。
  final Map<String, String>? env;
  final AggregateRemote Function(SyncTarget target)? remoteFactory;
  final Future<String?> Function()? readPin;

  @override
  List<String> get commands => const <String>['sync'];

  @override
  void register(ArgParser parser) {
    final ArgParser sync = parser.addCommand('sync');
    sync.addCommand('pull')
      ..addOption('fingerprint', help: 'host 证书 SHA-256 指纹（https 必填，已配对时可省）')
      ..addFlag('allow-http', negatable: false, help: '允许明文 http 端点')
      ..addFlag('push', negatable: false, help: '双向：合并结果再推回 host（缺省只拉）')
      ..addFlag('stats', defaultsTo: true, help: '同步学习统计')
      ..addFlag('favorites', defaultsTo: true, help: '同步收藏词 / 收藏句')
      ..addFlag('json', negatable: false, help: '输出 JSON');
    sync.addCommand('pair')
      ..addOption('fingerprint', help: 'host 证书 SHA-256 指纹（必填，从 host 的配对页抄）')
      ..addFlag('json', negatable: false, help: '输出 JSON');
    sync.addCommand('peers').addFlag('json', negatable: false, help: '输出 JSON');
    sync.addCommand('forget');
  }

  @override
  String get usage =>
      '''
sync pair <https://host:port> --fingerprint <sha256>
    以本服务端身份向另一台 host 配对（host 上需点同意；要 PIN 时从 stdin 读）
sync pull <url> [--fingerprint <sha256>] [--allow-http] [--push] [--no-stats] [--no-favorites] [--json]
    拉取 host 的学习统计 + 收藏并折进本机（只增不减）；--push 时把合并结果推回 host。
    凭据取已配对记录，或环境变量 $kSyncTokenEnv。只覆盖聚合维度（书 / 视频 / 合集
    的互联同步编排在 app 侧，服务端没有）。serve 也在跑且本机同时是该 host 的对端时，
    两个进程会并发写统计表，建议先停 serve 或改在 app 侧发起。
sync peers [--json] | sync forget <url>''';

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final StringSink o = out ?? stdout;
    final StringSink e = err ?? stderr;
    final ArgResults? sub = command.command;
    switch (sub?.name) {
      case 'pull':
        return _pull(sub!, ctx, o, e);
      case 'pair':
        return _pair(sub!, ctx, o, e);
      case 'peers':
        return ctx.withRuntime((ServerRuntime rt) async {
          final List<SyncPeerCredential> peers = await SyncPeerCredentialStore.under(rt.paths.support).load();
          if (sub!['json'] as bool) {
            o.writeln(
              const JsonEncoder.withIndent('  ').convert(<Object?>[
                for (final SyncPeerCredential c in peers)
                  <String, Object?>{'url': c.url, 'fingerprint': c.fingerprint, 'pairedAt': c.pairedAt},
              ]),
            );
          } else if (peers.isEmpty) {
            o.writeln('（尚未以 client 身份配对任何 host）');
          } else {
            for (final SyncPeerCredential c in peers) {
              o.writeln(
                '${c.url}  ${c.fingerprint ?? '-'}  '
                'paired ${DateTime.fromMillisecondsSinceEpoch(c.pairedAt).toIso8601String()}',
              );
            }
          }
          return _exitOk;
        });
      case 'forget':
        if (sub!.rest.length != 1) {
          e.writeln('用法: sync forget <url>');
          return _exitUsage;
        }
        final Uri? url = normalizeSyncPeerUrl(sub.rest.single);
        if (url == null) {
          e.writeln('不是合法的 host 根地址: ${sub.rest.single}');
          return _exitUsage;
        }
        return ctx.withRuntime((ServerRuntime rt) async {
          final bool removed = await SyncPeerCredentialStore.under(rt.paths.support).remove(url.toString());
          (removed ? o : e).writeln(removed ? '已删除 $url 的凭据' : '没有 $url 的凭据');
          return removed ? _exitOk : _exitFailure;
        });
    }
    e.writeln('用法: sync pair|pull|peers|forget …');
    return _exitUsage;
  }

  Future<int> _pull(ArgResults sub, CliContext ctx, StringSink o, StringSink e) async {
    if (sub.rest.length != 1) {
      e.writeln('用法: sync pull <url> [--fingerprint <sha256>] [--push] [--json]');
      return _exitUsage;
    }
    final bool stats = sub['stats'] as bool;
    final bool favorites = sub['favorites'] as bool;
    if (!stats && !favorites) {
      e.writeln('--no-stats 与 --no-favorites 同时给出：没有要同步的东西');
      return _exitUsage;
    }
    return ctx.withRuntime((ServerRuntime rt) async {
      final (SyncTarget? target, int code, String why) = await resolveSyncTarget(
        rawUrl: sub.rest.single,
        fingerprintArg: sub['fingerprint'] as String?,
        allowHttp: sub['allow-http'] as bool,
        envToken: (env ?? Platform.environment)[kSyncTokenEnv],
        store: SyncPeerCredentialStore.under(rt.paths.support),
      );
      if (target == null) {
        e.writeln(why);
        return code;
      }
      final AggregateRemote remote =
          (remoteFactory ??
          (SyncTarget t) => HttpAggregateRemote(baseUrl: t.url, token: t.token, fingerprint: t.fingerprint))(target);
      try {
        e.writeln('同步 ${target.url} …');
        final Map<String, Object?> result = await runAggregatePull(
          rt.db,
          remote,
          push: sub['push'] as bool,
          stats: stats,
          favorites: favorites,
        );
        final Map<String, Object?> report = <String, Object?>{'host': target.url.toString(), ...result};
        if (sub['json'] as bool) {
          o.writeln(const JsonEncoder.withIndent('  ').convert(report));
        } else {
          final Object? pulled = result['pulled'];
          o.writeln(pulled == null ? 'host 无聚合端点，只推了本机快照' : '已拉取并折进本机: $pulled');
          if (result['pushed'] == true) o.writeln('合并结果已推回 host');
        }
        return _exitOk;
      } on SyncRemoteException catch (x) {
        e.writeln(x.message);
        return x.exitCode;
      } finally {
        remote.close();
      }
    });
  }

  Future<int> _pair(ArgResults sub, CliContext ctx, StringSink o, StringSink e) async {
    if (sub.rest.length != 1) {
      e.writeln('用法: sync pair <https://host:port> --fingerprint <sha256>');
      return _exitUsage;
    }
    final Uri? url = normalizeSyncPeerUrl(sub.rest.single);
    if (url == null || url.scheme != 'https') {
      e.writeln('配对只走 https（v2 配对协议靠证书钉扎防中间人）: ${sub.rest.single}');
      return _exitUsage;
    }
    final String? fingerprint = (sub['fingerprint'] as String?)?.trim();
    if (fingerprint == null || fingerprint.isEmpty) {
      e.writeln('必须给 --fingerprint（从 host 的配对页抄写证书指纹；不做盲 TOFU）');
      return _exitUsage;
    }
    return ctx.withRuntime((ServerRuntime rt) async {
      e.writeln('向 $url 发起配对，请在 host 上点同意 …');
      final FushiPairV2Outcome outcome =
          await FushiPairV2Client(baseUrl: url.toString(), expectedFingerprint: fingerprint).pair(
            deviceName: rt.config.deviceName,
            clientDeviceId: rt.identity.deviceId,
            pinProvider:
                readPin ??
                () async {
                  e.write('host 要求 PIN，输入 host 上显示的 6 位 PIN: ');
                  return stdin.readLineSync()?.trim();
                },
          );
      switch (outcome) {
        case FushiPairV2Failure(:final String reason):
          final (int code, String why) = describePairFailure(reason);
          e.writeln(why);
          return code;
        case FushiPairV2Success(:final String token, :final String? hostFingerprint):
          if (hostFingerprint != null && !fingerprintEquals(hostFingerprint, fingerprint)) {
            e.writeln('host 回执的证书指纹与钉扎值不符，拒绝保存凭据');
            return _exitFailure;
          }
          await SyncPeerCredentialStore.under(rt.paths.support).upsert(
            SyncPeerCredential(
              url: url.toString(),
              token: token,
              fingerprint: fingerprint,
              pairedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          if (sub['json'] as bool) {
            o.writeln(jsonEncode(<String, Object?>{'url': url.toString(), 'paired': true}));
          } else {
            o.writeln('已配对 $url（凭据存在本机，可直接 sync pull $url）');
          }
          return _exitOk;
      }
    });
  }
}
