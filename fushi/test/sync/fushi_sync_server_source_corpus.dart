import '../helpers/part_corpus.dart';

/// B3（2026-09 同步/互联重构）：`fushi_sync_server.dart` 被拆成主库 +
/// `fushi_sync_server/*.part.dart` 一组按域 part（auth / pairing / lookup /
/// library / video / sync_state / webdav）。`_handleRequest` 路由表、生命周期、
/// 公开回调和值类型留在主库，各域 handler 搬进 part（同一 library 的私有作用域，
/// 方法逐字不动；extension 体内看不到宿主类 static，故 private static helper 提到
/// 库顶层）。
///
/// 原来读单文件的静态守卫改读这份「合并语料」：主库 + 磁盘枚举的全部 part 文件按
/// 路径排序拼接（同 [readSyncSettingsSchemaSource] 的理由：手写 part 清单实测会漏，
/// 漏掉的 part 里负向断言真空通过）。
const String _fushiSyncServerShell = 'lib/src/sync/fushi_sync_server.dart';
const String kFushiSyncServerPartDir = 'lib/src/sync/fushi_sync_server';

/// 主库 + 磁盘上全部 `*.part.dart`（按路径排序）。
List<String> fushiSyncServerFiles() => partCorpusFiles(
      shell: _fushiSyncServerShell,
      partDir: kFushiSyncServerPartDir,
    );

/// 读「互联服务器合并语料」：主库 + 全部 part 拼成单个字符串，换行统一成 '\n'。
String readFushiSyncServerSource() => readPartCorpus(fushiSyncServerFiles());
