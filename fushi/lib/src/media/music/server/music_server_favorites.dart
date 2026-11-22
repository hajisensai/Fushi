/// 服务器收藏的本机状态（Jellyfin `UserData.IsFavorite` / Subsonic `starred`）。
///
/// 服务器条目是列表里读到的不可变快照（[MusicServerTrack.favorite] 等），切换收藏后不重新
/// 拉整页：这里记下本进程里切换过的条目，各处（曲目行的心形、菜单、专辑页按钮、收藏页）
/// 都按「切换过的值 ?? 服务器报的值」显示，并随 [ChangeNotifier] 一起刷新。真相仍在服务器，
/// 这张表不落库，重进页面重新读服务器。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

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
  }) => _overrides[_key(browser.serverId, kind, id)] ?? reported ?? false;

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
