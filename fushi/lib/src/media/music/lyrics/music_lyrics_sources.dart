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

  /// 在线音源插件自带的歌词：`provider:plugin:<插件 id>`（插件曲目才有，排在 LRCLIB 前）。
  static const String _pluginPrefix = 'provider:plugin:';

  static String plugin(String pluginId) => '$_pluginPrefix$pluginId';

  static bool isPlugin(String source) => source.startsWith(_pluginPrefix);

  static String? pluginIdOf(String source) =>
      isPlugin(source) ? source.substring(_pluginPrefix.length) : null;

  /// 歌词插件（`lyricsSearch` + `lyricsFetch`，LRCLIB 之后按用户排序）按标题 / 艺人搜到的
  /// 歌词：`provider:lyrics:<插件 id>`。与 [plugin] 分开成两条缓存：同一个插件既给平台曲目
  /// 自带歌词、又做歌词来源时，两条路径的结果（与负缓存）互不覆盖。
  static const String _lyricsPluginPrefix = 'provider:lyrics:';

  static String lyricsPlugin(String pluginId) =>
      '$_lyricsPluginPrefix$pluginId';

  static bool isLyricsPlugin(String source) =>
      source.startsWith(_lyricsPluginPrefix);

  static String? lyricsPluginIdOf(String source) => isLyricsPlugin(source)
      ? source.substring(_lyricsPluginPrefix.length)
      : null;

  /// 自动来源的优先级（高 → 低），不含 [user]。
  static const List<String> automaticPriority = <String>[
    sidecar,
    embedded,
    lrclib,
  ];
}

/// sidecar 扩展名分档（高 → 低）：同名 `.ttml` > `.ass` > `.lys/.qrc/.krc/.yrc` >
/// `.kar/.mid`（MIDI 歌词事件，卡拉 OK 歌曲文件，P3）> `.lrc` > `.srt/.vtt` > `.txt`
/// （UltraStar `.txt` 由内容嗅探认出）。SAMI 与 SRT / VTT 同档。
const List<List<String>> kLyricSidecarTiers = <List<String>>[
  <String>['ttml'],
  <String>['ass', 'ssa'],
  <String>['lys', 'qrc', 'krc', 'yrc'],
  <String>['kar', 'mid', 'midi'],
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

/// UltraStar 歌曲包常见的命名：`Artist - Title.txt` 与音频文件主名不同，靠头部 `#MP3:`
/// （新版 `#AUDIO:`）指向音频文件名。纯函数：从 `.txt` 开头 [head] 里取它指向的文件名
/// （不含目录）；不是 UltraStar 头或没写返回 null。
String? ultraStarAudioReference(String head) {
  bool sawBpm = false;
  String? audio;
  for (final String raw in head.split('\n')) {
    final String l = raw.trim();
    if (!l.startsWith('#')) {
      if (l.isEmpty) continue;
      break; // 音符段开始：头部结束。
    }
    final int colon = l.indexOf(':');
    if (colon < 0) continue;
    final String key = l.substring(1, colon).trim().toUpperCase();
    final String value = l.substring(colon + 1).trim();
    if (key == 'BPM') sawBpm = true;
    if ((key == 'AUDIO' || (key == 'MP3' && audio == null)) &&
        value.isNotEmpty) {
      audio = _baseName(value);
    }
  }
  return sawBpm ? audio : null;
}

/// 读多少字节判 UltraStar 头（头部都在文件开头几百字节内）。
const int kUltraStarHeadBytes = 4096;

/// 一个目录里最多看多少个 `.txt`（防止往大目录里逐个读文件）。
const int kUltraStarMaxCandidates = 32;

/// 同目录里可能是 UltraStar 歌曲文件的 `.txt`（主名与音频不同的那些；同名的已按 sidecar 认）。
List<String> ultraStarCandidates(String audioPath, Iterable<String> siblings) {
  final String audioName = _baseName(audioPath).toLowerCase();
  final int dot = audioName.lastIndexOf('.');
  final String stem = dot <= 0 ? audioName : audioName.substring(0, dot);
  return <String>[
    for (final String p in siblings)
      if (_baseName(p).toLowerCase().endsWith('.txt') &&
          !_baseName(p).toLowerCase().startsWith('$stem.'))
        p,
  ].take(kUltraStarMaxCandidates).toList();
}

/// CD+G（设计 §9.2）：音频旁同主名的 `.cdg` 图形轨（`song.mp3` + `song.cdg`，大小写不敏感）。
/// 纯函数；没有返回 null。`.zip` 打包的 MP3+G 不认（要先解包）。
String? pickCdgCompanion(String audioPath, Iterable<String> siblings) {
  final String audioName = _baseName(audioPath).toLowerCase();
  final int dot = audioName.lastIndexOf('.');
  if (dot <= 0 || audioName.endsWith('.cdg')) return null;
  final String want = '${audioName.substring(0, dot)}.cdg';
  for (final String p in siblings) {
    if (_baseName(p).toLowerCase() == want) return p;
  }
  return null;
}
