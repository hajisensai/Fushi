import 'package:flutter_test/flutter_test.dart';

import '../helpers/part_corpus_disk_guard.dart';
import 'reader_history_source_corpus.dart';

/// 书架页「合并语料」自身的守卫（TODO-2707）。
///
/// 清单以前是手写常量：新增 / 改名一个 part 就正好制造「语料里没有它、而落在它里面的
/// 负向断言照样绿」的真空。清单已改成从磁盘枚举，本文件锁住这条契约。
///
/// 路径字面量在这里**故意再写一遍**，不从语料文件导入——见
/// `helpers/part_corpus_disk_guard.dart` 里「不要和被守对象共用同一个枚举」的说明。
void main() {
  group('书架页合并语料覆盖磁盘上的全部 part', () {
    test('主壳 + 每个 part 都在清单里、顺序确定（漏登记 = 负向断言真空通过）', () {
      expectPartManifestMatchesDisk(
        manifest: readerHistoryFiles(),
        shellPath:
            'lib/src/pages/implementations/reader_hibiki_history_page.dart',
        partDirPath: 'lib/src/pages/implementations/reader_history',
      );
    });

    test('每个 part 的内容真的进了语料（不只是路径进了清单）', () {
      expectPartContentsInCorpus(
        manifest: readerHistoryFiles(),
        corpus: readReaderHistorySource(),
      );
    });
  });
}
