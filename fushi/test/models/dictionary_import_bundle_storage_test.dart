// BUG-2952：词典导入导致 native 崩溃（磁盘写满 SIGBUS）与词典整合包。
//
// native 侧的根因与修复由 `native/fushidicts/tests/import_failure_boundary_test.cpp`
// 钉住（map_rw 预留块、异常边界、kanji 逐条容错）。这里钉 Dart 侧两件事：
//   1. 整合包判据：zip 里套 zip / 多份 index.json 都算一包多典，单本 Yomitan
//      包仍不拆；
//   2. native 用稳定标记 `FUSHI_ERR_STORAGE_FULL` 报「卷空间不足」，Dart 把它换成
//      可读文案；标记必须与 native 头文件逐字一致。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_import_manager.dart';
import 'package:fushi/utils.dart';

void main() {
  group('BUG-2952 整合包判据', () {
    test('zip 里套多个词典 zip（用户的「英语词典整理」形态）= 整合包，逐个算一本', () {
      final List<String> entries =
          DictionaryImportManager.archivedDictionaryEntries(<String>[
            '英语词典整理/',
            '英语词典整理/01_英汉学习词典/',
            '英语词典整理/01_英汉学习词典/cobuild10.zip',
            '英语词典整理/01_英汉学习词典/oald10_yomitan_v3.3.0.zip',
            '英语词典整理/03_短语与习语/牛津英语习语词典.zip',
            '英语词典整理/04_词频/coca60k_freq_yomitan.zip',
          ]);
      expect(entries.length, 4);
      expect(DictionaryImportManager.isDictionaryBundle(entries), isTrue);
    });

    test('只套了一个内层 zip 也必须解开：native 不会递归进内层 zip', () {
      final List<String> entries =
          DictionaryImportManager.archivedDictionaryEntries(<String>[
            'wrapper/',
            'wrapper/real_dictionary.zip',
          ]);
      expect(entries, <String>['wrapper/real_dictionary.zip']);
      expect(DictionaryImportManager.isDictionaryBundle(entries), isTrue);
    });

    test('根下多个子目录各带 index.json = 每个目录一本', () {
      final List<String> entries =
          DictionaryImportManager.archivedDictionaryEntries(<String>[
            'jmdict/index.json',
            'jmdict/term_bank_1.json',
            'kanjidic/index.json',
            'kanjidic/kanji_bank_1.json',
          ]);
      expect(entries, <String>['jmdict/index.json', 'kanjidic/index.json']);
      expect(DictionaryImportManager.isDictionaryBundle(entries), isTrue);
    });

    test('单本 Yomitan 包（一份 index.json + 几十个 bank）不是整合包', () {
      final List<String> entries =
          DictionaryImportManager.archivedDictionaryEntries(<String>[
            'index.json',
            'term_bank_1.json',
            'term_bank_2.json',
            'kanji_bank_1.json',
          ]);
      expect(entries, isEmpty);
      expect(DictionaryImportManager.isDictionaryBundle(entries), isFalse);
    });

    test('单本 MDX 不是整合包（行为与 BUG-1903 之前一致）', () {
      final List<String> entries =
          DictionaryImportManager.archivedDictionaryEntries(<String>[
            'oid/oid.mdx',
            'oid/oid.mdd',
            'oid/oid.css',
          ]);
      expect(DictionaryImportManager.isDictionaryBundle(entries), isFalse);
    });

    test('整合包的逐本导入同时认内层 zip 与多份 index.json 目录，且递归层不复用外层工作目录', () {
      final String src = File(
        'lib/src/models/dictionary_import_manager.dart',
      ).readAsStringSync();
      expect(
        src.contains("ext == '.mdx' || ext == '.dsl' || ext == '.zip'"),
        isTrue,
      );
      expect(
        src.contains('packDirectoryToZip(root, packed, skipPaths: skipPaths)'),
        isTrue,
      );
      expect(
        src.contains("Directory('\${archive.path}.extracted')"),
        isTrue,
        reason: '内层 zip 自己也是整合包时会递归；共用固定工作目录会删掉外层正在逐本导入的解压结果',
      );
      expect(
        src.contains('t.dict_import_bundle_detected(n: dictionaries.length)'),
        isTrue,
      );
    });
  });

  group('BUG-2952 存储空间不足的错误回传', () {
    test('带标记的 native 错误换成可读文案', () {
      expect(
        DictionaryImportManager.nativeImportErrorMessage(
          'FUSHI_ERR_STORAGE_FULL\nfailed to create hash table: No space left on device',
        ),
        t.dict_import_storage_full,
      );
    });

    test('其它错误原样回传，空错误退回通用文案', () {
      expect(
        DictionaryImportManager.nativeImportErrorMessage(
          'failed to parse index.json',
        ),
        'failed to parse index.json',
      );
      expect(
        DictionaryImportManager.nativeImportErrorMessage(''),
        t.import_failed,
      );
    });

    test('Dart 侧标记与 native kStorageFullMarker 逐字一致', () {
      final String header = File(
        '../native/fushidicts/fushidicts_include/fushidicts/importer.hpp',
      ).readAsStringSync();
      expect(
        header.contains(
          'kStorageFullMarker = "${DictionaryImportManager.kNativeStorageFullMarker}"',
        ),
        isTrue,
        reason: '两边各写一份字符串，改一边不改另一边，满盘失败就退回成看不懂的 iostream 报错',
      );
    });

    test('两个 native 导入入口都经 nativeImportErrorMessage 出错', () {
      final String src = File(
        'lib/src/models/dictionary_import_manager.dart',
      ).readAsStringSync();
      expect(
        'throw Exception(nativeImportErrorMessage(result.error));'
            .allMatches(src)
            .length,
        2,
      );
    });
  });
}
