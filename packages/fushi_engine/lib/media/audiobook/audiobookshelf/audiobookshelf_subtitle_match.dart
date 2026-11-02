/// 服务器条目里该挂哪份字幕：流式建书时自动挂上、下载单集时随附、选择对话框的
/// 排序，三处共用这一条规则（此前流式与下载各写一份，判据还不一样）。
library;

import 'package:fushi_engine/media/audiobook/audiobook_subtitle_formats.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';

/// 文件名 → 「主干 + 语言标记」：`Book.ja.srt` → (`book`, `ja`)；`Book.srt` →
/// (`book`, null)。主干去掉扩展名、转小写、去首尾空白。
({String stem, String? lang}) _splitName(String filename) {
  String base = filename.trim();
  final int dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  base = base.toLowerCase().trim();
  final RegExpMatch? tag = RegExp(
    r'\.([a-z]{2,3}(?:-[a-z0-9]{2,4})?)$',
  ).firstMatch(base);
  if (tag == null) return (stem: base, lang: null);
  return (stem: base.substring(0, tag.start), lang: tag.group(1));
}

/// 语言标记的名次：学习语言 0，无标记 1，别的语言 null（不自动挂）。
int? _langRank(String? lang, String langCode) {
  if (lang == null) return 1;
  final String want = langCode.toLowerCase();
  if (want.isNotEmpty && (lang == want || lang.startsWith('$want-'))) return 0;
  return null;
}

/// 在 [detail] 的服务器字幕文件里挑出该自动挂上的那份；挑不准返回 null（交给用户选）。
///
/// 先定「哪些文件属于这份音频」：
/// - 播客单集（[episode] 非空）：只认文件名主干与这一集音频**完全相同**的。一个播客
///   文件夹里常有很多集，挑错会把别集的字幕挂上来，所以不做任何退让。
/// - 书：主干与某个音轨同名的 → 其次与条目标题同名的 → 其次全部字幕。选出的文件必须
///   **同一个主干**（如 `book.ja.srt` + `book.ass`）；分属不同主干（每个音轨一份、或几份
///   互不相干的文件）时挑哪份都可能错，返回 null。
///
/// 再在同一主干里按名次挑：学习语言 [langCode] 标记的 > 无语言标记的（别的语言的不自动
/// 挂，与视频 sidecar 的规则一致）；同名次按格式优先级（[kAudiobookSubtitleExtensions]
/// 的顺序），再按服务器列出的顺序。
AudiobookshelfLibraryFile? matchAudiobookshelfSubtitle(
  AudiobookshelfItemDetail detail, {
  AudiobookshelfEpisode? episode,
  required String langCode,
}) {
  final List<AudiobookshelfLibraryFile> candidates = detail.subtitleFiles;
  if (candidates.isEmpty) return null;
  final List<({String stem, String? lang})> names =
      <({String stem, String? lang})>[
        for (final AudiobookshelfLibraryFile file in candidates)
          _splitName(file.filename),
      ];
  List<int> where(bool Function(String stem) test) => <int>[
    for (int i = 0; i < candidates.length; i++)
      if (test(names[i].stem)) i,
  ];

  List<int> pool;
  if (episode != null) {
    final String? audio = episode.track.filename;
    if (audio == null) return null;
    final String audioStem = _splitName(audio).stem;
    pool = where((String stem) => stem == audioStem);
  } else {
    final Set<String> audioStems = <String>{
      for (final AudiobookshelfTrack track in detail.tracks)
        if (track.filename case final String name) _splitName(name).stem,
    };
    final String title = detail.item.title.toLowerCase().trim();
    pool = where(audioStems.contains);
    if (pool.isEmpty) pool = where((String stem) => stem == title);
    if (pool.isEmpty) pool = where((String _) => true);
    if (<String>{for (final int i in pool) names[i].stem}.length != 1) {
      return null;
    }
  }

  final List<String> formats = kAudiobookSubtitleExtensions.toList();
  int? best;
  (int, int, int)? bestKey;
  for (final int i in pool) {
    final int? lang = _langRank(names[i].lang, langCode);
    if (lang == null) continue;
    final int format = formats.indexOf(candidates[i].extension);
    final (int, int, int) key = (lang, format, i);
    if (bestKey == null || _less(key, bestKey)) {
      best = i;
      bestKey = key;
    }
  }
  return best == null ? null : candidates[best];
}

bool _less((int, int, int) a, (int, int, int) b) {
  if (a.$1 != b.$1) return a.$1 < b.$1;
  if (a.$2 != b.$2) return a.$2 < b.$2;
  return a.$3 < b.$3;
}
