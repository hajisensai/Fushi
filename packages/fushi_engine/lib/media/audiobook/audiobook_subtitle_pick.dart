/// 「这份音频该配哪份字幕」的**文件名级**唯一规则：Audiobookshelf 服务器字幕、
/// 发现页 / 控制通道下载包的分类、本机导入扫同名字幕，三处都调这一个函数。
///
/// 此前三处各写一份且互相矛盾：下载包取字典序第一份（`Book.en.srt` 排在
/// `Book.ja.srt` 前面就挂上英文；每个音轨一份字幕时拿 `part1.srt` 当整本书的时间
/// 轴），本机导入只认完全同名（`book.ja.srt` 认不出来），Audiobookshelf 又是第三套。
library;

import 'package:fushi_engine/media/audiobook/audiobook_subtitle_formats.dart';

/// 学习语言代码 → 字幕文件名里常见的别名标记（ISO 639-2 / 民间写法）。
const Map<String, Set<String>> _languageTagAliases = <String, Set<String>>{
  'ja': <String>{'jp', 'jpn'},
  'zh': <String>{'chi', 'zho', 'chs', 'cht'},
  'ko': <String>{'kor'},
  'en': <String>{'eng'},
};

final RegExp _languageTag = RegExp(r'\.([a-z]{2,3}(?:-[a-z0-9]{2,4})?)$');

/// 文件名 → 「主干 + 语言标记」：`Book.ja.srt` → (`book`, `ja`)；`Book.srt` →
/// (`book`, null)。主干去掉扩展名、转小写、去首尾空白；只认 2–3 个字母（可带
/// `-JP` 之类地区后缀）的倒数第二段为语言标记。
({String stem, String? lang}) splitAudiobookSubtitleName(String filename) {
  final String base = _baseOf(filename);
  final RegExpMatch? tag = _languageTag.firstMatch(base);
  if (tag == null) return (stem: base, lang: null);
  return (stem: base.substring(0, tag.start), lang: tag.group(1));
}

/// 文件名（或路径）去目录、去扩展名、转小写、去首尾空白。
String _baseOf(String filename) {
  String base = filename.replaceAll('\\', '/');
  base = base.substring(base.lastIndexOf('/') + 1).trim();
  final int dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  return base.toLowerCase().trim();
}

/// 语言标记的名次：学习语言（含别名、地区变体）0，无标记 1，别的语言 null（不自动
/// 挂，与视频 sidecar 的规则一致）。[langCode] 为空 = 没有语言偏好：任何标记都算 1。
int? _langRank(String? lang, String langCode) {
  if (lang == null) return 1;
  final String want = langCode.toLowerCase();
  if (want.isEmpty) return 1;
  final String base = lang.split('-').first;
  if (base == want || (_languageTagAliases[want]?.contains(base) ?? false)) {
    return 0;
  }
  return null;
}

/// 一份字幕为什么被挑中（决定能不能不问用户直接挂上，见 [AudiobookSubtitlePick.confident]）。
enum AudiobookSubtitleBasis {
  /// 主干与音频同名（多音轨时须与**每条**音轨同名，见 [pickAudiobookSubtitle]）。
  audioName,

  /// 主干与条目标题同名。
  title,

  /// 兜底：剩下的字幕全是同一个主干，但跟音频 / 标题都对不上。
  onlyStem,
}

/// [pickAudiobookSubtitle] 的结论：挑中的下标 + 依据。
final class AudiobookSubtitlePick {
  const AudiobookSubtitlePick({
    required this.index,
    required this.basis,
    required this.confident,
  });

  /// 在 `subtitleNames` 里的下标。
  final int index;

  final AudiobookSubtitleBasis basis;

  /// 足够确定、可以**不问用户**直接挂上：同名（音频 / 标题），或兜底但整本书只有
  /// 一条音频。多音轨 + 一份对不上名字的字幕（`Bonus.srt`）只算「推荐」：有用户在场
  /// 的入口（Audiobookshelf 流式建书）把它排第一让用户确认，不静默挂上；没有用户的
  /// 入口（下载包自动导入）照样用它——不用它就只能白跑几个小时转录。
  final bool confident;
}

/// 在 [subtitleNames]（文件名或路径）里挑出该配给 [audioNames] 的那份；挑不准返回
/// null（交给用户选 / 转录）。
///
/// 先定「哪些字幕属于这份音频」：
/// - [strictPerAudio]（播客单集、本机导入的同名扫描）：只认文件名主干与某个音频
///   **完全相同**的，不做任何退让——一个文件夹里常有很多集，挑错就挂上别集的字幕。
/// - 否则（整本书）：主干与音频同名的 → 其次与 [title] 同名的 → 其次全部字幕。
///   多音轨时「与音频同名」指与**每一条**音轨同名：只和其中一条同名的（`part1.srt`）
///   是那一条的分轨字幕，拿它当整本书的时间轴，后面的音轨全没有正文——这类字幕
///   直接排除，不参与后面的标题 / 兜底（`part1.mp3` + `part2.mp3` 只配了
///   `part1.srt` → null，交给转录）。
///
/// 选出的文件必须**同一个主干**（如 `book.ja.srt` + `book.ass`）；分属不同主干（几份
/// 互不相干的文件）时挑哪份都可能错，返回 null。
///
/// 再在同一主干里按名次挑：学习语言 [langCode] 标记的 > 无标记的（别的语言的不
/// 自动挂）；同名次按格式优先级（[kAudiobookSubtitleExtensions] 的顺序），再按
/// [subtitleNames] 的顺序。不是有声书字幕格式的文件一律忽略。
AudiobookSubtitlePick? pickAudiobookSubtitle({
  required List<String> audioNames,
  required List<String> subtitleNames,
  String? title,
  required String langCode,
  bool strictPerAudio = false,
}) {
  final List<String> formats = kAudiobookSubtitleExtensions.toList();
  // 与某个音频**整名**相同的字幕不拆语言标记：`Book.Vol.mp3` + `Book.Vol.srt` 的
  // `vol` 不是语言，按「别的语言」排除就把唯一对得上的字幕丢了。
  final Set<String> audioBases = <String>{
    for (final String audio in audioNames) _baseOf(audio),
  };
  final List<int> candidates = <int>[];
  final List<({String stem, String? lang})> names =
      <({String stem, String? lang})>[];
  final List<int> formatRanks = <int>[];
  for (int i = 0; i < subtitleNames.length; i++) {
    final String name = subtitleNames[i];
    final int dot = name.lastIndexOf('.');
    final int format = dot < 0
        ? -1
        : formats.indexOf(name.substring(dot + 1).toLowerCase());
    final String base = _baseOf(name);
    names.add(
      audioBases.contains(base)
          ? (stem: base, lang: null)
          : splitAudiobookSubtitleName(name),
    );
    formatRanks.add(format);
    if (format >= 0) candidates.add(i);
  }
  if (candidates.isEmpty) return null;
  List<int> where(List<int> from, bool Function(String stem) test) => <int>[
    for (final int i in from)
      if (test(names[i].stem)) i,
  ];

  // 每条音频认的主干：整名与拆掉疑似语言标记后的主干都算（`Book.Vol.mp3` 认
  // `Book.Vol.en.srt`）。
  final List<Set<String>> stemsPerAudio = <Set<String>>[
    for (final String audio in audioNames)
      <String>{_baseOf(audio), splitAudiobookSubtitleName(audio).stem},
  ];
  bool matchesSomeAudio(String stem) =>
      stemsPerAudio.any((Set<String> stems) => stems.contains(stem));

  List<int> pool;
  AudiobookSubtitleBasis basis = AudiobookSubtitleBasis.audioName;
  if (strictPerAudio) {
    pool = where(candidates, matchesSomeAudio);
  } else {
    bool matchesEveryAudio(String stem) =>
        stemsPerAudio.every((Set<String> stems) => stems.contains(stem));
    // 只和部分音轨同名的是分轨字幕：从整本书的候选里剔掉。
    final List<int> wholeBook = <int>[
      for (final int i in candidates)
        if (!matchesSomeAudio(names[i].stem) ||
            matchesEveryAudio(names[i].stem))
          i,
    ];
    pool = where(wholeBook, matchesEveryAudio);
    final String? wantTitle = title?.toLowerCase().trim();
    if (pool.isEmpty && wantTitle != null && wantTitle.isNotEmpty) {
      pool = where(wholeBook, (String stem) => stem == wantTitle);
      basis = AudiobookSubtitleBasis.title;
    }
    if (pool.isEmpty) {
      pool = wholeBook;
      basis = AudiobookSubtitleBasis.onlyStem;
    }
  }
  if (<String>{for (final int i in pool) names[i].stem}.length != 1) {
    return null;
  }

  int? best;
  (int, int, int)? bestKey;
  for (final int i in pool) {
    final int? lang = _langRank(names[i].lang, langCode);
    if (lang == null) continue;
    final (int, int, int) key = (lang, formatRanks[i], i);
    if (bestKey == null || _less(key, bestKey)) {
      best = i;
      bestKey = key;
    }
  }
  if (best == null) return null;
  return AudiobookSubtitlePick(
    index: best,
    basis: basis,
    confident:
        basis != AudiobookSubtitleBasis.onlyStem || audioNames.length == 1,
  );
}

bool _less((int, int, int) a, (int, int, int) b) {
  if (a.$1 != b.$1) return a.$1 < b.$1;
  if (a.$2 != b.$2) return a.$2 < b.$2;
  return a.$3 < b.$3;
}
