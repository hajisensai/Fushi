import 'package:flutter_test/flutter_test.dart';

import '../helpers/part_corpus_disk_guard.dart';
import 'backup_service_source_corpus.dart';

/// 备份服务「合并语料」自身的守卫。
///
/// 备份/恢复域的静态守卫里带着这一批负向断言：「不得 materialize 整个条目再
/// writeAsBytes」「device-local 表不得进备份包」。它们全都是「语料少读一个文件就
/// 静默真空通过」的形状，而本域刚从单文件拆成主壳 + part 目录。
///
/// 路径字面量在这里**故意再写一遍**，不从语料文件导入——见
/// `helpers/part_corpus_disk_guard.dart` 里「不要和被守对象共用同一个枚举」的说明。
void main() {
  group('备份服务合并语料覆盖磁盘上的全部 part', () {
    test('主壳 + 每个 part 都在清单里、顺序确定（漏登记 = 负向断言真空通过）', () {
      expectPartManifestMatchesDisk(
        manifest: backupServiceFiles(),
        shellPath: 'lib/src/sync/backup_service.dart',
        partDirPath: 'lib/src/sync/backup_service',
      );
    });

    test('每个 part 的内容真的进了语料（不只是路径进了清单）', () {
      expectPartContentsInCorpus(
        manifest: backupServiceFiles(),
        corpus: readBackupServiceSource(),
      );
    });
  });
}
