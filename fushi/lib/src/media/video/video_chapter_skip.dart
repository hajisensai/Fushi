/// 「跳过片头 / 片尾」：章节标题判据（纯函数）。
///
/// 番剧 / 剧集的 mkv 常带命名章节（`OP` / `Opening` / `オープニング` /
/// `ED` / `Ending` / `Credits` …）。当前播放位置落在这类章节、且后面还有下一章时，
/// 播放页在画面右下角给一枚「跳过片头 / 片尾」按钮，按下 = 跳到下一章开头
/// （与 `videoNextChapter` 快捷键同一条路径）。没有章节数据或章节名不像片头片尾
/// 时什么都不出现——这是被动提示，不需要开关。
library;

/// 可跳过的章节种类。
enum VideoSkippableChapter { opening, ending }

final RegExp _openingPattern = RegExp(
  r'^(?:op(?:ening)?|intro(?:duction)?|opening\s*(?:song|theme|credits)?|'
  r'オープニング|前奏|片头|片頭|主题曲|主題歌|ＯＰ)(?:\s*[\d０-９]+)?$',
  caseSensitive: false,
);

final RegExp _endingPattern = RegExp(
  r'^(?:ed|ending|outro|credits|end\s*credits|ending\s*(?:song|theme|credits)?|'
  r'エンディング|片尾|片尾曲|ＥＤ)(?:\s*[\d０-９]+)?$',
  caseSensitive: false,
);

/// 章节标题像片头 / 片尾时返回种类，否则 null。只认**整个标题**是这类词（可带
/// 序号，如 `OP2`），「Episode Preview」「Part A」之类正片章节不会误判。
VideoSkippableChapter? videoSkippableChapterKind(String title) {
  final String t = title.trim();
  if (t.isEmpty) return null;
  if (_openingPattern.hasMatch(t)) return VideoSkippableChapter.opening;
  if (_endingPattern.hasMatch(t)) return VideoSkippableChapter.ending;
  return null;
}
