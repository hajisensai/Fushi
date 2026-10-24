/// 歌词来源的纯判据（设计 §5.4）：sidecar 命名与优先级、内嵌多条时选哪条、来源键。
library;

import 'package:fushi_music/fushi_music.dart';

/// `music_lyrics.source` 的取值。
abstract final class MusicLyricsSource {
  /// 用户手动指定 / 编辑过的（`is_user_edited`，永远最高）。
  static const String user = 'user';
  static const String sidecar = 'sidecar';
  static const String embedded = 'embedded';
  static const String lrclib = 'provider:lrclib';

  /// 自动来源的优先级（高 → 低），不含 [user]。
  static const List<String> automaticPriority = <String>[
    sidecar,
    embedded,
    lrclib,
  ];
}

/// sidecar 扩展名分档（高 → 低）：同名 `.ttml` > `.ass` > `.lys/.qrc/.krc/.yrc` > `.lrc` >
/// `.srt/.vtt` > `.txt`。SAMI 与 SRT / VTT 同档。
const List<List<String>> kLyricSidecarTiers = <List<String>>[
  <String>['ttml'],
  <String>['ass', 'ssa'],
  <String>['lys', 'qrc', 'krc', 'yrc'],
  <String>['lrc'],
  <String>['srt', 'vtt', 'smi', 'sami'],
  <String>['txt'],
];

int? _tierOf(String ext) {
  for (int i = 0; i < kLyricSidecarTiers.length; i++) {
    if (kLyricSidecarTiers[i].contains(ext)) return i;
  }
  return null;
}

/// 语言后缀（`zh` / `zh-Hans` / `en_US` / `jpn`）。
final RegExp _langTag = RegExp(r'^[a-zA-Z]{2,3}([-_][a-zA-Z0-9]{2,8})*$');

class LyricSidecarFile {
  const LyricSidecarFile({
    required this.path,
    required this.ext,
    this.translationLang,
  });

  final String path;

  /// 小写扩展名（解析提示）。
  final String ext;

  /// 翻译文件的语言后缀（`song.zh.lrc` → `zh`）；正文为 null。
  final String? translationLang;
}

class LyricSidecarSet {
  const LyricSidecarSet({this.primary, this.translations = const []});

  final LyricSidecarFile? primary;
  final List<LyricSidecarFile> translations;

  bool get isEmpty => primary == null;
}

String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

/// 纯函数：从音频文件同目录的文件名里挑 sidecar。匹配不区分大小写：
/// - `<音频主名>.<ext>` → 正文候选，取最高档；
/// - `<音频主名>.<语言>.<ext>` → 该语言的翻译（每种语言取最高档）；
/// - 没有正文、只有翻译文件时，最高档的那个翻译文件当正文（有总比没有好）。
LyricSidecarSet pickLyricSidecars(String audioPath, Iterable<String> siblings) {
  final String audioName = _baseName(audioPath);
  final int dot = audioName.lastIndexOf('.');
  final String stem = (dot <= 0 ? audioName : audioName.substring(0, dot))
      .toLowerCase();
  LyricSidecarFile? best;
  int bestTier = 1 << 30;
  final Map<String, (int, LyricSidecarFile)> byLang =
      <String, (int, LyricSidecarFile)>{};
  for (final String p in siblings) {
    final String name = _baseName(p);
    final String lower = name.toLowerCase();
    if (lower == audioName.toLowerCase()) continue;
    if (!lower.startsWith('$stem.')) continue;
    final String rest = lower.substring(stem.length + 1);
    final List<String> parts = rest.split('.');
    final String ext = parts.last;
    final int? tier = _tierOf(ext);
    if (tier == null) continue;
    if (parts.length == 1) {
      if (tier < bestTier) {
        bestTier = tier;
        best = LyricSidecarFile(path: p, ext: ext);
      }
    } else if (parts.length == 2 && _langTag.hasMatch(parts[0])) {
      final String lang = name
          .substring(stem.length + 1)
          .split('.')
          .first
          .replaceAll('_', '-');
      final (int, LyricSidecarFile)? prev = byLang[lang.toLowerCase()];
      if (prev == null || tier < prev.$1) {
        byLang[lang.toLowerCase()] = (
          tier,
          LyricSidecarFile(path: p, ext: ext, translationLang: lang),
        );
      }
    }
  }
  final List<(int, LyricSidecarFile)> translations = byLang.values.toList()
    ..sort(((int, LyricSidecarFile) a, (int, LyricSidecarFile) b) {
      final int t = a.$1.compareTo(b.$1);
      return t != 0
          ? t
          : a.$2.translationLang!.compareTo(b.$2.translationLang!);
    });
  if (best == null && translations.isNotEmpty) {
    final LyricSidecarFile first = translations.removeAt(0).$2;
    best = LyricSidecarFile(path: first.path, ext: first.ext);
  }
  return LyricSidecarSet(
    primary: best,
    translations: <LyricSidecarFile>[
      for (final (int, LyricSidecarFile) t in translations) t.$2,
    ],
  );
}

/// 纯函数：一个文件有多条内嵌歌词时选哪条——时间粒度最细的优先（SYLT 逐字 > 内嵌 LRC >
/// 纯文本），同粒度取先出现的。
EmbeddedLyrics? pickBestEmbedded(List<EmbeddedLyrics> items) {
  EmbeddedLyrics? best;
  for (final EmbeddedLyrics e in items) {
    if (e.timeline.lines.isEmpty) continue;
    if (best == null ||
        e.timeline.timingQuality.index > best.timeline.timingQuality.index) {
      best = e;
    }
  }
  return best;
}
