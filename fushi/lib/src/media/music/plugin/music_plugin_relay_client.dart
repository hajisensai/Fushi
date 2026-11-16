/// 互联「插件中继」的 client 侧（拍板台 wOMR4_Er7s 方案 b，协议见
/// `package:fushi_engine/sync/interconnect_plugin_relay.dart`）：本机没有插件运行时（iOS）时，
/// 已配对 host 上装着的音乐 / 歌词插件经 [MusicPluginManager.relay] 出现在本机，调用、封面核对、
/// 取流都转给 host 代跑，媒体从 host 的流票地址播放。本机不执行第三方代码、不连插件的平台取流 /
/// 调接口；封面图例外——host 只核对地址，图片由本机直接从插件平台的图片 CDN 加载。
///
/// 只问把本机标为「我的设备」、开着「把来源共享给我的设备」的 host（门在 host 侧）；本机的
/// 「接收共享来源」关着时一个请求都不发。多台 host 装了同一个插件时用配对表里靠前的那台。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/interconnect_plugin_relay.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:meta/meta.dart';

/// 一台可能提供中继的 host（[key] 稳定标识，[label] 给用户看）。
typedef MusicPluginRelayHostRef = ({String key, String label});

/// host 的一次回答：[json] 是 JSON 对象体（不是对象时为 null），[resolve] 把 host 给的路径
/// 拼成本次实际走的那条地址上的绝对 URL。
typedef MusicPluginRelayResponse = ({
  int status,
  Map<String, Object?>? json,
  Uri? Function(String path) resolve,
});

/// 没有任何地址给出 HTTP 回答（离线 / 不可达 / 证书不符 / 凭据被拒）。
final class MusicPluginRelayUnreachable implements Exception {
  const MusicPluginRelayUnreachable(this.code);

  final String code;

  @override
  String toString() => 'MusicPluginRelayUnreachable($code)';
}

/// 中继请求的传输（生产实现 [InterconnectMusicPluginRelayTransport]；测试注入替身）。
abstract interface class MusicPluginRelayTransport {
  /// 此刻配对表里已启用的 host，按配对表顺序。
  Future<List<MusicPluginRelayHostRef>> hosts();

  /// 向 host [hostKey] 发一次请求。没有 HTTP 回答抛 [MusicPluginRelayUnreachable]。
  Future<MusicPluginRelayResponse> send(
    String hostKey,
    String method,
    String path, {
    Object? json,
    required Duration timeout,
  });

  void close();
}

/// 经 [InterconnectHostChannel]（选路、per-peer 凭据、证书钉扎、整段超时）发中继请求。
class InterconnectMusicPluginRelayTransport
    implements MusicPluginRelayTransport {
  InterconnectMusicPluginRelayTransport(this._repository);

  final SyncRepository Function() _repository;
  final Map<String, InterconnectHostChannel> _channels =
      <String, InterconnectHostChannel>{};
  final Map<String, InterconnectHostRef> _refs =
      <String, InterconnectHostRef>{};

  @override
  Future<List<MusicPluginRelayHostRef>> hosts() async {
    final List<FushiClientUrl> rows = await _repository().getFushiClientUrls();
    return <MusicPluginRelayHostRef>[
      for (final InterconnectHostRef ref in interconnectPairedHostRefs(rows))
        (
          key: (_refs[ref.key] = ref).key,
          label: interconnectHostLabel(rows, ref),
        ),
    ];
  }

  @override
  Future<MusicPluginRelayResponse> send(
    String hostKey,
    String method,
    String path, {
    Object? json,
    required Duration timeout,
  }) async {
    final InterconnectHostRef? ref = _refs[hostKey];
    if (ref == null) throw const MusicPluginRelayUnreachable('no_host');
    final InterconnectHostChannel channel = _channels[hostKey] ??=
        InterconnectHostChannel(repo: _repository(), host: ref);
    final InterconnectChannelResponse res;
    try {
      res = await channel.send(
        method,
        path,
        body: json == null ? null : InterconnectRequestBody.json(json),
        timeout: timeout,
        // 能力调用可能是写操作（喜欢 / 编辑歌单）：送出后不换地址重发。
        idempotent: method == 'GET',
      );
    } on InterconnectChannelException catch (e) {
      throw MusicPluginRelayUnreachable(e.code);
    }
    final Map<String, dynamic>? body = res.jsonObject;
    return (
      status: res.statusCode,
      json: body?.cast<String, Object?>(),
      resolve: (String p) => interconnectRequestUri(res.via.url, p),
    );
  }

  @override
  void close() {
    for (final InterconnectHostChannel c in _channels.values) {
      c.close();
    }
    _channels.clear();
  }
}

/// 中继目录里的一项：插件 + 代跑它的 host。
@immutable
class _RelayEntry {
  const _RelayEntry(this.plugin, this.hostKey);

  final MusicPluginRelayedPlugin plugin;
  final String hostKey;
}

/// 插件中继的 client 实现。目录按 [cacheTtl] 缓存（插件页、搜索、歌词频繁地列插件，不能每次
/// 都去问每台 host）；某个插件在 host 上不再可用时立刻重拉。
class InterconnectMusicPluginRelay implements MusicPluginRelay {
  InterconnectMusicPluginRelay({
    required MusicPluginRelayTransport transport,
    required Future<bool> Function() enabled,
    this.cacheTtl = const Duration(minutes: 2),
    this.catalogTimeout = const Duration(seconds: 8),
    @visibleForTesting DateTime Function()? now,
  }) : _transport = transport,
       _enabled = enabled,
       _now = now ?? DateTime.now;

  final MusicPluginRelayTransport _transport;
  final Future<bool> Function() _enabled;
  final DateTime Function() _now;

  /// 目录缓存多久。
  final Duration cacheTtl;

  /// 问一台 host 的目录最多等多久（离线的 host 不能把插件页拖住）。
  final Duration catalogTimeout;

  final StreamController<void> _changes = StreamController<void>.broadcast();
  Map<String, _RelayEntry>? _catalog;
  DateTime? _loadedAt;
  Future<Map<String, _RelayEntry>>? _loading;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<MusicPluginRelayedPlugin>> list() async =>
      <MusicPluginRelayedPlugin>[
        for (final _RelayEntry e in (await _entries()).values) e.plugin,
      ];

  @override
  Future<MusicPluginRuntime> open(String id) async {
    _RelayEntry? entry = (await _entries())[id];
    entry ??= (await _entries(force: true))[id];
    if (entry == null) {
      throw MusicPluginUnavailableException(
        '插件不再经互联提供',
        pluginId: id,
        reason: MusicPluginUnavailableReason.notInstalled,
      );
    }
    return _RelayedRuntime(this, entry);
  }

  /// 丢掉缓存，下次使用时重拉（host 说某插件已不可用时调）。
  void invalidate() {
    _loadedAt = null;
  }

  Future<Map<String, _RelayEntry>> _entries({bool force = false}) {
    final DateTime? at = _loadedAt;
    final Map<String, _RelayEntry>? cached = _catalog;
    if (!force &&
        cached != null &&
        at != null &&
        _now().difference(at) < cacheTtl) {
      return Future<Map<String, _RelayEntry>>.value(cached);
    }
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<Map<String, _RelayEntry>> _load() async {
    final Map<String, _RelayEntry> next = <String, _RelayEntry>{};
    // 契约（[MusicPluginRelay.list]）：取不到时为空、不抛。读开关 / 配对表失败（库关着、
    // 迁移中）若往上抛，[MusicPluginManager.list] 会连本机已装插件一起列不出来。
    final List<MusicPluginRelayHostRef> hosts;
    try {
      hosts = await _enabled()
          ? await _transport.hosts()
          : const <MusicPluginRelayHostRef>[];
    } on Object catch (e) {
      debugPrint('[music-plugin-relay] host list unavailable: $e');
      return _catalog ?? next;
    }
    {
      final List<List<MusicPluginRelayedPlugin>> perHost = await Future.wait(
        <Future<List<MusicPluginRelayedPlugin>>>[
          for (final MusicPluginRelayHostRef h in hosts) _catalogOf(h),
        ],
      );
      for (int i = 0; i < hosts.length; i++) {
        for (final MusicPluginRelayedPlugin p in perHost[i]) {
          next.putIfAbsent(p.id, () => _RelayEntry(p, hosts[i].key));
        }
      }
    }
    final Map<String, _RelayEntry>? previous = _catalog;
    _catalog = next;
    _loadedAt = _now();
    if (previous != null && !_sameCatalog(previous, next)) {
      _changes.add(null);
    }
    return next;
  }

  static bool _sameCatalog(
    Map<String, _RelayEntry> a,
    Map<String, _RelayEntry> b,
  ) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, _RelayEntry> e in a.entries) {
      final _RelayEntry? o = b[e.key];
      if (o == null ||
          o.hostKey != e.value.hostKey ||
          o.plugin.info.digest != e.value.plugin.info.digest) {
        return false;
      }
    }
    return true;
  }

  /// 一台 host 的中继目录。旧 host（404）、明文、关着、本机不是它的「我的设备」、不可达都是
  /// 「这台此刻不给」，回空，不报错。
  Future<List<MusicPluginRelayedPlugin>> _catalogOf(
    MusicPluginRelayHostRef host,
  ) async {
    final MusicPluginRelayResponse res;
    try {
      res = await _transport.send(
        host.key,
        'GET',
        kInterconnectPluginRelayPath,
        timeout: catalogTimeout,
      );
    } on MusicPluginRelayUnreachable {
      return const <MusicPluginRelayedPlugin>[];
    }
    final Object? plugins = res.json?['plugins'];
    if (res.status != 200 || plugins is! List) {
      return const <MusicPluginRelayedPlugin>[];
    }
    final List<MusicPluginRelayedPlugin> out = <MusicPluginRelayedPlugin>[];
    for (final Object? raw in plugins) {
      if (raw is! Map) continue;
      try {
        final MusicPluginPackageInfo info = MusicPluginPackageInfo.fromJson(
          raw.cast<String, Object?>(),
        );
        if (!info.manifest.isMusic) continue;
        out.add(
          MusicPluginRelayedPlugin(
            // 不经中继的能力 host 已去掉；这里再去一次，别让旧 / 异常 host 的清单露出登录入口。
            info: MusicPluginPackageInfo(
              manifest: info.manifest.withoutCapabilities(
                kMusicPluginRelayExcludedCapabilities,
              ),
              digest: info.digest,
              signer: info.signer,
              files: info.files,
            ),
            via: host.label,
          ),
        );
      } on Object {
        // 一条坏项不影响其余（host 是别的版本时字段可能对不上）。
        continue;
      }
    }
    return out;
  }

  /// 向代跑 [entry] 的 host 发一次中继请求，返回 2xx 的 JSON 体；失败抛 [MusicPluginException]
  /// （host 说插件已不可用时是 [MusicPluginUnavailableException]，并作废目录缓存）。
  Future<Map<String, Object?>> _post(
    _RelayEntry entry,
    String path,
    Map<String, Object?> body, {
    required Duration timeout,
    void Function(MusicPluginRelayResponse res)? onSuccess,
  }) async {
    final String id = entry.plugin.id;
    final MusicPluginRelayResponse res;
    try {
      res = await _transport.send(
        entry.hostKey,
        'POST',
        path,
        json: <String, Object?>{'plugin': id, ...body},
        timeout: timeout,
      );
    } on MusicPluginRelayUnreachable {
      throw MusicPluginException('连不上${entry.plugin.via}', pluginId: id);
    }
    final Map<String, Object?>? json = res.json;
    if (res.status >= 200 && res.status < 300 && json != null) {
      onSuccess?.call(res);
      return json;
    }
    final String code = '${json?['error'] ?? 'http_${res.status}'}';
    final String message = '${json?['message'] ?? code}';
    if (code == kPluginRelayNotAvailable ||
        code == 'disabled' ||
        code == 'not_owner_device' ||
        res.status == 404) {
      // 目录作废并通知订阅方重列（重列时现拉），不在这里另起一个没人等的请求。
      invalidate();
      if (!_changes.isClosed) _changes.add(null);
      throw MusicPluginUnavailableException(
        '${entry.plugin.via}上的插件此刻不可用',
        pluginId: id,
        reason: MusicPluginUnavailableReason.notInstalled,
      );
    }
    throw MusicPluginException(message, pluginId: id);
  }

  void dispose() {
    unawaited(_changes.close());
    _transport.close();
  }
}

/// 中继插件的可调用实例：每次调用都转给 host。
class _RelayedRuntime implements MusicPluginRuntime {
  _RelayedRuntime(this._relay, this._entry);

  final InterconnectMusicPluginRelay _relay;
  final _RelayEntry _entry;

  /// host 自己的插件调用时限之外，再留给网络的余量。
  static const Duration _networkMargin = Duration(seconds: 15);

  @override
  MusicPluginPackageInfo get info => _entry.plugin.info;

  @override
  bool get isAlive => true;

  @override
  Future<Object?> invoke(
    String method,
    Map<String, Object?> args, {
    Duration? timeout,
  }) async {
    final Map<String, Object?> r = await _relay._post(
      _entry,
      kInterconnectPluginRelayInvokePath,
      <String, Object?>{'method': method, 'args': args},
      timeout: (timeout ?? musicPluginInvokeTimeout(method)) + _networkMargin,
    );
    return r['value'];
  }

  /// 登录不经中继（[kMusicPluginRelayExcludedCapabilities]），没有要核对的登录页地址。
  @override
  Map<String, String> checkRequestUrls(Iterable<String> urls) =>
      const <String, String>{};

  @override
  Future<Map<String, String>> checkCoverUrls(Iterable<String> urls) async {
    final List<String> list = urls.toSet().toList();
    if (list.isEmpty) return const <String, String>{};
    final Map<String, Object?> r = await _relay._post(
      _entry,
      kInterconnectPluginRelayCoversPath,
      <String, Object?>{'urls': list},
      timeout: kMusicPluginInvokeTimeout,
    );
    final Object? covers = r['covers'];
    if (covers is! Map) return const <String, String>{};
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in covers.entries)
        if (e.key is String && e.value is String)
          e.key! as String: e.value! as String,
    };
  }

  @override
  Future<({String url, Map<String, String> headers})> resolveMediaStream(
    String url,
    Map<String, String> headers,
  ) async {
    Uri? Function(String path)? resolve;
    final Map<String, Object?> r;
    try {
      r = await _relay._post(
        _entry,
        kInterconnectPluginRelayMediaPath,
        <String, Object?>{'url': url, 'headers': headers},
        timeout: kMusicPluginStreamTimeout + _networkMargin,
        onSuccess: (MusicPluginRelayResponse res) => resolve = res.resolve,
      );
    } on MusicPluginException catch (e) {
      throw MusicPluginHttpException(e.message);
    }
    final Object? path = r['path'];
    final Uri? stream = path is String ? resolve?.call(path) : null;
    if (stream == null) {
      throw const MusicPluginHttpException('主机没有给出播放地址');
    }
    // 流票地址自带门（host 现查签发凭据），播放器不需要任何请求头。
    return (url: stream.toString(), headers: const <String, String>{});
  }
}
