import 'dart:math';

/// 视频合集（多集播放列表）一集播完后「下一集」怎么选（拍板台 QHbRRctQdW）。
///
/// 只决定**自动连播**的目标集；是否连播仍归「自动连播下一集」开关管，单集循环归
/// mpv 的「单文件循环」（`loop-file=inf` 时这一集永远播不完，自然不会走到选集）。
/// 三者合起来就是音乐播放器那套「顺序 / 随机 / 单曲循环」。手动上 / 下一集与剧集
/// 面板选集仍按合集顺序走，不受本项影响。
enum VideoPlaylistOrder {
  /// 按合集顺序进下一集，末集播完停下（历史行为）。
  sequential('sequential'),

  /// 在合集里随机挑一集：一轮之内不重复，整轮都播过后开新一轮，不会停。
  shuffle('shuffle');

  const VideoPlaylistOrder(this.storageValue);

  /// 落 `video_playlist_order` 偏好的存储值（冻结，不随枚举名改）。
  final String storageValue;

  static const VideoPlaylistOrder fallback = sequential;

  static VideoPlaylistOrder fromStorage(String value) {
    for (final VideoPlaylistOrder order in VideoPlaylistOrder.values) {
      if (order.storageValue == value) return order;
    }
    return fallback;
  }
}

/// 顺序模式的下一集：有下一集返回 `current + 1`，单集 / 末集 / 越界返回 null。
int? sequentialNextEpisode({required int count, required int current}) {
  if (count <= 1 || current < 0 || current >= count - 1) return null;
  return current + 1;
}

/// 随机模式的下一集（纯函数）：从「本轮还没播过、且不是当前集」的集里均匀挑一个；
/// 本轮都播过了就从除当前集外的全部集里挑（开新一轮）。[count] ≤ 1 或 [current]
/// 越界返回 null。[played] 是本轮已播集的下标。
int? pickShuffleEpisode({
  required int count,
  required int current,
  required Set<int> played,
  required Random random,
}) {
  if (count <= 1 || current < 0 || current >= count) return null;
  final List<int> fresh = <int>[
    for (int i = 0; i < count; i++)
      if (i != current && !played.contains(i)) i,
  ];
  final List<int> pool = fresh.isNotEmpty
      ? fresh
      : <int>[
          for (int i = 0; i < count; i++)
            if (i != current) i,
        ];
  return pool[random.nextInt(pool.length)];
}

/// 随机连播的「本轮已播」记录，进程内、按播放列表分槽。
///
/// 本地换集是 `pushReplacement` 到新页（每集一个页面实例），页面字段活不过一次
/// 换集，所以轮次记录挂在进程级单例上；键是整份集清单的身份（[playlistKey]），
/// 集清单变了（增删集）就是另一个槽，旧槽的下标不会套到新清单上。不落盘：随机
/// 轮次是一次观看会话的概念，重启后从新一轮开始即可。
class VideoShuffleRounds {
  VideoShuffleRounds({Random? random}) : _random = random ?? Random();

  /// 播放页共用的单例。
  static final VideoShuffleRounds instance = VideoShuffleRounds();

  final Random _random;
  final Map<String, Set<int>> _playedByPlaylist = <String, Set<int>>{};

  /// 由每集稳定身份（本地集 bookUid、远端 / 站点集的路径或下标）拼出的槽键。
  static String playlistKey(List<String> episodeIds) =>
      episodeIds.join('\u0001');

  /// 记下 [current] 已播，并挑本轮的下一集。整轮播完时清空本槽重开（当前集
  /// 记为新一轮的第一集）。
  int? next({
    required String playlistKey,
    required int count,
    required int current,
  }) {
    if (count <= 1 || current < 0 || current >= count) return null;
    final Set<int> played = _playedByPlaylist.putIfAbsent(
      playlistKey,
      () => <int>{},
    )..removeWhere((int i) => i >= count);
    played.add(current);
    if (played.length >= count) {
      played
        ..clear()
        ..add(current);
    }
    return pickShuffleEpisode(
      count: count,
      current: current,
      played: played,
      random: _random,
    );
  }
}
