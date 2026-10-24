import 'package:drift/drift.dart';

// ── 歌词生词覆盖率（schema v134，docs/specs/2026-10-23-music-module-design.md §12）──
//
// 曲库「按难度排序」要把每首歌的覆盖率落库，不能每次开曲库页都把整库歌词重新分词。
// 一首歌一行，分两段缓存，失效条件各自独立：
//
// - **分词段**（[MusicLyricCoverage.inputStamp] / [termsJson] / [totalTokens]）：整首歌词
//   一次 FFI（`fushidicts_tokenize_terms`）取出的词头与出现次数。输入指纹 = 词典集合签名
//   + 歌词解析器版本 + 曲目文件 mtime + 该曲 `music_lyrics` 各行内容摘要；任一项变了才
//   重新分词。
// - **已知段**（[knownTokens] / [knownStamp]）：复习库变了只重判「哪些词已进入复习队列」，
//   用存下来的词头重算，不碰词典、不碰歌词文件。
//
// 纯派生缓存：可整表删掉重算，装的是本机曲目 uid（含路径派生），设备本地、不进备份。

/// 曲目歌词的生词覆盖率缓存（一首歌一行）。
@DataClassName('MusicLyricCoverageRow')
class MusicLyricCoverage extends Table {
  TextColumn get trackUid => text()();

  /// `ok`（有词典命中的词）/ `no_lyrics`（本地没有歌词）/ `no_terms`（有歌词但一个
  /// 词典命中的词都没有，如纯外语 / 纯拟声）。
  TextColumn get status => text()();

  /// 分词段的输入指纹（见文件头）。
  TextColumn get inputStamp => text()();

  /// 去重后的词：`[[词头, 读音, 出现次数], …]`（JSON）。`status != ok` 时为 `[]`。
  TextColumn get termsJson => text().withDefault(const Constant('[]'))();

  /// 词典命中的词的出现次数合计（覆盖率分母）。
  IntColumn get totalTokens => integer().withDefault(const Constant(0))();

  /// 去重后的词数。
  IntColumn get uniqueTerms => integer().withDefault(const Constant(0))();

  /// 已知词的出现次数合计；null = 还没判过（复习模块关着 / 刚分完词）。
  IntColumn get knownTokens => integer().nullable()();

  /// 判 [knownTokens] 时复习库「已知词」快照的指纹；与当前快照不同即需重判。
  TextColumn get knownStamp => text().nullable()();

  /// 本行分词段最后一次计算的时刻（毫秒）。
  IntColumn get computedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{trackUid};
}
