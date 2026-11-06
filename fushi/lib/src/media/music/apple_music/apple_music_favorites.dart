/// Apple Music 曲目的「喜欢」（Apple Music 评分：喜欢 = 1、不喜欢 = -1）：播放器收藏按钮、
/// 曲目菜单共用的内存缓存 + 读写。与插件收藏（`MusicPluginFavorites`）并列挂在 `MusicSession`
/// 上，按曲目路径分流：`fushi-apple-music://song/<catalogId>` 的曲目归这里。
///
/// - 只在本平台能整曲播放且已连接账号时可用（评分要 Music-User-Token）。
/// - 评分按需取：第一次被问到某首时后台读一次，读到后通知；之后读缓存。
/// - 账号变了（断开 / 换账号 / 订阅变化）清缓存：评分属于账号。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show appleMusicSongIdFromPath;
import 'package:fushi_engine/media/music/apple_music/apple_music_personal_client.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';

class AppleMusicFavorites extends ChangeNotifier {
  AppleMusicFavorites({
    required bool Function() available,
    required AppleMusicPersonalClient Function() client,
    Listenable? accountChanges,
    void Function(Object, StackTrace)? onError,
  }) : _available = available,
       _client = client,
       _accountChanges = accountChanges,
       _onError = onError {
    _accountChanges?.addListener(_onAccountChanged);
  }

  final bool Function() _available;
  final AppleMusicPersonalClient Function() _client;
  final Listenable? _accountChanges;
  final void Function(Object, StackTrace)? _onError;

  /// catalog 曲目 id → 评分（null = 没评过）。缺键 = 还没读。
  final Map<String, AppleMusicRating?> _ratings = <String, AppleMusicRating?>{};

  /// 正在读评分的曲目（同一首并发问只读一次）。
  final Set<String> _loading = <String>{};

  /// 账号代次：账号变了 +1，在途的旧读取结果不再写进缓存。
  int _gen = 0;
  bool _available0 = false;
  bool _disposed = false;

  void _onAccountChanged() {
    final bool now = _available();
    if (now == _available0 && _ratings.isEmpty) return;
    _available0 = now;
    _gen++;
    _ratings.clear();
    _loading.clear();
    notifyListeners();
  }

  /// 这一首的 catalog id；不是 Apple Music 整曲回 null。
  static String? songIdOf(MusicPlayItem item) =>
      appleMusicSongIdFromPath(item.path);

  /// 这一首能不能收藏：Apple Music 整曲，且账号可用。
  bool canFavorite(MusicPlayItem item) =>
      songIdOf(item) != null && _available();

  /// 这一首是否已喜欢（同步读缓存；没读过时后台读，读到后通知）。
  bool isFavorite(MusicPlayItem item) {
    final String? id = songIdOf(item);
    if (id == null) return false;
    return ratingOf(id) == AppleMusicRating.love;
  }

  /// 一首 catalog 曲目的评分（同步读缓存；没读过时后台读）。
  AppleMusicRating? ratingOf(String songId) {
    if (!_ratings.containsKey(songId)) _load(songId);
    return _ratings[songId];
  }

  void _load(String songId) {
    if (!_available() || !_loading.add(songId)) return;
    final int gen = _gen;
    unawaited(
      _client()
          .rating(AppleMusicResourceType.song, songId)
          .then(
            (AppleMusicRating? r) {
              if (_disposed || gen != _gen) return;
              _ratings[songId] = r;
              notifyListeners();
            },
            onError: (Object e, StackTrace st) {
              _onError?.call(e, st);
            },
          )
          .whenComplete(() {
            if (gen == _gen) _loading.remove(songId);
          }),
    );
  }

  /// 喜欢 ↔ 取消喜欢。失败抛出（调用方提示）。
  Future<void> toggle(MusicPlayItem item) async {
    final String? id = songIdOf(item);
    if (id == null) throw StateError('not an Apple Music track: ${item.path}');
    await setRating(
      id,
      ratingOf(id) == AppleMusicRating.love ? null : AppleMusicRating.love,
    );
  }

  /// 设评分（null = 清掉）。成功后更新缓存并通知；失败抛出、缓存不变。
  Future<void> setRating(String songId, AppleMusicRating? rating) async {
    final int gen = _gen;
    await _client().setRating(AppleMusicResourceType.song, songId, rating);
    if (_disposed || gen != _gen) return;
    _ratings[songId] = rating;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _accountChanges?.removeListener(_onAccountChanged);
    super.dispose();
  }
}
