import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';

// 合集里一集**自己没选过字幕**时，沿用同合集兄弟集最近一次的字幕选择（BUG-5464）。
//
// 统一合集 Phase 3 起每集是独立的 `VideoBooks` 行，字幕选择（`subtitleSource`）只记在
// 做选择的那一集上；换集（`pushReplacement` 到下一集）和从库里直接打开另一集，都是
// 拿那一集自己的行去 `_loadSingle`，行里没有选择。这里把兄弟集的选择**按描述**翻译
// 到新集：内封轨按「语言 + 轨标题」，同目录 sidecar 按去掉视频主名后的「语言 + 格式」
// 后缀——不按序号原样照搬（两集的轨顺序可以不同），也不把住在别处的单集字幕档
// （下载 / 导入进 `<appDocs>/video_subtitles/` 的）搬到别的集上（BUG-165）。
//
// 全部是纯函数（不碰文件系统，不碰 Flutter），由视频页负责枚举与加载。

/// 兄弟集上的一次字幕选择：那一集的视频路径 + 它持久化的 `subtitleSource`。
typedef SiblingSubtitleChoice = ({String videoPath, String subtitleSource});

/// 从合集的各集行 [episodes] 里挑「最近一次的字幕选择」，跳过当前集 [currentBookUid]。
///
/// 判据是 `VideoBooks.lastPlayedAt`（schema v85，与 `lastPositionMs` 同一事务写入）：
/// 字幕选择只能在播放时做出，播放中进度周期落库、换集前也会先落一次，都会刷新这一列；
/// 所以「有选择的兄弟集里最近播放的那一集」就是最近一次做选择的地方。
///
/// 没有播放时刻的行不参与：从未播放过的集没有可比的时刻，库页批量指派字幕写进去的
/// 又是逐集各自的字幕档，本来也借不过来。同一时刻取 [episodes] 里靠前的那一集。
SiblingSubtitleChoice? pickLatestSiblingSubtitleChoice(
  Iterable<VideoBookRow> episodes, {
  required String currentBookUid,
}) {
  VideoBookRow? best;
  int bestPlayedAt = 0;
  for (final VideoBookRow row in episodes) {
    if (row.bookUid == currentBookUid) continue;
    final String? source = row.subtitleSource;
    if (source == null || source.isEmpty) continue;
    final int? playedAt = row.lastPlayedAt;
    if (playedAt == null) continue;
    if (best == null || playedAt > bestPlayedAt) {
      best = row;
      bestPlayedAt = playedAt;
    }
  }
  if (best == null) return null;
  return (videoPath: best.videoPath, subtitleSource: best.subtitleSource!);
}

/// 兄弟集的选择在新集上意味着什么（[inheritedSubtitleIntent] 的结果）。
sealed class InheritedSubtitleIntent {
  const InheritedSubtitleIntent();
}

/// 兄弟集显式关了字幕（[SubtitleSource.offSentinel]）：新集同样关着起播。
final class InheritSubtitleOff extends InheritedSubtitleIntent {
  const InheritSubtitleOff();
}

/// 兄弟集选的是内封轨：它在兄弟集里是 [previousVideoPath] 的第 [streamIndex] 条字幕流。
/// 序号只用来在兄弟集里读出这条轨的描述，新集里按描述找（[matchEmbeddedSubtitleTrack]）。
final class InheritEmbeddedSubtitle extends InheritedSubtitleIntent {
  const InheritEmbeddedSubtitle({
    required this.previousVideoPath,
    required this.streamIndex,
  });

  final String previousVideoPath;
  final int streamIndex;
}

/// 兄弟集选的是它自己的同目录同名 sidecar；[suffix] 是去掉兄弟集视频主名后剩下的
/// 尾巴（小写，如 `.ja.srt` / `.ass` / `.chs.ass`）。
final class InheritSidecarSubtitle extends InheritedSubtitleIntent {
  const InheritSidecarSubtitle(this.suffix);

  final String suffix;
}

/// 把兄弟集的选择 [choice] 归成一种可以在新集上复现的意图；不可复现时返回 null
/// （调用方照常走 sidecar / 字幕文件夹 / 内封轨自动加载）。
///
/// 不可复现的情况：
/// - 外挂档不是兄弟集视频的同目录同名 sidecar——下载 / 导入进 `<appDocs>/video_subtitles/`
///   的档、从别的文件夹挑的档，都只属于那一集，搬到新集上就是字幕卡在上一集（BUG-165）。
/// - 互联 host 的外挂编码（`hostsidecar:`）、坏掉的 `embedded:` 值。
InheritedSubtitleIntent? inheritedSubtitleIntent(SiblingSubtitleChoice choice) {
  final String persisted = choice.subtitleSource;
  if (SubtitleSource.isOff(persisted)) return const InheritSubtitleOff();
  if (SubtitleSource.isEmbeddedPersisted(persisted)) {
    final int? index = int.tryParse(
      persisted.substring(SubtitleSource.embeddedPrefix.length),
    );
    if (index == null || index < 0) return null;
    return InheritEmbeddedSubtitle(
      previousVideoPath: choice.videoPath,
      streamIndex: index,
    );
  }
  if (SubtitleSource.isHostSidecarPersisted(persisted)) return null;
  final String? suffix = sidecarSubtitleSuffix(
    videoPath: choice.videoPath,
    subtitlePath: persisted,
  );
  return suffix == null ? null : InheritSidecarSubtitle(suffix);
}

/// [subtitlePath] 是 [videoPath] 的同目录同名 sidecar 时，返回去掉视频主名后剩下的
/// 尾巴（小写）；否则 null。
///
/// 与 [pickSameNameSubs] 同口径：同一目录、文件名（大小写不敏感）以视频主名开头、
/// 扩展名是外挂字幕格式。按视频主名切而不是按第一个 `.` 切：发布组文件名里常带点
/// （`Show.S01E01.1080p.ja.srt`），按第一个点切出来的尾巴每集都不一样。
String? sidecarSubtitleSuffix({
  required String videoPath,
  required String subtitlePath,
}) {
  if (subtitleFormatForPath(subtitlePath) == null) return null;
  if (!p.equals(
    p.canonicalize(p.dirname(subtitlePath)),
    p.canonicalize(p.dirname(videoPath)),
  )) {
    return null;
  }
  final String base = p.basenameWithoutExtension(videoPath).toLowerCase();
  final String name = p.basename(subtitlePath).toLowerCase();
  if (base.isEmpty || !name.startsWith(base)) return null;
  final String suffix = name.substring(base.length);
  return suffix.isEmpty ? null : suffix;
}

/// 轨标题的比较形态：小写，字母 / 数字以外的连续字符折成一个空格，去首尾空白。
/// `Signs & Songs` / `signs/songs` → `signs songs`；null / 空 → ''。
String normalizeSubtitleTrackTitle(String? title) {
  if (title == null) return '';
  return title
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
}

bool _isGraphicTrack(EmbeddedSubtitleTrack track) =>
    subtitleFormatForCodec(track.codec) == null;

/// 在新集的内封轨 [candidates] 里找与兄弟集那条 [wanted] 描述相同的轨；找不到返回 null。
///
/// 描述 = 文本 / 图形（硬条件：图形轨不能逐字查词，不拿它顶替文本轨，反之亦然）+
/// 语言（[normalizeSubtitleLanguageCode]，`jpn` / `ja` 视为同一种）+ 轨标题
/// （[normalizeSubtitleTrackTitle]）。依次：
/// 1. 标题相同、且语言不冲突（两边都声明了语言时必须相同；一边没声明不算冲突）。
/// 2. [wanted] 声明了语言：同语言的轨里，[wanted] 有标题时只收**没有标题**的轨——
///    标题对不上说明是另一种字幕（Full 对 Signs & Songs），不能顶替。
/// 3. [wanted] 既没语言也没标题：只剩序号可比，新集同序号的那条也同样没有描述才算。
///
/// 序号只做同档里的决胜：同档多条时依次偏好无标题、同 codec、同序号，再按轨序。
EmbeddedSubtitleTrack? matchEmbeddedSubtitleTrack(
  EmbeddedSubtitleTrack wanted,
  List<EmbeddedSubtitleTrack> candidates,
) {
  final bool wantGraphic = _isGraphicTrack(wanted);
  final String? wantLang = normalizeSubtitleLanguageCode(wanted.language);
  final String wantTitle = normalizeSubtitleTrackTitle(wanted.title);
  final List<EmbeddedSubtitleTrack> sameKind = <EmbeddedSubtitleTrack>[
    for (final EmbeddedSubtitleTrack c in candidates)
      if (_isGraphicTrack(c) == wantGraphic) c,
  ];

  if (wantTitle.isNotEmpty) {
    final List<EmbeddedSubtitleTrack> sameTitle = <EmbeddedSubtitleTrack>[
      for (final EmbeddedSubtitleTrack c in sameKind)
        if (normalizeSubtitleTrackTitle(c.title) == wantTitle &&
            _languagesCompatible(
              wantLang,
              normalizeSubtitleLanguageCode(c.language),
            ))
          c,
    ];
    if (sameTitle.isNotEmpty) return _tieBreak(sameTitle, wanted);
  }

  if (wantLang != null) {
    final List<EmbeddedSubtitleTrack> sameLang = <EmbeddedSubtitleTrack>[
      for (final EmbeddedSubtitleTrack c in sameKind)
        if (normalizeSubtitleLanguageCode(c.language) == wantLang &&
            (wantTitle.isEmpty || normalizeSubtitleTrackTitle(c.title).isEmpty))
          c,
    ];
    if (sameLang.isNotEmpty) return _tieBreak(sameLang, wanted);
    return null;
  }

  if (wantTitle.isEmpty) {
    for (final EmbeddedSubtitleTrack c in sameKind) {
      if (c.streamIndex == wanted.streamIndex &&
          normalizeSubtitleLanguageCode(c.language) == null &&
          normalizeSubtitleTrackTitle(c.title).isEmpty) {
        return c;
      }
    }
  }
  return null;
}

bool _languagesCompatible(String? a, String? b) =>
    a == null || b == null || a == b;

EmbeddedSubtitleTrack _tieBreak(
  List<EmbeddedSubtitleTrack> pool,
  EmbeddedSubtitleTrack wanted,
) {
  int rank(EmbeddedSubtitleTrack c) =>
      (normalizeSubtitleTrackTitle(c.title).isEmpty ? 0 : 4) +
      (c.codec == wanted.codec ? 0 : 2) +
      (c.streamIndex == wanted.streamIndex ? 0 : 1);
  EmbeddedSubtitleTrack best = pool.first;
  int bestRank = rank(best);
  for (final EmbeddedSubtitleTrack c in pool.skip(1)) {
    final int r = rank(c);
    if (r < bestRank) {
      best = c;
      bestRank = r;
    }
  }
  return best;
}

/// 把意图 [intent] 落到新集 [videoPath] 的字幕源枚举 [listing] 上，返回要加载的源；
/// 没有对应的源返回 null（调用方照常往下兜底）。
///
/// [previousEmbeddedTracks] 是兄弟集视频的内封轨枚举（只在 [InheritEmbeddedSubtitle]
/// 时用到）。[InheritSubtitleOff] 不需要枚举，恒返回 null，由调用方直接按关闭处理。
SubtitleSource? resolveInheritedSubtitleSource({
  required InheritedSubtitleIntent intent,
  required List<EmbeddedSubtitleTrack> previousEmbeddedTracks,
  required String videoPath,
  required SubtitleSourceListing listing,
}) {
  switch (intent) {
    case InheritSubtitleOff():
      return null;
    case InheritEmbeddedSubtitle(:final int streamIndex):
      EmbeddedSubtitleTrack? wanted;
      for (final EmbeddedSubtitleTrack t in previousEmbeddedTracks) {
        if (t.streamIndex == streamIndex) {
          wanted = t;
          break;
        }
      }
      // 兄弟集的文件读不到 / 那条轨已不在：描述无从得知，不按序号瞎猜。
      if (wanted == null) return null;
      final EmbeddedSubtitleTrack? match = matchEmbeddedSubtitleTrack(
        wanted,
        listing.embeddedProbe.tracks,
      );
      if (match == null) return null;
      for (final SubtitleSource s in listing.sources) {
        if (s.isEmbedded && s.streamIndex == match.streamIndex) return s;
      }
      return null;
    case InheritSidecarSubtitle(:final String suffix):
      for (final SubtitleSource s in listing.sources) {
        final String? path = s.externalPath;
        if (s.isEmbedded || path == null) continue;
        if (sidecarSubtitleSuffix(videoPath: videoPath, subtitlePath: path) ==
            suffix) {
          return s;
        }
      }
      return null;
  }
}
