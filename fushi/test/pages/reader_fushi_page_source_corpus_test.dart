import 'package:flutter_test/flutter_test.dart';

import '../helpers/part_corpus_disk_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// 阅读器页「合并语料」自身的守卫。
///
/// 90+ 个静态守卫读 [readReaderPageSource]，其中 25 个文件里带 `isNot(contains(...))`
/// 这类**负向**断言。负向断言有个天然弱点：语料少读一个文件，它照样绿——不是符号真的
/// 没了，是根本没扫到。清单以前是手写常量，新增 / 改名一个 part 就正好制造这种真空。
///
/// 清单已改成从磁盘枚举，本文件锁住这条契约：磁盘上每个 part 都必须真的进语料。
///
/// 路径字面量在这里**故意再写一遍**，不从语料文件导入——见
/// `helpers/part_corpus_disk_guard.dart` 里「不要和被守对象共用同一个枚举」的说明。
void main() {
  group('阅读器页合并语料覆盖磁盘上的全部 part', () {
    test('主壳 + 每个 part 都在清单里、顺序确定（漏登记 = 负向断言真空通过）', () {
      expectPartManifestMatchesDisk(
        manifest: readerFushiPageFiles(),
        shellPath: 'lib/src/pages/implementations/reader_fushi_page.dart',
        partDirPath: 'lib/src/pages/implementations/reader_fushi',
      );
    });

    test('每个 part 的内容真的进了语料（不只是路径进了清单）', () {
      expectPartContentsInCorpus(
        manifest: readerFushiPageFiles(),
        corpus: readReaderPageSource(),
      );
    });
  });
}
