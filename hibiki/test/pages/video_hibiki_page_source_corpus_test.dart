import 'package:flutter_test/flutter_test.dart';

import '../helpers/part_corpus_disk_guard.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 视频页「合并语料」自身的守卫（TODO-2707）。
///
/// 这份清单以前是手写常量，而且**实测已经漏过两个**：`flicker_notice.part.dart` 与
/// `quality.part.dart` 落地后没人回来补清单，落在它们里面的负向断言
/// （`isNot(contains(...))`）一直真空通过。清单已改成从磁盘枚举，本文件锁住这条契约。
///
/// 路径字面量在这里**故意再写一遍**，不从语料文件导入——见
/// `helpers/part_corpus_disk_guard.dart` 里「不要和被守对象共用同一个枚举」的说明。
void main() {
  group('视频页合并语料覆盖磁盘上的全部 part', () {
    test('主壳 + 每个 part 都在清单里、顺序确定（漏登记 = 负向断言真空通过）', () {
      expectPartManifestMatchesDisk(
        manifest: videoHibikiPageFiles(),
        shellPath: 'lib/src/pages/implementations/video_hibiki_page.dart',
        partDirPath: 'lib/src/pages/implementations/video_hibiki',
      );
    });

    test('每个 part 的内容真的进了语料（不只是路径进了清单）', () {
      expectPartContentsInCorpus(
        manifest: videoHibikiPageFiles(),
        corpus: readVideoHibikiSource(),
      );
    });
  });
}
