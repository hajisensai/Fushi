/// 歌曲收藏 = 在线平台自己的「喜欢」（用户 2026-10-29 拍板：
/// 「歌曲收藏是对应在线媒体的」）。不做本地收藏表：宿主只在内存里缓存各插件账号的喜欢
/// 集合（首次被问到时懒加载、登录 / 退出 / 装卸插件后重拉），喜欢 / 取消喜欢直接调插件的
/// `like` 能力（docs/specs/2026-10-28-music-plugins.md §4）。本地曲目没有平台账号，不能收藏。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';

/// 收藏要用到的插件操作（生产实现 [MusicPluginManagerLikeHost]；测试注入替身）。
abstract interface class MusicPluginLikeHost {
  /// 当前可用（已装、启用、校验通过）且声明了 `like` 能力的插件。
  Future<List<MusicPluginManifest>> likeCapablePlugins();

  /// 该插件账号的喜欢集合；未登录返回 null。
  Future<MusicPluginLikes?> likes(String pluginId);

  /// 喜欢 / 取消喜欢一首；失败抛错（消息给用户看）。
  Future<void> setLiked(String pluginId, String trackId, {required bool liked});
}

/// 包 [MusicPluginManager] 的生产实现（管理器按需懒建，所以这里也只存取法）。
class MusicPluginManagerLikeHost implements MusicPluginLikeHost {
  const MusicPluginManagerLikeHost(this._manager);

  final MusicPluginManager Function() _manager;

  @override
  Future<List<MusicPluginManifest>> likeCapablePlugins() async =>
      <MusicPluginManifest>[
        for (final InstalledMusicPlugin p in await _manager().list())
          if (p.usable && p.info!.manifest.can(MusicPluginCapability.like))
            p.info!.manifest,
      ];

  @override
  Future<MusicPluginLikes?> likes(String pluginId) =>
      _manager().source(pluginId).likes();

  @override
  Future<void> setLiked(
    String pluginId,
    String trackId, {
    required bool liked,
  }) => _manager().source(pluginId).setLiked(trackId, liked: liked);
}

/// 收藏需要先登录该插件的平台账号（UI 据此引导去「插件音源」登录）。
final class MusicFavoriteLoginRequired implements Exception {
  const MusicFavoriteLoginRequired(this.pluginId);

  final String pluginId;

  @override
  String toString() => 'MusicFavoriteLoginRequired($pluginId)';
}

/// 这一首不能收藏（本地 / 服务器曲目，或插件没声明 `like`）。
final class MusicFavoriteUnsupported implements Exception {
  const MusicFavoriteUnsupported();

  @override
  String toString() => 'MusicFavoriteUnsupported';
}

/// 一个插件账号的喜欢状态（推荐页「我喜欢的音乐」入口读它）。
@immutable
class MusicPluginLikeState {
  const MusicPluginLikeState({
    required this.manifest,
    required this.loggedIn,
    this.playlist,
  });

  final MusicPluginManifest manifest;

  /// false = 未登录（或还没拉到）。
  final bool loggedIn;

  /// 平台的「我喜欢的音乐」歌单；平台没有对应歌单时为 null。
  final MusicPluginPlaylist? playlist;
}

/// 各插件账号喜欢集合的内存缓存 + 喜欢 / 取消喜欢。变化时 [notifyListeners]。
class MusicPluginFavorites extends ChangeNotifier {
  MusicPluginFavorites(this._host, {void Function(Object, StackTrace)? onError})
    : _onError = onError;

  final MusicPluginLikeHost _host;
  final void Function(Object, StackTrace)? _onError;

  /// 声明了 `like` 的可用插件（id → 清单）；首次加载前为空。
  Map<String, MusicPluginManifest> _plugins = <String, MusicPluginManifest>{};

  /// 插件 id → 喜欢的曲目 id；缺键 = 未登录 / 没拉到。
  final Map<String, Set<String>> _liked = <String, Set<String>>{};
  final Map<String, MusicPluginPlaylist?> _playlists =
      <String, MusicPluginPlaylist?>{};

  /// 每个插件的缓存版本：喜欢 / 取消喜欢后 +1，在途的旧拉取结果不再覆盖。
  final Map<String, int> _versions = <String, int>{};

  Future<void>? _loading;
  bool _loaded = false;
  bool _disposed = false;

  /// 是否已至少加载过一次（测试与 UI 判「还在拉」用）。
  bool get loaded => _loaded;

  /// 首次被问到时在后台加载（不阻塞同步读）。
  void _ensureLoaded() {
    if (_loaded || _loading != null) return;
    unawaited(refresh());
  }

  /// 插件曲目才有平台身份；其它返回 null。
  static ({String pluginId, String trackId})? _refOf(MusicPlayItem item) =>
      parseMusicPluginTrackPath(item.path);

  /// 这一首能不能收藏：插件曲目，且该插件可用并声明了 `like`。
  bool canFavorite(MusicPlayItem item) {
    _ensureLoaded();
    final ({String pluginId, String trackId})? ref = _refOf(item);
    return ref != null && _plugins.containsKey(ref.pluginId);
  }

  /// 这一首是否在平台上已喜欢（同步读内存缓存；未加载 / 未登录为 false）。
  bool isFavorite(MusicPlayItem item) {
    _ensureLoaded();
    final ({String pluginId, String trackId})? ref = _refOf(item);
    if (ref == null) return false;
    return _liked[ref.pluginId]?.contains(ref.trackId) ?? false;
  }

  /// 推荐页「我喜欢的音乐」入口：每个声明了 `like` 的插件一项。
  List<MusicPluginLikeState> get states {
    _ensureLoaded();
    return <MusicPluginLikeState>[
      for (final MusicPluginManifest m in _plugins.values)
        MusicPluginLikeState(
          manifest: m,
          loggedIn: _liked.containsKey(m.id),
          playlist: _playlists[m.id],
        ),
    ];
  }

  /// 重拉插件列表与全部插件的喜欢集合（装卸 / 启停插件后调）。并发调用合并成一次。
  Future<void> refresh() => _loading ??= _refreshAll().whenComplete(() {
    _loading = null;
  });

  Future<void> _refreshAll() async {
    List<MusicPluginManifest> plugins;
    try {
      plugins = await _host.likeCapablePlugins();
    } catch (e, st) {
      _onError?.call(e, st);
      plugins = const <MusicPluginManifest>[];
    }
    if (_disposed) return;
    _plugins = <String, MusicPluginManifest>{
      for (final MusicPluginManifest m in plugins) m.id: m,
    };
    _liked.removeWhere((String id, _) => !_plugins.containsKey(id));
    _playlists.removeWhere((String id, _) => !_plugins.containsKey(id));
    _loaded = true;
    notifyListeners();
    await Future.wait(<Future<void>>[
      for (final String id in _plugins.keys) refreshPlugin(id),
    ]);
  }

  /// 重拉一个插件账号的喜欢集合（登录 / 退出后调）。拉取失败保留旧缓存。
  Future<void> refreshPlugin(String pluginId) async {
    if (!_loaded) return refresh();
    if (!_plugins.containsKey(pluginId)) return;
    final int version = _versions[pluginId] ?? 0;
    MusicPluginLikes? r;
    try {
      r = await _host.likes(pluginId);
    } catch (e, st) {
      _onError?.call(e, st);
      return;
    }
    if (_disposed || (_versions[pluginId] ?? 0) != version) return;
    if (r == null) {
      _liked.remove(pluginId);
      _playlists.remove(pluginId);
    } else {
      _liked[pluginId] = <String>{...r.trackIds};
      _playlists[pluginId] = r.playlist;
    }
    notifyListeners();
  }

  /// 喜欢 ↔ 取消喜欢。成功后更新缓存并通知；失败原样抛出（UI 提示）：不能收藏抛
  /// [MusicFavoriteUnsupported]，未登录抛 [MusicFavoriteLoginRequired]，插件报错抛
  /// [MusicPluginException]。
  Future<void> toggle(MusicPlayItem item) async {
    if (!_loaded) await refresh();
    final ({String pluginId, String trackId})? ref = _refOf(item);
    if (ref == null || !_plugins.containsKey(ref.pluginId)) {
      throw const MusicFavoriteUnsupported();
    }
    // 没拉到集合：可能是刚登录还没拉，先重拉一次再判未登录。
    if (!_liked.containsKey(ref.pluginId)) await refreshPlugin(ref.pluginId);
    final Set<String>? liked = _liked[ref.pluginId];
    if (liked == null) throw MusicFavoriteLoginRequired(ref.pluginId);
    final bool next = !liked.contains(ref.trackId);
    await _host.setLiked(ref.pluginId, ref.trackId, liked: next);
    if (_disposed) return;
    _versions[ref.pluginId] = (_versions[ref.pluginId] ?? 0) + 1;
    final Set<String> now = _liked[ref.pluginId] ?? <String>{...liked};
    if (next) {
      now.add(ref.trackId);
    } else {
      now.remove(ref.trackId);
    }
    _liked[ref.pluginId] = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
