import 'package:flutter_test/flutter_test.dart';

import '../helpers/part_corpus_disk_guard.dart';
import 'sync_settings_schema_source_corpus.dart';

/// 同步设置 schema「合并语料」自身的守卫（TODO-2707）。
///
/// 这份清单以前是手写常量，而且**实测已经漏过**：`data_root.part.dart` 从落地起就没进
/// 清单，落在它里面的负向断言（`isNot(contains(...))`）一直真空通过——不是被禁的写法
/// 真的没有，是根本没读到那个文件。清单已改成从磁盘枚举，本文件锁住这条契约。
///
/// 路径字面量在这里**故意再写一遍**，不从语料文件导入——见
/// `helpers/part_corpus_disk_guard.dart` 里「不要和被守对象共用同一个枚举」的说明。
void main() {
  group('同步设置 schema 合并语料覆盖磁盘上的全部 part', () {
    test('主壳 + 每个 part 都在清单里、顺序确定（漏登记 = 负向断言真空通过）', () {
      expectPartManifestMatchesDisk(
        manifest: syncSettingsSchemaFiles(),
        shellPath: 'lib/src/sync/sync_settings_schema.dart',
        partDirPath: 'lib/src/sync/sync_settings_schema',
      );
    });

    test('每个 part 的内容真的进了语料（不只是路径进了清单）', () {
      expectPartContentsInCorpus(
        manifest: syncSettingsSchemaFiles(),
        corpus: readSyncSettingsSchemaSource(),
      );
    });
  });
}
