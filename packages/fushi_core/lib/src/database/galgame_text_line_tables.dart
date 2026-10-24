import 'package:drift/drift.dart';

import 'tables.dart' show Galgames;

// ── galgame_text_lines（schema v130，作品图谱 L4 跟进）──────────────────────
//
// 文本钩子收到的游戏台词。文本钩子的工作台历史只在会话内存里（`TexthookerService`
// 上限 500 行），这张表是台词**唯一的持久副本**：「我库里的例句」（native/fushi_corpus）
// 的游戏文档由它派生（与书 / 字幕 / 歌词一样可整库重建），备份随 `games` 类别走、合并
// 导入按 (游戏, 台词) 去重。所有者 2026-10-24 拍板：游戏台词要进备份，换设备 / 恢复
// 备份不能丢。
//
// 为什么进 DB 而不是把语料库文件打进备份：备份的类别裁剪（`backupTableRules`）、
// 合并导入的游戏身份重映射（`BackupMergeEngine._buildGameIdMap`：同 id / 同刮削 id /
// 同 exe 路径）都只作用于 DB 表；语料库文件是 Rust 的派生索引格式，按词典归一过，
// 换一套词典就要重建，不适合当交换格式。
//
// 去重键是 (game_id, text)：同一句台词（重读存档、回想模式）只留第一次收到的那一行——
// 例句索引要的是「这句话在这个游戏里出现过」，不是播放流水。
@DataClassName('GalgameTextLineRow')
class GalgameTextLines extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// 所属游戏（`galgames.id`）。游戏从库里移除时台词跟着删（ON DELETE CASCADE）：
  /// 台词是这个游戏的内容，不像游玩时长那样要留作统计。
  TextColumn get gameId =>
      text().references(Galgames, #id, onDelete: KeyAction.cascade)();

  /// 台词正文（文本钩子管线处理后的那一份：注音已剥、折叠后的整行）。
  TextColumn get lineText => text().named('text')();

  /// 第一次收到这句台词的时刻（毫秒时间戳）。
  IntColumn get receivedAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
    <Column>{gameId, lineText},
  ];
}
