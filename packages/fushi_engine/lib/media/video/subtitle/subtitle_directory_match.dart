/// 反馈 0PZAhFd1RO：整季字幕放在**单独一个文件夹**里时，按集号给当前视频挑字幕。
///
/// 视频同目录同名的 sidecar 由 `video_sidecar.dart` 负责；这里处理的是「字幕和视频
/// 不同名、也不同目录」的情形——用户为某个系列记住一个字幕文件夹后，之后每一集都
/// 在这个文件夹里按 `SxxEyy` / 集号认领自己的那一份。
///
/// 纯函数，无 IO：调用方列目录后把文件名交进来。宁缺毋滥——认不出集号、找不到、
/// 或多个候选分不出高下时都不挑，交给用户手选（集号解析容易误配，误挂一份别集的
/// 字幕比不挂更糟）。
library;

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/video_filename_parser.dart';

/// 文件夹匹配认的字幕格式（与视频手选字幕白名单 srt/vtt/ass/ssa 一致），顺序即同一份
/// 字幕多种格式并存时的择一优先级。
const List<String> kSubtitleDirectoryMatchExtensions = <String>[
  'srt',
  'ass',
  'ssa',
  'vtt',
];

/// 一次文件夹匹配的结论。
enum SubtitleDirectoryMatchStatus {
  /// 挑中了唯一一份（[SubtitleDirectoryMatch.fileName]）。
  matched,

  /// 视频文件名里认不出集号，无从匹配。
  noEpisodeNumber,

  /// 文件夹里没有这一集的字幕。
  notFound,

  /// 这一集有多份字幕且分不出该用哪份（[SubtitleDirectoryMatch.candidates]）。
  ambiguous,
}

/// [matchEpisodeSubtitleInDirectory] 的结果。
class SubtitleDirectoryMatch {
  const SubtitleDirectoryMatch._(
    this.status, {
    this.fileName,
    this.candidates = const <String>[],
  });

  const SubtitleDirectoryMatch.matched(String fileName)
    : this._(SubtitleDirectoryMatchStatus.matched, fileName: fileName);

  const SubtitleDirectoryMatch.noEpisodeNumber()
    : this._(SubtitleDirectoryMatchStatus.noEpisodeNumber);

  const SubtitleDirectoryMatch.notFound()
    : this._(SubtitleDirectoryMatchStatus.notFound);

  const SubtitleDirectoryMatch.ambiguous(List<String> candidates)
    : this._(SubtitleDirectoryMatchStatus.ambiguous, candidates: candidates);

  final SubtitleDirectoryMatchStatus status;

  /// 挑中的文件名（basename，保留原大小写）；仅 [SubtitleDirectoryMatchStatus.matched]
  /// 非 null。
  final String? fileName;

  /// 打成平手的候选文件名（仅 [SubtitleDirectoryMatchStatus.ambiguous]）。
  final List<String> candidates;

  @override
  String toString() =>
      'SubtitleDirectoryMatch($status, fileName: $fileName, '
      'candidates: $candidates)';
}

/// 拆好的一个字幕文件名。
typedef _SubtitleName = ({String name, String stem, String? tag, String ext});

/// 字幕文件名 stem 末段的语言标记：`.ja` / `.jpn` / `.zh-Hans` / `.chs&jpn` 这类
/// 字母开头的段（数字开头的段是集号 / 版本，不算）。
final RegExp _langTagSegment = RegExp(
  r'^[A-Za-z]{2,8}(?:[-_&][A-Za-z0-9]{2,8})*$',
);

/// 学习语言代码 → 字幕文件名里常见的同义标记（小写）。不在表里的语言只认代码本身。
const Map<String, Set<String>> _languageTagAliases = <String, Set<String>>{
  'ja': <String>{'ja', 'jp', 'jpn', 'jap', 'japanese'},
  'en': <String>{'en', 'eng', 'english'},
  'ko': <String>{'ko', 'kor', 'korean'},
  'zh': <String>{'zh', 'chi', 'zho', 'chs', 'cht', 'sc', 'tc', 'gb', 'big5'},
};

/// 拆一个字幕文件名：`[Group] Show - 03.ja.ass` → stem `[Group] Show - 03`、
/// 标记 `ja`、扩展名 `ass`。不是 [kSubtitleDirectoryMatchExtensions] 里的格式返回
/// null。
_SubtitleName? _splitSubtitleName(String rawName) {
  final String name = p.basename(rawName);
  final String ext = p.extension(name).toLowerCase().replaceFirst('.', '');
  if (!kSubtitleDirectoryMatchExtensions.contains(ext)) return null;
  final String withoutExt = name.substring(0, name.length - ext.length - 1);
  final int dot = withoutExt.lastIndexOf('.');
  if (dot > 0) {
    final String last = withoutExt.substring(dot + 1);
    if (_langTagSegment.hasMatch(last)) {
      return (
        name: name,
        stem: withoutExt.substring(0, dot),
        tag: last,
        ext: ext,
      );
    }
  }
  return (name: name, stem: withoutExt, tag: null, ext: ext);
}

/// 文件名「骨架」：小写 + 每段数字换成 `#`。同一字幕组同一套命名的各集骨架相同
/// （`[Group] Show - 01 [1080p].ja.ass` 与 `- 02` 都是 `[group] show - # [#p].ja.ass`），
/// 用来在一集多份字幕时认出「和用户上次选的是同一套」。
String _skeleton(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'\d+'), '#');

bool _tagMatchesLanguage(String? tag, String langCode) {
  if (tag == null) return false;
  final String lang = langCode.toLowerCase();
  if (lang.isEmpty) return false;
  final Set<String> aliases = _languageTagAliases[lang] ?? <String>{lang};
  final String lower = tag.toLowerCase();
  if (aliases.contains(lower)) return true;
  // `zh-Hans` / `ja_JP` / `chs&jpn`：任一分段是学习语言即算。
  return lower.split(RegExp(r'[-_&]')).any(aliases.contains);
}

/// 在字幕文件夹的文件名列表 [fileNames] 里，给视频 [videoPath] 挑这一集的字幕。
///
/// 规则：
/// 1. 视频集号 / 季号取自 [parseVideoPath]（文件名没写季号时回落季目录名）。
///    认不出集号 → [SubtitleDirectoryMatchStatus.noEpisodeNumber]。
/// 2. 字幕集号按同一个文件名规则引擎解析（先剥掉语言标记），单个解不出的再用同文件夹
///    兄弟差分补齐（`1.ass … 12.ass` 这类不补零的命名，[parsedEpisodeNumbersOf]）。
///    集号相同、且两边季号都已知时季号也相同的才算候选。
/// 3. 候选按优先级分层，取最高一层：与 [templateFileName]（用户在这个文件夹里选过的
///    那份）骨架相同 > 与它语言标记相同 > 带学习语言 [langCode] 标记 > 无标记 >
///    其它语言。最高层里若不止一份不同的字幕（stem 或语言标记不同：不同字幕组 /
///    版本 / 语言）→ [SubtitleDirectoryMatchStatus.ambiguous]；只差格式的按「与模板
///    同格式 > srt > ass > ssa > vtt」择一。
SubtitleDirectoryMatch matchEpisodeSubtitleInDirectory({
  required String videoPath,
  required List<String> fileNames,
  required String langCode,
  String? templateFileName,
}) {
  final VideoNameInfo video = parseVideoPath(videoPath);
  final int? episode = video.episode;
  if (episode == null || episode <= 0) {
    return const SubtitleDirectoryMatch.noEpisodeNumber();
  }

  final List<_SubtitleName> subs = <_SubtitleName>[
    for (final String raw in fileNames)
      if (_splitSubtitleName(raw) case final _SubtitleName s
          when s.stem.isNotEmpty)
        s,
  ];
  if (subs.isEmpty) return const SubtitleDirectoryMatch.notFound();

  // 同一 stem（多语言 / 多格式）只解析一次；兄弟差分要求 stem 两两不同。统一挂
  // `.mkv` 后缀交给视频文件名规则引擎，免得它把 stem 里的 `.S01E02` 当扩展名剥掉。
  final List<String> uniqueStems = <String>{
    for (final _SubtitleName s in subs) s.stem,
  }.toList();
  final List<String> parseNames = <String>[
    for (final String stem in uniqueStems) '$stem.mkv',
  ];
  final List<int?> stemEpisodes = parsedEpisodeNumbersOf(parseNames);
  final Map<String, int?> episodeOf = <String, int?>{
    for (int i = 0; i < uniqueStems.length; i++) uniqueStems[i]: stemEpisodes[i],
  };
  final Map<String, int?> seasonOf = <String, int?>{
    for (int i = 0; i < uniqueStems.length; i++)
      uniqueStems[i]: parseVideoFilename(parseNames[i]).season,
  };

  final int? videoSeason = video.season;
  final List<_SubtitleName> candidates = <_SubtitleName>[
    for (final _SubtitleName s in subs)
      if (episodeOf[s.stem] == episode &&
          (videoSeason == null ||
              seasonOf[s.stem] == null ||
              seasonOf[s.stem] == videoSeason))
        s,
  ];
  if (candidates.isEmpty) return const SubtitleDirectoryMatch.notFound();

  final _SubtitleName? template = templateFileName == null
      ? null
      : _splitSubtitleName(templateFileName);
  final String? templateSkeleton = template == null
      ? null
      : _skeleton(template.name);

  int tierOf(_SubtitleName s) {
    if (templateSkeleton != null && _skeleton(s.name) == templateSkeleton) {
      return 0;
    }
    if (template != null &&
        (s.tag?.toLowerCase() ?? '') == (template.tag?.toLowerCase() ?? '')) {
      return 1;
    }
    if (_tagMatchesLanguage(s.tag, langCode)) return 2;
    if (s.tag == null) return 3;
    return 4;
  }

  int bestTier = 1 << 30;
  for (final _SubtitleName s in candidates) {
    final int tier = tierOf(s);
    if (tier < bestTier) bestTier = tier;
  }
  final List<_SubtitleName> best = <_SubtitleName>[
    for (final _SubtitleName s in candidates)
      if (tierOf(s) == bestTier) s,
  ];

  // 最高层按「stem + 语言标记」去重：只差格式的是同一份字幕的不同封装，按格式择一；
  // 差在 stem 或语言上的是不同的字幕，分不出高下就交给用户。
  final Set<String> distinct = <String>{
    for (final _SubtitleName s in best)
      '${s.stem.toLowerCase()}\u0000${s.tag?.toLowerCase() ?? ''}',
  };
  if (distinct.length > 1) {
    return SubtitleDirectoryMatch.ambiguous(<String>[
      for (final _SubtitleName s in best) s.name,
    ]);
  }

  int formatRank(String ext) {
    if (template != null && ext == template.ext) return -1;
    return kSubtitleDirectoryMatchExtensions.indexOf(ext);
  }

  _SubtitleName chosen = best.first;
  for (final _SubtitleName s in best.skip(1)) {
    if (formatRank(s.ext) < formatRank(chosen.ext)) chosen = s;
  }
  return SubtitleDirectoryMatch.matched(chosen.name);
}
