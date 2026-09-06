import '../helpers/part_corpus.dart';

/// B2（2026-09 同步/互联重构）：`sync_orchestrator.dart` 被拆成主库 +
/// `sync_orchestrator/*.part.dart` 一组按域 part（aggregate / collections /
/// tombstones / books / videos / audiobooks / dictionaries / local_audio）。
/// 公开入口与 `run()` 留在主库，各域 `_sync*Live` 等私有实现搬进 part（同一
/// library 的私有作用域，方法逐字不动）。
///
/// 原来读单文件的静态守卫改读这份「合并语料」：主库 + 磁盘枚举的全部 part 文件按
/// 路径排序拼接（同 [readSyncSettingsSchemaSource] 的理由：手写 part 清单实测会漏，
/// 漏掉的 part 里负向断言真空通过）。
const String _syncOrchestratorShell = 'lib/src/sync/sync_orchestrator.dart';
const String kSyncOrchestratorPartDir = 'lib/src/sync/sync_orchestrator';

/// 主库 + 磁盘上全部 `*.part.dart`（按路径排序）。
List<String> syncOrchestratorFiles() => partCorpusFiles(
      shell: _syncOrchestratorShell,
      partDir: kSyncOrchestratorPartDir,
    );

/// 读「同步编排器合并语料」：主库 + 全部 part 拼成单个字符串，换行统一成 '\n'。
String readSyncOrchestratorSource() => readPartCorpus(syncOrchestratorFiles());
