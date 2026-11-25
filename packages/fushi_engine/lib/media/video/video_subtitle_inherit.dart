import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoEmbeddedSubtitleTrack, RemoteVideoSidecarSubtitle;

// 合集里一集**自己没选过字幕**时，沿用同合集兄弟集最近一次的字幕选择（BUG-5464）。
//
// 统一合集 Phase 3 起每集是独立的 `VideoBooks` 行，字幕选择（`subtitleSource`）只记在
// 做选择的那一集上；换集（`pushReplacement` 到下一集）和从库里直接打开另一集，都是
// 拿那一集自己的行去 `_loadSingle`，行里没有选择。这里把兄弟集的选择**按描述**翻译
// 到新集：内封轨按「语言 + 轨标题」，同目录 sidecar 按去掉视频主名后的「语言 + 格式」
// 后缀——不按序号原样照搬（两集的轨顺序可以不同），也不把住在别处的单集字幕档
// （下载 / 导入进 `<appDocs>/video_subtitles/` 的）搬到别的集上（BUG-165）。
//
// 远端合集（互联 host / 媒体服务器，成员是各自独立的远端视频 id）同理：选择记在
// `video_remote_subtitle`（按成员 id），轨的描述随选择另记一份
// （[RemoteSubtitleChoiceDescriptor]），兄弟成员按描述落到自己的轨表上——见文件后半段。
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
  if (!p.equals(
    p.canonicalize(p.dirname(subtitlePath)),
    p.canonicalize(p.dirname(videoPath)),
  )) {
    return null;
  }
  return sidecarSubtitleNameSuffix(
    videoFileName: p.basename(videoPath),
    subtitleFileName: p.basename(subtitlePath),
  );
}

/// [sidecarSubtitleSuffix] 去掉同目录判定的文件名版：[subtitleFileName] 以
/// [videoFileName] 的主名开头（大小写不敏感）且是外挂字幕格式时，返回剩下的尾巴
/// （小写）；否则 null。远端只有文件名（互联 host 的同目录 sidecar 本来就同目录）。
String? sidecarSubtitleNameSuffix({
  required String videoFileName,
  required String subtitleFileName,
}) {
  if (subtitleFormatForPath(subtitleFileName) == null) return null;
  final String base = p.basenameWithoutExtension(videoFileName).toLowerCase();
  final String name = p.basename(subtitleFileName).toLowerCase();
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

/// 一条字幕轨用来跨集比对的描述：内封轨（[describeEmbeddedSubtitleTrack]）与远端轨
/// （[describeRemoteSubtitleTrack]）都归成它，由 [matchSubtitleTrackDescription] 比。
/// [graphic] = 图形轨（PGS / VobSub …，不能逐字查词）。
typedef SubtitleTrackDescription = ({
  int streamIndex,
  String codec,
  String? language,
  String? title,
  bool graphic,
});

/// 内封轨的描述：图形与否按 codec 认（[subtitleFormatForCodec] 认不出 = 图形）。
SubtitleTrackDescription describeEmbeddedSubtitleTrack(
  EmbeddedSubtitleTrack track,
) => (
  streamIndex: track.streamIndex,
  codec: track.codec,
  language: track.language,
  title: track.title,
  graphic: subtitleFormatForCodec(track.codec) == null,
);

/// 远端轨的描述：图形与否按后端给的 [RemoteVideoEmbeddedSubtitleTrack.isText]。
SubtitleTrackDescription describeRemoteSubtitleTrack(
  RemoteVideoEmbeddedSubtitleTrack track,
) => (
  streamIndex: track.streamIndex,
  codec: track.codec,
  language: track.language,
  title: track.title,
  graphic: !track.isText,
);

/// 在新集的内封轨 [candidates] 里找与兄弟集那条 [wanted] 描述相同的轨；找不到返回 null。
/// 判据见 [matchSubtitleTrackDescription]。
EmbeddedSubtitleTrack? matchEmbeddedSubtitleTrack(
  EmbeddedSubtitleTrack wanted,
  List<EmbeddedSubtitleTrack> candidates,
) {
  final int? at = matchSubtitleTrackDescription(
    describeEmbeddedSubtitleTrack(wanted),
    <SubtitleTrackDescription>[
      for (final EmbeddedSubtitleTrack c in candidates)
        describeEmbeddedSubtitleTrack(c),
    ],
  );
  return at == null ? null : candidates[at];
}

/// 在新集的轨描述 [candidates] 里找与兄弟集那条 [wanted] 相同的轨，返回它在
/// [candidates] 里的下标；找不到返回 null。
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
int? matchSubtitleTrackDescription(
  SubtitleTrackDescription wanted,
  List<SubtitleTrackDescription> candidates,
) {
  final String? wantLang = normalizeSubtitleLanguageCode(wanted.language);
  final String wantTitle = normalizeSubtitleTrackTitle(wanted.title);
  final List<int> sameKind = <int>[
    for (int i = 0; i < candidates.length; i++)
      if (candidates[i].graphic == wanted.graphic) i,
  ];

  if (wantTitle.isNotEmpty) {
    final List<int> sameTitle = <int>[
      for (final int i in sameKind)
        if (normalizeSubtitleTrackTitle(candidates[i].title) == wantTitle &&
            _languagesCompatible(
              wantLang,
              normalizeSubtitleLanguageCode(candidates[i].language),
            ))
          i,
    ];
    if (sameTitle.isNotEmpty) return _tieBreak(sameTitle, candidates, wanted);
  }

  if (wantLang != null) {
    final List<int> sameLang = <int>[
      for (final int i in sameKind)
        if (normalizeSubtitleLanguageCode(candidates[i].language) == wantLang &&
            (wantTitle.isEmpty ||
                normalizeSubtitleTrackTitle(candidates[i].title).isEmpty))
          i,
    ];
    if (sameLang.isNotEmpty) return _tieBreak(sameLang, candidates, wanted);
    return null;
  }

  if (wantTitle.isEmpty) {
    for (final int i in sameKind) {
      final SubtitleTrackDescription c = candidates[i];
      if (c.streamIndex == wanted.streamIndex &&
          normalizeSubtitleLanguageCode(c.language) == null &&
          normalizeSubtitleTrackTitle(c.title).isEmpty) {
        return i;
      }
    }
  }
  return null;
}

bool _languagesCompatible(String? a, String? b) =>
    a == null || b == null || a == b;

int _tieBreak(
  List<int> pool,
  List<SubtitleTrackDescription> candidates,
  SubtitleTrackDescription wanted,
) {
  int rank(SubtitleTrackDescription c) =>
      (normalizeSubtitleTrackTitle(c.title).isEmpty ? 0 : 4) +
      (c.codec == wanted.codec ? 0 : 2) +
      (c.streamIndex == wanted.streamIndex ? 0 : 1);
  int best = pool.first;
  int bestRank = rank(candidates[best]);
  for (final int i in pool.skip(1)) {
    final int r = rank(candidates[i]);
    if (r < bestRank) {
      best = i;
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

// ── 远端合集（互联 host / 媒体服务器）──────────────────────────────────────────
//
// 远端成员没有 `VideoBooks` 行，选择按 `(成员 id, 0)` 记在 `video_remote_subtitle`
// （值是 `embedded:<n>` / `hostsidecar:<文件名>` / 本机档路径 / `off:`，冻结格式，旧版本
// 与同步对端照样读写）。值里没有轨的描述，兄弟成员的轨表又只有向 host 再开一次那个
// 成员的取流会话才拿得到，所以描述在**选轨那一刻**（页面手里正有本成员的轨表）另记
// 一份：`video_remote_subtitle_descriptor`，同样按 `remoteSubtitleKey` 记，值是
// [RemoteSubtitleChoiceDescriptor.toJson]。描述带着它描述的那个选择值
// （[RemoteSubtitleChoiceDescriptor.source]）：旧版本 / 同步对端改了选择却没改描述时，
// 两边对不上，描述作废，不会把旧描述套到新选择上。

/// 远端成员一次字幕选择附带的轨描述（`video_remote_subtitle_descriptor` 的一条值）。
///
/// 两种：
/// - 内封 / 后端轨（`embedded:<n>`）：[track] = 那条轨的文本 / 图形 + 语言 + 标题 + codec；
/// - 互联 host 的同目录 sidecar（`hostsidecar:<文件名>`）：[sidecarSuffix] = 去掉成员
///   视频主名后的尾巴（小写，如 `.ja.srt`），与本地 sidecar 同口径。
///
/// wire（JSON 对象，未知键忽略）：
/// - `{"source": "embedded:2", "kind": "embedded", "codec": "subrip",
///   "language": "jpn", "title": "Full", "graphic": false}`（language / title 缺省可省）；
/// - `{"source": "hostsidecar:Show - 01.ja.srt", "kind": "host_sidecar",
///   "suffix": ".ja.srt"}`。
final class RemoteSubtitleChoiceDescriptor {
  const RemoteSubtitleChoiceDescriptor._({
    required this.source,
    this.track,
    this.sidecarSuffix,
  });

  /// 内封 / 后端轨的选择 `embedded:<track.streamIndex>`。
  factory RemoteSubtitleChoiceDescriptor.embedded(
    SubtitleTrackDescription track,
  ) => RemoteSubtitleChoiceDescriptor._(
    source: '${SubtitleSource.embeddedPrefix}${track.streamIndex}',
    track: track,
  );

  /// 互联 host 外挂字幕的选择 `hostsidecar:<fileName>`，尾巴 [suffix]。
  factory RemoteSubtitleChoiceDescriptor.hostSidecar({
    required String fileName,
    required String suffix,
  }) => RemoteSubtitleChoiceDescriptor._(
    source: '${SubtitleSource.hostSidecarPrefix}$fileName',
    sidecarSuffix: suffix,
  );

  static const String _kindEmbedded = 'embedded';
  static const String _kindHostSidecar = 'host_sidecar';

  /// 它描述的那个持久化选择值（与 `video_remote_subtitle` 同一编码）。
  final String source;

  /// 内封 / 后端轨的描述；host sidecar 时为 null。
  final SubtitleTrackDescription? track;

  /// host sidecar 的尾巴；内封轨时为 null。
  final String? sidecarSuffix;

  /// 这份描述是不是在说 [persisted] 这个选择（不是就作废）。
  bool describes(String? persisted) => persisted != null && persisted == source;

  Map<String, Object?> toJson() {
    final SubtitleTrackDescription? t = track;
    if (t != null) {
      return <String, Object?>{
        'source': source,
        'kind': _kindEmbedded,
        'codec': t.codec,
        if ((t.language ?? '').isNotEmpty) 'language': t.language,
        if ((t.title ?? '').isNotEmpty) 'title': t.title,
        'graphic': t.graphic,
      };
    }
    return <String, Object?>{
      'source': source,
      'kind': _kindHostSidecar,
      'suffix': sidecarSuffix,
    };
  }

  /// [toJson] 的逆；形状不对（缺键、类型不符、source 与 kind 对不上）返回 null。
  static RemoteSubtitleChoiceDescriptor? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? source = json['source'];
    if (source is! String) return null;
    switch (json['kind']) {
      case _kindEmbedded:
        if (!SubtitleSource.isEmbeddedPersisted(source)) return null;
        final int? index = int.tryParse(
          source.substring(SubtitleSource.embeddedPrefix.length),
        );
        final Object? codec = json['codec'];
        final Object? graphic = json['graphic'];
        final Object? language = json['language'];
        final Object? title = json['title'];
        if (index == null || index < 0) return null;
        if (codec is! String || graphic is! bool) return null;
        if (language != null && language is! String) return null;
        if (title != null && title is! String) return null;
        return RemoteSubtitleChoiceDescriptor.embedded((
          streamIndex: index,
          codec: codec,
          language: language as String?,
          title: title as String?,
          graphic: graphic,
        ));
      case _kindHostSidecar:
        if (!SubtitleSource.isHostSidecarPersisted(source)) return null;
        final String fileName = source.substring(
          SubtitleSource.hostSidecarPrefix.length,
        );
        final Object? suffix = json['suffix'];
        if (fileName.isEmpty || suffix is! String || suffix.isEmpty) {
          return null;
        }
        return RemoteSubtitleChoiceDescriptor.hostSidecar(
          fileName: fileName,
          suffix: suffix,
        );
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteSubtitleChoiceDescriptor &&
      other.source == source &&
      other.track == track &&
      other.sidecarSuffix == sidecarSuffix;

  @override
  int get hashCode => Object.hash(source, track, sidecarSuffix);
}

/// 用户在远端成员上选了 [source] 时，按这一刻本成员的轨表 [embeddedTracks] 与视频
/// 文件名 [videoFileName]（`RemoteVideoInfo.fileName`，null = 后端不给）写出它的描述；
/// 描述不了时返回 null（调用方删掉该成员的旧描述）。
///
/// 描述不了的：`off:`（沿用关闭不需要描述）、本机档路径（下载 / 导入的单集字幕，不沿用，
/// BUG-165）、后端默认字幕（每集各自下发，本来就是默认）、轨表里已没有的 `embedded:<n>`、
/// 文件名不以视频主名开头的 host 外挂字幕。
RemoteSubtitleChoiceDescriptor? describeRemoteSubtitleChoice({
  required String source,
  required List<RemoteVideoEmbeddedSubtitleTrack> embeddedTracks,
  required String? videoFileName,
}) {
  if (SubtitleSource.isEmbeddedPersisted(source)) {
    final int? index = int.tryParse(
      source.substring(SubtitleSource.embeddedPrefix.length),
    );
    if (index == null) return null;
    for (final RemoteVideoEmbeddedSubtitleTrack t in embeddedTracks) {
      if (t.streamIndex == index) {
        return RemoteSubtitleChoiceDescriptor.embedded(
          describeRemoteSubtitleTrack(t),
        );
      }
    }
    return null;
  }
  if (SubtitleSource.isHostSidecarPersisted(source)) {
    final String fileName = source.substring(
      SubtitleSource.hostSidecarPrefix.length,
    );
    if (videoFileName == null || videoFileName.isEmpty) return null;
    final String? suffix = sidecarSubtitleNameSuffix(
      videoFileName: videoFileName,
      subtitleFileName: fileName,
    );
    if (suffix == null) return null;
    return RemoteSubtitleChoiceDescriptor.hostSidecar(
      fileName: fileName,
      suffix: suffix,
    );
  }
  return null;
}

/// 远端合集一个成员的字幕记忆（[pickLatestRemoteSiblingSubtitleChoice] 的输入）：
/// 成员 id、`video_remote_subtitle` 里它的选择、`video_remote_subtitle_descriptor` 里的
/// 描述、`video_remote_position_at_<id>` 的播放时刻（毫秒，0 = 没有）。
typedef RemoteMemberSubtitleMemory = ({
  String memberId,
  String? subtitleSource,
  RemoteSubtitleChoiceDescriptor? descriptor,
  int playedAt,
});

/// 选中的兄弟成员选择：`off:`（[descriptor] 为 null）或带有效描述的选择。
typedef RemoteSiblingSubtitleChoice = ({
  String subtitleSource,
  RemoteSubtitleChoiceDescriptor? descriptor,
});

/// 这条远端选择能不能沿用到兄弟成员：`off:`，或带着在说这个选择的描述
/// （[RemoteSubtitleChoiceDescriptor.describes]）。
bool isInheritableRemoteSubtitleChoice(
  String? source,
  RemoteSubtitleChoiceDescriptor? descriptor,
) {
  if (source == null || source.isEmpty) return false;
  return SubtitleSource.isOff(source) ||
      (descriptor?.describes(source) ?? false);
}

/// 远端合集里挑「可沿用的兄弟成员选择里播放时刻最新的那一个」，跳过当前成员
/// [currentMemberId]。
///
/// 可沿用见 [isInheritableRemoteSubtitleChoice]：没有描述的旧选择、本机档路径、后端默认
/// 字幕都不参与（不为了读兄弟成员的轨表去 host 再开一次取流）。判据是远端断点的时间戳
/// 键 `video_remote_position_at_<成员 id>`（播放中周期落、换集前落一次，互联 sweep 也会
/// 带回别的设备的）——与本地合集按 `lastPlayedAt` 同义；没有播放时刻的成员不参与。
/// 同一时刻取 [members] 里靠前的那个。
RemoteSiblingSubtitleChoice? pickLatestRemoteSiblingSubtitleChoice(
  Iterable<RemoteMemberSubtitleMemory> members, {
  required String currentMemberId,
}) {
  RemoteMemberSubtitleMemory? best;
  for (final RemoteMemberSubtitleMemory m in members) {
    if (m.memberId == currentMemberId) continue;
    if (m.playedAt <= 0) continue;
    if (!isInheritableRemoteSubtitleChoice(m.subtitleSource, m.descriptor)) {
      continue;
    }
    if (best == null || m.playedAt > best.playedAt) best = m;
  }
  if (best == null) return null;
  final String source = best.subtitleSource!;
  return (
    subtitleSource: source,
    descriptor: SubtitleSource.isOff(source) ? null : best.descriptor,
  );
}

/// 把兄弟成员的选择 [choice] 落到当前成员上，返回当前成员自己的选择编码：
/// `off:` / `embedded:<本成员的序号>` / `hostsidecar:<本成员的文件名>`；没有对应的轨
/// 返回 null（调用方照常走语言偏好 / 服务器默认）。
///
/// 内封轨按 [matchSubtitleTrackDescription] 在 [embeddedTracks] 里找（两个成员轨顺序
/// 不同也对得上，标题不同的同语言轨不顶替）；host sidecar 按尾巴在 [sidecars] 里找，
/// 当前成员的视频文件名 [videoFileName] 不知道就不猜。
String? resolveRemoteInheritedSubtitleSource({
  required RemoteSiblingSubtitleChoice choice,
  required List<RemoteVideoEmbeddedSubtitleTrack> embeddedTracks,
  required List<RemoteVideoSidecarSubtitle> sidecars,
  required String? videoFileName,
}) {
  if (SubtitleSource.isOff(choice.subtitleSource)) {
    return SubtitleSource.offSentinel;
  }
  final RemoteSubtitleChoiceDescriptor? descriptor = choice.descriptor;
  if (descriptor == null || !descriptor.describes(choice.subtitleSource)) {
    return null;
  }
  final SubtitleTrackDescription? wanted = descriptor.track;
  if (wanted != null) {
    final int? at =
        matchSubtitleTrackDescription(wanted, <SubtitleTrackDescription>[
          for (final RemoteVideoEmbeddedSubtitleTrack t in embeddedTracks)
            describeRemoteSubtitleTrack(t),
        ]);
    return at == null
        ? null
        : '${SubtitleSource.embeddedPrefix}${embeddedTracks[at].streamIndex}';
  }
  final String? suffix = descriptor.sidecarSuffix;
  if (suffix == null || videoFileName == null || videoFileName.isEmpty) {
    return null;
  }
  for (final RemoteVideoSidecarSubtitle s in sidecars) {
    if (sidecarSubtitleNameSuffix(
          videoFileName: videoFileName,
          subtitleFileName: s.fileName,
        ) ==
        suffix) {
      return '${SubtitleSource.hostSidecarPrefix}${s.fileName}';
    }
  }
  return null;
}
