import 'package:flutter_test/flutter_test.dart';

import '../helpers/part_corpus_disk_guard.dart';
import 'local_library_host_service_source_corpus.dart';

/// 本机库 host 服务「合并语料」自身的守卫。
///
/// 本仓 part 型语料的既有约定是「一份语料配一份磁盘一致性守卫」，理由写在
/// `helpers/part_corpus_disk_guard.dart` 的文件头：语料少读一个文件，读它的**负向**
/// 断言照样绿——不是被禁的写法真的没了，是根本没扫到。而这份语料已经有活的负向
/// 消费方（BUG-814 那条 `isNot(contains('listEmbeddedSubtitleTracks'))`，B4 正是
/// 为了让它别在 `listVideos` 搬进 part 后真空通过才改读合并语料的）。
///
/// 生产侧 [partCorpusFiles] 按 `*.part.dart` 后缀过滤，所以「`part of` 了但没按
/// `.part.dart` 命名」的新文件会被静默跳过；该 helper 的基准刻意放宽成全部 `.dart`
/// 就是为了堵这条。路径字面量在这里**故意再写一遍**，不从语料文件 import——守卫和
/// 被守对象共用同一个枚举时，那个枚举的缺陷会让双方在同一处同时失明。
void main() {
  group('本机库 host 服务合并语料覆盖磁盘上的全部 part', () {
    test('主壳 + 每个 part 都在清单里、顺序确定（漏登记 = 负向断言真空通过）', () {
      expectPartManifestMatchesDisk(
        manifest: localLibraryHostServiceFiles(),
        shellPath: 'lib/src/sync/local_library_host_service.dart',
        partDirPath: 'lib/src/sync/local_library_host_service',
      );
    });

    test('每个 part 的内容真的进了语料（不只是路径进了清单）', () {
      expectPartContentsInCorpus(
        manifest: localLibraryHostServiceFiles(),
        corpus: readLocalLibraryHostServiceSource(),
      );
    });
  });
}
