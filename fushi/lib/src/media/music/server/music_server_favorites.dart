/// 服务器收藏的本机状态（Jellyfin `UserData.IsFavorite` / Subsonic `starred`）。
///
/// 服务器条目是列表里读到的不可变快照（[MusicServerTrack.favorite] 等），切换收藏后不重新
/// 拉整页：这里记下本进程里切换过的条目，各处（曲目行的心形、菜单、专辑页按钮、收藏页）
/// 都按「切换过的值 ?? 服务器报的值」显示，并随 [ChangeNotifier] 一起刷新。真相仍在服务器，
/// 这张表不落库，重进页面重新读服务器。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/server/music_server_track_ref.dart'
    show MusicServerResolvedTrack;

class MusicServerFavoriteStore extends ChangeNotifier {
  MusicServerFavoriteStore();

  /// app 内共享的一份（页面与菜单不必层层传）。
  static final MusicServerFavoriteStore instance = MusicServerFavoriteStore();

  final Map<String, bool> _overrides = <String, bool>{};

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

  /// 设成 [favorite]：先改本机显示，再请服务器；失败还原并抛（调用方提示）。[browser] 不能
  /// 收藏时抛 [UnsupportedError]。
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
    final bool? before = _overrides[key];
    _overrides[key] = favorite;
    notifyListeners();
    try {
      await (browser as MusicServerFavoriteEditing).setFavorite(
        kind,
        id,
        favorite: favorite,
      );
    } on Object {
      if (before == null) {
        _overrides.remove(key);
      } else {
        _overrides[key] = before;
      }
      notifyListeners();
      rethrow;
    }
  }
}

/// 「正在播放」里服务器曲目（Jellyfin / Subsonic，带 [MusicPlayItem.serverTrack] 的项）的收藏：
/// 播放项不带列表里读到的收藏状态，第一次显示时问一次服务器
/// （[MusicServerFavoriteEditing.trackFavorite]），切换走 [MusicServerFavoriteStore]（与曲目行、
/// 菜单、收藏页同一份本机状态）。服务器连不上时按未收藏显示，切换照常请求、失败抛给 UI 提示。
class MusicServerTrackFavorites extends ChangeNotifier {
  MusicServerTrackFavorites({
    required Future<MusicServerResolvedTrack?> Function(MusicPlayItem item)
    resolve,
    MusicServerFavoriteStore? store,
  }) : _resolve = resolve,
       _store = store ?? MusicServerFavoriteStore.instance {
    _store.addListener(notifyListeners);
  }

  final Future<MusicServerResolvedTrack?> Function(MusicPlayItem item) _resolve;
  final MusicServerFavoriteStore _store;

  /// uid → 服务器报的收藏状态（问过的）。
  final Map<String, bool> _reported = <String, bool>{};

  /// 正在问 / 问过但没问到（连不上、服务器没有这首）的 uid：不反复问。
  final Set<String> _asked = <String>{};

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
      reported: reported,
    );
  }

  Future<void> _ask(MusicPlayItem item) async {
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
    } on Object catch (e) {
      debugPrint('[music-favorite] server state unavailable: ${e.runtimeType}');
    }
  }

  /// 收藏 ↔ 取消收藏。这台设备上没配那台服务器 / 服务器不能收藏时抛 [UnsupportedError]；
  /// 服务器报错照抛（本机显示已还原）。
  Future<void> toggle(MusicPlayItem item) async {
    final MusicServerResolvedTrack? r = await _resolve(item);
    if (r == null) {
      throw UnsupportedError('music server is not configured on this device');
    }
    final bool next = !isFavorite(item);
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
    super.dispose();
  }
}
