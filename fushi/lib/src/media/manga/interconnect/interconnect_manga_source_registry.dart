/// 「Fushi 互联」漫画来源合集的进程内注册表：聚合所有在线对端透出的扩展源，
/// 供来源页（列出 + 开关）、发现页（卡片 / 热门行 / 聚合搜索）与适配器（按源 id
/// 找到该走哪台对端）共用一份快照。
///
/// 真值只有对端——本机不落库任何源清单：对端停用 / 卸载一个源，下一次探测它就
/// 没了；只有「用户在本机关掉了哪些源」进偏好（[PreferencesRepository]）。探测有
/// 网络代价（每台对端两次 GET），所以按 [staleAfter] 节流：页面进入时调 [ensureFresh]，
/// 用户点刷新才 [refresh] 强制重探。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_client.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/manga_sources/host_manga_source_host.dart';

class InterconnectMangaSourceRegistry extends ChangeNotifier {
  InterconnectMangaSourceRegistry({
    required InterconnectMangaSourceTransport transport,
    required SyncRepository syncRepository,
    required PreferencesRepository prefs,
    this.staleAfter = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _transport = transport,
       _syncRepository = syncRepository,
       _prefs = prefs,
       _now = now ?? DateTime.now {
    // 互联总开关的另一个写入口在同步设置页（BUG-1560 同因）：不订阅这条广播，从
    // 那里关掉互联后本合集仍列着对端的源。
    SyncRepository.interconnectEnabledRevision.addListener(
      _onInterconnectToggled,
    );
    _prefs.addListener(notifyListeners);
  }

  final InterconnectMangaSourceTransport _transport;
  final SyncRepository _syncRepository;
  final PreferencesRepository _prefs;
  final Duration staleAfter;
  final DateTime Function() _now;

  List<InterconnectMangaSourcePeer> _peers =
      const <InterconnectMangaSourcePeer>[];
  bool _interconnectEnabled = false;
  bool _loading = false;
  Object? _error;
  DateTime? _refreshedAt;
  Future<void>? _inFlight;

  /// 互联总开关（全应用一个）当前是否开着；关着时 [sources] 恒空。
  bool get interconnectEnabled => _interconnectEnabled;
  bool get loading => _loading;
  Object? get error => _error;
  DateTime? get refreshedAt => _refreshedAt;

  /// 本机偏好里的合集总开关。
  bool get collectionEnabled => _prefs.mangaInterconnectSourcesEnabled;

  /// 「对端漫画库」子项是否参与发现（合集总开关 + 互联总开关都开才算）。
  bool get libraryEnabled =>
      _interconnectEnabled &&
      collectionEnabled &&
      _prefs.mangaInterconnectLibraryEnabled;

  /// 探到的全部对端源，按源 id 去重（同一个源在多台对端上时保留先探到的那台）。
  ///
  /// 不管本机开关——来源页要把关掉的也列出来给用户开回去。
  List<InterconnectRemoteSource> get sources {
    if (!_interconnectEnabled) return const <InterconnectRemoteSource>[];
    final Map<String, InterconnectRemoteSource> byId =
        <String, InterconnectRemoteSource>{};
    for (final InterconnectMangaSourcePeer peer in _peers) {
      for (final RemoteMangaSourceInfo info in peer.sources) {
        byId.putIfAbsent(
          info.id,
          () => InterconnectRemoteSource(info: info, peer: peer),
        );
      }
    }
    return byId.values.toList(growable: false);
  }

  /// 参与发现页 / 聚合搜索的源：合集开着且用户没在本机关掉的那些。
  List<InterconnectRemoteSource> get enabledSources {
    if (!collectionEnabled) return const <InterconnectRemoteSource>[];
    final Set<String> disabled = _prefs.mangaInterconnectDisabledSourceIds;
    return <InterconnectRemoteSource>[
      for (final InterconnectRemoteSource s in sources)
        if (!disabled.contains(s.id)) s,
    ];
  }

  bool isSourceEnabled(String sourceId) =>
      !_prefs.mangaInterconnectDisabledSourceIds.contains(sourceId);

  /// 按源 id 定位它此刻经哪台对端走；快照里没有就重探一次（书架上的条目可能是
  /// 上次会话加的，本次还没探过）。仍没有 → null（对端离线 / 已停用该源）。
  Future<InterconnectRemoteSource?> resolve(String sourceId) async {
    InterconnectRemoteSource? found = _find(sourceId);
    if (found != null) return found;
    await refresh();
    found = _find(sourceId);
    return found;
  }

  InterconnectRemoteSource? _find(String sourceId) {
    for (final InterconnectRemoteSource s in sources) {
      if (s.id == sourceId) return s;
    }
    return null;
  }

  /// 快照过期（或从未探过）时重探；否则直接返回。
  Future<void> ensureFresh() {
    final DateTime? at = _refreshedAt;
    if (at != null && _now().difference(at) < staleAfter) {
      return Future<void>.value();
    }
    return refresh();
  }

  /// 强制重探全部对端。并发调用合并成一次。
  Future<void> refresh() {
    final Future<void>? running = _inFlight;
    if (running != null) return running;
    final Future<void> job = _refresh();
    _inFlight = job;
    return job.whenComplete(() {
      if (identical(_inFlight, job)) _inFlight = null;
    });
  }

  Future<void> _refresh() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _interconnectEnabled = await _syncRepository.isInterconnectEnabled();
      _peers = _interconnectEnabled
          ? await _transport.probe()
          : const <InterconnectMangaSourcePeer>[];
      _refreshedAt = _now();
    } catch (error) {
      _error = error;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void _onInterconnectToggled() {
    // 真值在 preferences 里；广播不带载荷，重读 + 重探（关掉 → 清空快照）。
    _refreshedAt = null;
    unawaited(refresh());
  }

  @override
  void dispose() {
    SyncRepository.interconnectEnabledRevision.removeListener(
      _onInterconnectToggled,
    );
    _prefs.removeListener(notifyListeners);
    super.dispose();
  }
}
