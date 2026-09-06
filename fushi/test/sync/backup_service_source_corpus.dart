import '../helpers/part_corpus.dart';

/// B1 分家：`backup_service.dart` 拆成主壳 + `backup_service/*.part.dart`
/// （`fs_retry` / `path_rebase` / `restore`）。这是本仓第 5 份「主壳 + part 目录」
/// 型语料。
///
/// 为什么必须接上磁盘枚举而不是各守卫自己 `read('...part.dart')`：备份/恢复域的
/// 静态守卫里有大量**负向**断言（「不得再 materialize 整个条目」「不得裸
/// writeAsBytes」「不得泄漏 device-local 表」）。负向断言的天然弱点是**语料少读一个
/// 文件照样绿**——不是被禁的写法真的没了，是根本没扫到那个文件。本 PR 刚把恢复链
/// 整体搬进 part，下一个人再往 `backup_service/` 加一个 part 时，任何硬编码文件名
/// 的守卫都会对它失明，而且没有任何反馈。
///
/// 路径从磁盘枚举 + 排序（跨机器/跨次运行顺序确定），新 part 自动进语料。
const String _backupServiceShell = 'lib/src/sync/backup_service.dart';
const String kBackupServicePartDir = 'lib/src/sync/backup_service';

/// 主壳 + 磁盘上全部 `*.part.dart`（按路径排序）。
List<String> backupServiceFiles() => partCorpusFiles(
      shell: _backupServiceShell,
      partDir: kBackupServicePartDir,
    );

/// 读「备份服务合并语料」：主壳 + 全部 part 拼成单个字符串，CRLF 归一成 LF。
String readBackupServiceSource() => readPartCorpus(backupServiceFiles());
