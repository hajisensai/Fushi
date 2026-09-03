// BUG-1903 / BUG-1904：用户把「日语辞典三件套」打成一个 zip 拖进来，报「不支持」。
//
// 实测（真引擎，用户原包）：
//   整包导入  → success=true title="旺文社国語辞典［第十一版］" term=219343
//              ——三本只进了一本，岩波与大辞林**静默丢弃**，还报成功。
//   逐本导入  → 岩波 189782 / 旺文社 219343 / 大辞林 1000000（正好卡上限）
//   MDX 头声明 → 岩波 189782 / 旺文社 220573 / 大辞林 1086308
//
// 于是两条根因各自成一条 bug：
//   BUG-1903 一包多典只进第一本（本文件前两组）
//   BUG-1904 大辞林被 kMaxEntriesPerBank 砍掉 86308 条（本文件第三组）
//
// 顺带排除掉两个看着像但不是的原因：`Encrypted=2`（旺文社正文 / 岩波 mdd）只是
// key-block-info 混淆，引擎自带 RIPEMD-128 解法、无需注册码；日文文件名也正常。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_import_manager.dart';

void main() {
  group('BUG-1903 判据：什么算「一包多典」', () {
    test('两本 MDX = 两本词典', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          'iwanami/iwanami.mdx',
          'iwanami/iwanami.css',
          'daijirin/daijirin.mdx',
          'daijirin/daijirin.mdd',
        ]),
        <String>['iwanami/iwanami.mdx', 'daijirin/daijirin.mdx'],
      );
    });

    test('用户那一包正是三本（岩波 / 旺文社 / 大辞林）', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          '岩波国語辞典8/iwakoku.css',
          '岩波国語辞典8/岩波国語辞典.mdd',
          '岩波国語辞典8/岩波国語辞典.mdx',
          '旺文社/obs.css',
          '旺文社/旺文社国語辞典［第十一版］.mdx',
          '三省堂 大辞林 [第三版]/daijirin2.css',
          '三省堂 大辞林 [第三版]/daijirin2.ddb',
          '三省堂 大辞林 [第三版]/daijirin2.mdd',
          '三省堂 大辞林 [第三版]/daijirin2.mdx',
        ]).length,
        3,
      );
    });

    test('Yomitan 包有几十个 term_bank 也只是一本，绝不能按文件数拆', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          'index.json',
          'term_bank_1.json',
          'term_bank_2.json',
          'term_bank_3.json',
          'tag_bank_1.json',
        ]),
        isEmpty,
        reason: '按 json 文件数拆会把一本 Yomitan 词典拆成几十本',
      );
    });

    test('单本 MDX 不触发拆包（长度 1，走原路径）', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          'daijirin2.mdx',
          'daijirin2.mdd',
          'daijirin2.css',
        ]).length,
        1,
      );
    });

    test('DSL 同样是一文件一典', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          'a/a.dsl',
          'b/b.dsl',
        ]).length,
        2,
      );
    });

    test('mdd / ddb / png 是资源，不算词典', () {
      expect(
        DictionaryImportManager.archivedDictionaryEntries(<String>[
          'x/x.mdd',
          'x/x.ddb',
          'x/x.png',
          'x/x.css',
        ]),
        isEmpty,
      );
    });
  });

  group('BUG-1903 接线：分流真的挂在导入入口上', () {
    final String src = File(
      'lib/src/models/dictionary_import_manager.dart',
    ).readAsStringSync();

    test('importFromFile 里按判据分流到逐本导入', () {
      expect(
        src.contains('archivedDictionaryEntries(_readZipFileNames(file))'),
        isTrue,
      );
      expect(src.contains('_importArchivedDictionaries('), isTrue);
      expect(
        src.contains('if (archived.length > 1) {'),
        isTrue,
        reason: '只有真的多于一本才拆；单本必须走原路径，行为不变',
      );
    });

    test('三个「更新某一本」的入口不拆包', () {
      expect(
        src.contains(
          'if (replaceTarget == null &&\n'
          '        !forceReplaceExisting &&\n'
          '        sourceOverride == null &&',
        ),
        isTrue,
        reason:
            '强制重导 / 来源回填 / 显式替换目标的语义是「用这个包替换那一本」，'
            '拆包会把一次更新变成多次追加',
      );
    });

    test('每本只带同目录的 css，且单本失败不中断其余', () {
      expect(
        src.contains('Directory(path.dirname(dictionary.path))'),
        isTrue,
        reason: 'MDX 的样式表就在它自己那本的目录里，摊平会让 A 典样式套到 B 典头上',
      );
      expect(
        src.contains("ErrorLogService.instance.log('DictImport.multiArchive'"),
        isTrue,
      );
      expect(src.contains('failedNames.add('), isTrue);
    });

    test('临时解压目录在 finally 里清掉', () {
      expect(src.contains('import_multi_temp'), isTrue);
      expect(src.contains('} finally {'), isTrue);
    });
  });

  group('BUG-1904：整词典流不该套用 per-bank 上限', () {
    final String importer = File(
      '../native/fushidicts/fushidicts_src/importer.cpp',
    ).readAsStringSync();

    test('simple entries（MDX/DSL 整本词典流）用 kMaxTotalEntries 而非 per-bank', () {
      final int at = importer.indexOf('ProcessedFile process_simple_entries(');
      expect(at, greaterThan(0), reason: '函数不在了，守卫需更新');
      final String body = importer.substring(at, at + 2000);
      expect(
        body.contains('processed.count >= kMaxTotalEntries'),
        isTrue,
        reason:
            '大辞林第四版声明 1086308 条，per-bank 的 100 万上限会把它砍到'
            '正好 1000000 还报 success；整词典级别的上限应当是 kMaxTotalEntries',
      );
      expect(
        body.contains('processed.count >= kMaxEntriesPerBank'),
        isFalse,
        reason:
            'kMaxEntriesPerBank 是给 Yomitan 单个 term_bank_N.json 设计的，'
            '同一个常量套到整词典流上语义就错位了',
      );
    });

    test('另外两道 OOM 保护仍在（不是把闸门全拆了）', () {
      expect(importer.contains('kMaxDataBufferBytes'), isTrue);
      expect(importer.contains('kMaxGlossarySizeBytes'), isTrue);
      expect(
        importer.contains(
          "static constexpr size_t kMaxTotalEntries = 10'000'000;",
        ),
        isTrue,
        reason: '整词典上限本身必须还是个有限值',
      );
    });

    test('per-bank 上限对 Yomitan 的三条 bank 路径原样保留', () {
      expect(
        'processed.count >= kMaxEntriesPerBank'.allMatches(importer).length,
        3,
        reason:
            'term / meta / kanji 三条 bank 路径仍该用 per-bank 上限——'
            '那里的语义是对的，本次只改整词典流那一处',
      );
    });
  });
}
