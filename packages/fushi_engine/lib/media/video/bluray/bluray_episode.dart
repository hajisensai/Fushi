// 「一条播放列表串着几集」的蓝光剧集盘：把一条 MPLS 按 PlayItem 切成各集。
//
// 只有「全部播放」、没有逐集播放列表的剧集盘（《魔女の旅々》BD 每卷一条 6 × 24 分钟
// 的播放列表）整条入库就是「一卷一个条目」——没有分集、没有逐集进度、刮削绑不到集。
// 这里给每一集一个**虚拟的分集路径**当库成员身份：
//
//     <盘根>/BDMV/PLAYLIST/<播放列表号>.p<锚点 PlayItem 序号>.mpls
//     例：…/Disc 1/BDMV/PLAYLIST/00001.p03.mpls
//
// 它仍以 `.mpls` 结尾、仍在 `PLAYLIST/` 下，所以全仓「这是一条蓝光标题」的判据
// （`isBlurayPlaylistPath` / `blurayDiscRootForPlaylistPath` / 互联按文件名认原盘成员
// / 删除不给「删本地文件」/ 制卡强制重编码……）原样成立；文件名去扩展名
// （`00001.p03`）就是派生播放列表的 id，与真实标题 `00001` 同一形状。
//
// 代价是它**不是真实文件**：背后真实存在的是 `<播放列表号>.mpls`
// （[blurayEpisodeBackingPlaylistPath]）。「这一条还在不在」经
// `discMemberBackingFilePath` 换成它再判；要读播放列表内容一律走
// `readBlurayMemberPlaylist`（`bluray_source.dart`），不许对成员路径裸读文件。
//
// 身份只编码「哪条播放列表的第几个 PlayItem 起头」，不编码累计集号：集号取决于同一
// 发布里还有哪几张盘，盘增减时身份不能跟着变。
//
// 设计见 `docs/specs/2026-11-15-bluray-playitem-episodes.md`。

import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';

/// 一段 PlayItem 至少这么长才可能是「一集」（[blurayPlaylistLooksEpisodic] 的口径）。
const Duration kBlurayEpisodeLikeMinimumDuration = Duration(minutes: 10);

/// 真的把播放列表切成集的下限：每个锚点至少这么长。
///
/// 比 [kBlurayEpisodeLikeMinimumDuration] 严：A/B 两半各 11～12 分钟的单集 OVA
/// 同样是「两段时长相近的长片段」，切开就是两条半集。18 分钟把它与常规 TV 集
/// （23～25 分钟）分开；12～15 分钟的短篇番剧因此不切，照旧整条入库。
const Duration kBlurayEpisodeSplitMinimumDuration = Duration(minutes: 18);

/// 恰好两个锚点时每段的上限：中场休息 / 换层切成两段的电影（各 50 分钟以上）不是
/// 两集。三段及以上不设上限（一小时一集的剧集盘照切）。
const Duration kBlurayTwoEpisodeMaximumDuration = Duration(minutes: 40);

/// 「这一段开头有章节点」的容差：每一集的开头都是一个章节点，而被无缝分支 / 换层
/// 切成几段的电影在段的接缝处通常没有。
const Duration kBlurayEpisodeStartChapterTolerance = Duration(seconds: 2);

int _ticks(Duration duration) =>
    duration.inMilliseconds * kBlurayTimeScale ~/ 1000;

/// [playlist] 是不是「一条播放列表串着几集」的剧集形状：至少两段各 ≥ 10 分钟、
/// 彼此时长相近（最长不超过最短的 1.2 倍）的片段，且它们占总时长的四分之三以上。
///
/// 只有「全部播放」、没有逐集播放列表的剧集盘入库后是单标题，光看「单标题」会被
/// 当成电影去识别。
bool blurayPlaylistLooksEpisodic(BlurayPlaylist playlist) {
  final int minimumEpisodeTicks = _ticks(kBlurayEpisodeLikeMinimumDuration);
  final List<int> episodeLike = <int>[
    for (final BlurayClipRef clip in playlist.clips)
      if (clip.durationTicks >= minimumEpisodeTicks) clip.durationTicks,
  ]..sort();
  if (episodeLike.length < 2) return false;
  if (episodeLike.last > episodeLike.first * 1.2) return false;
  final int sum = episodeLike.fold<int>(0, (int a, int b) => a + b);
  return sum * 4 >= playlist.durationTicks * 3;
}

/// 一集在播放列表里占的 PlayItem 区间（下标 0 起，两端都含）。
class BlurayEpisodeSpan {
  const BlurayEpisodeSpan({
    required this.firstItem,
    required this.lastItem,
    required this.anchorItem,
  });

  final int firstItem;
  final int lastItem;

  /// 这一集的正片那一段（≥ 10 分钟的 PlayItem）。分集身份按它编号。
  final int anchorItem;

  /// 分集路径里写的序号（1 起）。
  int get playItemNumber => anchorItem + 1;
}

/// 把 [playlist] 切成各集；不是剧集形状、或拿不准（见两个 `kBlurayEpisodeSplit*`
/// 常量）时返回空表——调用方照旧整条当一个标题。纯函数。
///
/// 每段 ≥ 10 分钟的 PlayItem 是一集的锚点；紧跟其后的短段（次回预告、提供画面）并入
/// 这一集，第一集之前的短段（厂标）并入第一集。
///
/// 拿不准就不切的几种情形：
///   * 有锚点开头没有章节点——几段等长的正片（被切成三段的电影）与几集的区别就在
///     这里。《魔女の旅々》实测各段的 `connection_condition` 都是 5（无缝），与分段
///     电影相同，所以不能拿它区分；
///   * 锚点之间夹着短段、且整条以短段开头以锚点结尾（`OP 集 OP 集 …`）——短段是
///     前一集的预告还是后一集的片头说不清。
///
/// 「这几段是不是已经各有一条逐集播放列表」要看整张盘，由
/// [blurayPlaylistSharesAnchorClips] 判，不在这里。
List<BlurayEpisodeSpan> splitBlurayPlaylistEpisodes(BlurayPlaylist playlist) {
  if (!blurayPlaylistLooksEpisodic(playlist)) {
    return const <BlurayEpisodeSpan>[];
  }
  final int likeTicks = _ticks(kBlurayEpisodeLikeMinimumDuration);
  final int splitTicks = _ticks(kBlurayEpisodeSplitMinimumDuration);
  final List<int> anchors = <int>[
    for (int i = 0; i < playlist.clips.length; i++)
      if (playlist.clips[i].durationTicks >= likeTicks) i,
  ];
  if (anchors.length < 2) return const <BlurayEpisodeSpan>[];
  for (final int anchor in anchors) {
    if (playlist.clips[anchor].durationTicks < splitTicks) {
      return const <BlurayEpisodeSpan>[];
    }
  }
  if (anchors.length == 2) {
    final int maximum = _ticks(kBlurayTwoEpisodeMaximumDuration);
    for (final int anchor in anchors) {
      if (playlist.clips[anchor].durationTicks > maximum) {
        return const <BlurayEpisodeSpan>[];
      }
    }
  }
  final bool shortBetweenAnchors =
      anchors.last - anchors.first >= anchors.length;
  if (shortBetweenAnchors &&
      anchors.first > 0 &&
      anchors.last == playlist.clips.length - 1) {
    return const <BlurayEpisodeSpan>[];
  }
  final int tolerance = _ticks(kBlurayEpisodeStartChapterTolerance);
  int itemStart = 0;
  final Set<int> chapterAtStart = <int>{};
  for (int i = 0; i < playlist.clips.length; i++) {
    for (final BlurayChapter chapter in playlist.chapters) {
      if (chapter.playItemIndex == i &&
          chapter.startTicks - itemStart <= tolerance) {
        chapterAtStart.add(i);
        break;
      }
    }
    itemStart += playlist.clips[i].durationTicks;
  }
  if (!anchors.every(chapterAtStart.contains)) {
    return const <BlurayEpisodeSpan>[];
  }
  return <BlurayEpisodeSpan>[
    for (int i = 0; i < anchors.length; i++)
      BlurayEpisodeSpan(
        firstItem: i == 0 ? 0 : anchors[i],
        lastItem: i + 1 < anchors.length
            ? anchors[i + 1] - 1
            : playlist.clips.length - 1,
        anchorItem: anchors[i],
      ),
  ];
}

/// [playlist] 的各集正片段（≥ 10 分钟的片段）里，有没有哪一段也被 [others] 里别的
/// 播放列表引用。有 = 这张盘另有逐集播放列表（[playlist] 是漏网的「全部播放」），
/// 或它是同一批片段换个顺序的诱饵——都不该再切成集。
bool blurayPlaylistSharesAnchorClips(
  BlurayPlaylist playlist,
  Iterable<BlurayPlaylist> others,
) {
  final int likeTicks = _ticks(kBlurayEpisodeLikeMinimumDuration);
  final Set<String> anchors = <String>{
    for (final BlurayClipRef clip in playlist.clips)
      if (clip.durationTicks >= likeTicks) clip.clipId,
  };
  for (final BlurayPlaylist other in others) {
    if (identical(other, playlist) || other.id == playlist.id) continue;
    for (final BlurayClipRef clip in other.clips) {
      if (anchors.contains(clip.clipId)) return true;
    }
  }
  return false;
}

/// [span] 这一集在 [playlist] 时间轴上的起点（45 kHz tick）。
int blurayEpisodeStartTicks(BlurayPlaylist playlist, BlurayEpisodeSpan span) {
  int start = 0;
  for (int i = 0; i < span.firstItem; i++) {
    start += playlist.clips[i].durationTicks;
  }
  return start;
}

/// 分集的派生播放列表 id：`00001` 的第 3 个 PlayItem → `00001.p03`。
String blurayEpisodePlaylistId(String playlistId, int playItemNumber) =>
    '$playlistId.p${playItemNumber.toString().padLeft(2, '0')}';

/// [span] 这一集的派生播放列表：片段取区间，章节只留落在区间内的并平移到本集零点，
/// 流表照抄。它的 `id`（`00001.p03`）+ `.mpls` 就是分集路径的文件名。
BlurayPlaylist blurayEpisodePlaylist(
  BlurayPlaylist playlist,
  BlurayEpisodeSpan span,
) {
  final int offset = blurayEpisodeStartTicks(playlist, span);
  return BlurayPlaylist(
    id: blurayEpisodePlaylistId(playlist.id, span.playItemNumber),
    clips: List<BlurayClipRef>.unmodifiable(
      playlist.clips.sublist(span.firstItem, span.lastItem + 1),
    ),
    chapters: List<BlurayChapter>.unmodifiable(<BlurayChapter>[
      for (final BlurayChapter chapter in playlist.chapters)
        if (chapter.playItemIndex >= span.firstItem &&
            chapter.playItemIndex <= span.lastItem)
          BlurayChapter(
            startTicks: chapter.startTicks - offset,
            playItemIndex: chapter.playItemIndex - span.firstItem,
          ),
    ]),
    streams: playlist.streams,
    playbackType: playlist.playbackType,
  );
}

/// [playlist] 切出的各集的派生播放列表，按集序；不切时为空表。
List<BlurayPlaylist> blurayEpisodePlaylists(
  BlurayPlaylist playlist,
) => <BlurayPlaylist>[
  for (final BlurayEpisodeSpan span in splitBlurayPlaylistEpisodes(playlist))
    blurayEpisodePlaylist(playlist, span),
];

/// [playlist] 里以第 [playItemNumber]（1 起）个 PlayItem 为锚点的那一集；这条播放
/// 列表不切集、或那个 PlayItem 不是锚点时返回 null。
BlurayPlaylist? blurayEpisodeForPlayItem(
  BlurayPlaylist playlist,
  int playItemNumber,
) {
  for (final BlurayEpisodeSpan span in splitBlurayPlaylistEpisodes(playlist)) {
    if (span.playItemNumber == playItemNumber) {
      return blurayEpisodePlaylist(playlist, span);
    }
  }
  return null;
}

/// 分集文件名（去扩展名）：五位播放列表号 + `.p` + 两到三位 PlayItem 序号。
final RegExp _episodeName = RegExp(r'^(\d{5})\.p(\d{2,3})$');

/// 分集路径拆出来的两半。
typedef BlurayEpisodeRef = ({
  /// 背后真实存在的那条播放列表的路径（`…/PLAYLIST/00001.mpls`）。
  String playlistPath,

  /// 锚点 PlayItem 序号（1 起）。
  int playItemNumber,
});

/// 把分集路径拆成「背后的播放列表 + PlayItem 序号」；不是分集路径返回 null。
///
/// 只做文本切分，两种分隔符都认（库里的路径可能来自别的平台），不碰文件系统。
BlurayEpisodeRef? parseBlurayEpisodePath(String path) {
  final int separator = path.lastIndexOf(RegExp(r'[\\/]'));
  final String name = separator >= 0 ? path.substring(separator + 1) : path;
  if (!name.toLowerCase().endsWith('.mpls')) return null;
  final Match? match = _episodeName.firstMatch(
    name.substring(0, name.length - 5),
  );
  if (match == null) return null;
  final int number = int.parse(match.group(2)!);
  if (number < 1) return null;
  return (
    playlistPath:
        '${path.substring(0, separator + 1)}${match.group(1)}'
        '${name.substring(name.length - 5)}',
    playItemNumber: number,
  );
}

/// [path] 是不是一条蓝光分集的虚拟成员路径。
bool isBlurayEpisodePath(String path) => parseBlurayEpisodePath(path) != null;

/// 分集路径背后真实存在的 `.mpls`；不是分集路径时原样返回 [path]。
String blurayEpisodeBackingPlaylistPath(String path) =>
    parseBlurayEpisodePath(path)?.playlistPath ?? path;
