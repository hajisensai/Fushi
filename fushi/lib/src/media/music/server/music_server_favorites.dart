/// 服务器收藏的本机状态（Jellyfin `UserData.IsFavorite` / Subsonic `starred`）。
///
/// 服务器条目是列表里读到的不可变快照（[MusicServerTrack.favorite] 等），切换收藏后不重新
/// 拉整页：这里记下本进程里切换过的条目，各处（曲目行的心形、菜单、专辑页按钮、收藏页）
/// 都按「切换过的值 ?? 服务器报的值」显示，并随 [ChangeNotifier] 一起刷新。真相仍在服务器，
/// 这张表不落库，重进页面重新读服务器。
///
/// 曲目的收藏在服务器连不上时不还原、不报错：切换记进离线补发队列（[MusicServerOfflineQueue]，
/// 同一首只留最后一次），心形保持切换后的值，服务器连得通时补发。专辑 / 艺人的收藏只能在
/// 浏览服务器时点（那时服务器本就在线），失败照旧还原并抛。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/server/music_server_offline_queue.dart';
import 'package:fushi/src/media/music/server/music_server_track_ref.dart'
    show MusicServerResolvedTrack;

class MusicServerFavoriteStore extends ChangeNotifier {
  MusicServerFavoriteStore({MusicServerOfflineQueue? offline})
    : _offline = offline;

  /// 离线补发队列（缺省进程级 [MusicServerOfflineQueue.instance]；没接库时不入队）。
  final MusicServerOfflineQueue? _offline;
  MusicServerOfflineQueue get offline =>
      _offline ?? MusicServerOfflineQueue.instance;

  /// app 内共享的一份（页面与菜单不必层层传）。
  static final MusicServerFavoriteStore instance = MusicServerFavoriteStore();

  final Map<String, bool> _overrides = <String, bool>{};

  /// 服务器确认过的切换（请求成功的最后一次）：失败时还原到这里，没有 = 还原到服务器报的值。
  final Map<String, bool> _confirmed = <String, bool>{};

  /// 每个条目的切换代数：连点时只有最后一次请求有权还原（早先那次晚到的失败不能把后来
  /// 那次的乐观值抹掉）。
  final Map<String, int> _generations = <String, int>{};

  static String _key(String serverId, MusicServerItemKind kind, String id) =>
      '$serverId\u0000${kind.name}\u0000$id';

  /// 此刻该显示的收藏状态：本进程切换过的优先，其次服务器报的，都没有为 false。
  bool isFavorite(
    MusicServerBrowser browser,
    MusicServerItemKind kind,
    String id, {
    bool? reported,
  }) => isFavoriteOn(browser.serverId, kind, id, reported: reported);

  /// 同 [isFavorite]，按服务器配置身份读（播放项只带 [MusicServerTrackRef]，没有客户端）。
  bool isFavoriteOn(
    String serverId,
    MusicServerItemKind kind,
    String id, {
    bool? reported,
  }) => _overrides[_key(serverId, kind, id)] ?? reported ?? false;

  /// 服务器确认过 [favorite]（离线补发成功）：之后失败还原到这个值。
  void confirm(
    String serverId,
    MusicServerItemKind kind,
    String id,
    bool favorite,
  ) {
    _confirmed[_key(serverId, kind, id)] = favorite;
  }

  /// 服务器不在 / 这台设备上没配那台服务器时的曲目收藏：只改本机显示并记进离线队列。
  Future<void> setTrackFavoriteOffline({
    required MusicServerKind serverKind,
    required String serverId,
    required String trackId,
    required bool favorite,
  }) async {
    final String key = _key(serverId, MusicServerItemKind.track, trackId);
    _generations[key] = (_generations[key] ?? 0) + 1;
    _overrides[key] = favorite;
    notifyListeners();
    await offline.enqueueFavorite(
      kind: serverKind,
      serverId: serverId,
      itemId: trackId,
      favorite: favorite,
    );
  }

  /// 设成 [favorite]：先改本机显示，再请服务器；失败还原到服务器最后确认的状态并抛（调用方
  /// 提示）——只有这个条目最后一次切换的失败才还原。曲目在服务器连不上时例外：不还原、不抛，
  /// 记进离线队列。[browser] 不能收藏时抛 [UnsupportedError]。
  Future<void> setFavorite(
    MusicServerBrowser browser,
    MusicServerItemKind kind,
    String id, {
    required bool favorite,
  }) async {
    if (browser is! MusicServerFavoriteEditing) {
      throw UnsupportedError('${browser.kind.wire} cannot favorite items');
    }
    final String key = _key(browser.serverId, kind, id);
    final int generation = (_generations[key] ?? 0) + 1;
    _generations[key] = generation;
    _overrides[key] = favorite;
    notifyListeners();
    try {
      await (browser as MusicServerFavoriteEditing).setFavorite(
        kind,
        id,
        favorite: favorite,
      );
      _confirmed[key] = favorite;
      if (kind == MusicServerItemKind.track) {
        unawaited(
          offline.rememberFavorite(
            kind: browser.kind,
            serverId: browser.serverId,
            itemId: id,
            favorite: favorite,
          ),
        );
      }
      // 那台服务器此刻连得通：顺带把积压的离线条目发出去。
      unawaited(offline.flushServer(browser));
    } on Object catch (e) {
      if (kind == MusicServerItemKind.track &&
          offline.attached &&
          musicServerKindQueueable(browser.kind) &&
          musicServerUnreachable(e)) {
        // 连不上：保持切换后的值，记进离线队列（之后又切换过的由那次自己入队）。
        if (_generations[key] == generation) {
          await offline.enqueueFavorite(
            kind: browser.kind,
            serverId: browser.serverId,
            itemId: id,
            favorite: favorite,
          );
        }
        return;
      }
      // 之后又切换过：显示归那次（它自己成功 / 失败时再定），这里不动。
      if (_generations[key] == generation) {
        final bool? confirmed = _confirmed[key];
        if (confirmed == null) {
          _overrides.remove(key);
        } else {
          _overrides[key] = confirmed;
        }
        notifyListeners();
      }
      rethrow;
    }
  }
}

/// 「正在播放」里服务器曲目（Jellyfin / Subsonic，带 [MusicPlayItem.serverTrack] 的项）的收藏：
/// 播放项不带列表里读到的收藏状态，第一次显示时问一次服务器
/// （[MusicServerFavoriteEditing.trackFavorite]），切换走 [MusicServerFavoriteStore]（与曲目行、
/// 菜单、收藏页同一份本机状态）。
///
/// 显示的优先级：本进程切换过的 > 待送达的离线切换 > 服务器这次报的 > 本机记下的最后已知
/// 状态（v174 `music_server_track_states`）。服务器连不上、或这台设备上的服务器配置删了（离线
/// 副本照样能放）时心形按最后已知状态显示，切换记进离线补发队列、心形保持切换后的值。
class MusicServerTrackFavorites extends ChangeNotifier {
  MusicServerTrackFavorites({
    required Future<MusicServerResolvedTrack?> Function(MusicPlayItem item)
    resolve,
    MusicServerFavoriteStore? store,
  }) : _resolve = resolve,
       _store = store ?? MusicServerFavoriteStore.instance {
    _store.addListener(notifyListeners);
    _store.offline.addListener(notifyListeners);
  }

  final Future<MusicServerResolvedTrack?> Function(MusicPlayItem item) _resolve;
  final MusicServerFavoriteStore _store;

  /// uid → 服务器报的收藏状态（问过的）。
  final Map<String, bool> _reported = <String, bool>{};

  /// 正在问 / 问过但没问到（连不上、服务器没有这首）的 uid：不反复问。
  final Set<String> _asked = <String>{};

  /// uid → 本机记下的最后已知状态（第一次显示时读一次库）。
  final Map<String, bool> _lastKnown = <String, bool>{};

  /// 能不能收藏：Jellyfin / Subsonic 曲目（两家客户端都实现了 [MusicServerFavoriteEditing]），
  /// 不是试听片段。
  bool canFavorite(MusicPlayItem item) {
    final MusicServerTrackRef? ref = item.serverTrack;
    return ref != null &&
        !item.isPreview &&
        (ref.kind == MusicServerKind.jellyfin ||
            ref.kind == MusicServerKind.subsonic);
  }

  /// 此刻该显示的状态：本进程切换过的优先，其次服务器报的；还没问过就后台问一次。
  bool isFavorite(MusicPlayItem item) {
    final MusicServerTrackRef? ref = item.serverTrack;
    if (ref == null) return false;
    final bool? reported = _reported[item.trackUid];
    if (reported == null && _asked.add(item.trackUid)) {
      unawaited(_ask(item));
    }
    return _store.isFavoriteOn(
      ref.serverId,
      MusicServerItemKind.track,
      ref.trackId,
      reported:
          _store.offline.pendingFavorite(item.trackUid) ??
          reported ??
          _lastKnown[item.trackUid],
    );
  }

  Future<void> _ask(MusicPlayItem item) async {
    try {
      final bool? known = await _store.offline.lastKnownFavorite(item.trackUid);
      if (known != null && _reported[item.trackUid] == null) {
        _lastKnown[item.trackUid] = known;
        notifyListeners();
      }
    } on Object catch (e) {
      debugPrint(
        '[music-favorite] last known state unreadable: ${e.runtimeType}',
      );
    }
    try {
      final MusicServerResolvedTrack? r = await _resolve(item);
      final MusicServerBrowser? b = r?.browser;
      if (r == null || b is! MusicServerFavoriteEditing) return;
      final bool? fav = await (b as MusicServerFavoriteEditing).trackFavorite(
        r.trackId,
      );
      if (fav == null) return;
      _reported[item.trackUid] = fav;
      notifyListeners();
      if (_lastKnown[item.trackUid] != fav) {
        _lastKnown[item.trackUid] = fav;
        await _store.offline.rememberFavorite(
          kind: r.browser.kind,
          serverId: r.browser.serverId,
          itemId: r.trackId,
          favorite: fav,
        );
      }
    } on Object catch (e) {
      debugPrint('[music-favorite] server state unavailable: ${e.runtimeType}');
    }
  }

  /// 收藏 ↔ 取消收藏。这台设备上没配那台服务器（离线副本照样能放）时记进离线队列，服务器
  /// 重新配上后补发；服务器连不上时同样入队（[MusicServerFavoriteStore.setFavorite]）。服务器
  /// 报别的错照抛（本机显示已还原）；服务器不能收藏时抛 [UnsupportedError]。
  Future<void> toggle(MusicPlayItem item) async {
    final bool next = !isFavorite(item);
    final MusicServerResolvedTrack? r = await _resolve(item);
    if (r == null) {
      final MusicServerTrackRef? ref = item.serverTrack;
      if (ref == null ||
          !musicServerKindQueueable(ref.kind) ||
          !_store.offline.attached) {
        throw UnsupportedError('music server is not configured on this device');
      }
      await _store.setTrackFavoriteOffline(
        serverKind: ref.kind,
        serverId: ref.serverId,
        trackId: ref.trackId,
        favorite: next,
      );
      return;
    }
    await _store.setFavorite(
      r.browser,
      MusicServerItemKind.track,
      r.trackId,
      favorite: next,
    );
  }

  @override
  void dispose() {
    _store.removeListener(notifyListeners);
    _store.offline.removeListener(notifyListeners);
    super.dispose();
  }
}
