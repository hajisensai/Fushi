import 'package:flutter_test/flutter_test.dart';

import '../helpers/part_corpus_disk_guard.dart';
import 'sync_orchestrator_source_corpus.dart';

/// 同步编排器「合并语料」自身的守卫。
///
/// 本仓另外 4 份 part 型语料 4/4 都配了这一份，理由写在
/// `helpers/part_corpus_disk_guard.dart` 的文件头：语料少读一个文件，读它的**负向**
/// 断言照样绿——不是被禁的写法真的没了，是根本没扫到。而这份语料已经有活的负向
/// 消费方（`server_lifecycle_appmodel_guard_test` 的 `if (syncLocalAudio` 那条）。
///
/// 生产侧 [partCorpusFiles] 按 `*.part.dart` 后缀过滤，所以「`part of` 了但没按
/// `.part.dart` 命名」的新文件会被静默跳过；该 helper 的基准刻意放宽成全部 `.dart`
/// 就是为了堵这条。路径字面量在这里**故意再写一遍**，不从语料文件 import——守卫和
/// 被守对象共用同一个枚举时，那个枚举的缺陷会让双方在同一处同时失明。
void main() {
  group('同步编排器合并语料覆盖磁盘上的全部 part', () {
    test('主壳 + 每个 part 都在清单里、顺序确定（漏登记 = 负向断言真空通过）', () {
      expectPartManifestMatchesDisk(
        manifest: syncOrchestratorFiles(),
        shellPath: 'lib/src/sync/sync_orchestrator.dart',
        partDirPath: 'lib/src/sync/sync_orchestrator',
      );
    });

    test('每个 part 的内容真的进了语料（不只是路径进了清单）', () {
      expectPartContentsInCorpus(
        manifest: syncOrchestratorFiles(),
        corpus: readSyncOrchestratorSource(),
      );
    });
  });
}
