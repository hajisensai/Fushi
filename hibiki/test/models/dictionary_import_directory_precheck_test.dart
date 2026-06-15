import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/dictionary_import_manager.dart';
import 'package:path/path.dart' as path;

/// TODO-379 / BUG 守卫：「导入文件夹词典」选了一个**没有任何词典、只混了无关
/// 文件**（如 QQ 下载的随机名 `879-11f1-ab07-7df86a9e5503.conf`）的目录时，旧实现
/// 会把整个目录无脑打包丢给 native，让用户看到一句含糊的「导入失败」。
///
/// 修复：在整目录打包前用 [DictionaryImportManager.directoryContainsImportableDictionary]
/// 做一次递归预检——目录里没有 `index.json` / 任意 `.json` 词典主文件时返回 false，
/// 调用方据此抛明确的「无法识别的词典格式」。这套用例锁住该谓词：
/// - 真词典目录（顶层 / 子目录里有 index.json 或散 .json）→ true（不能误杀）。
/// - 只有无关文件（.conf 等、无 .json）→ false（用户的失败场景）。
void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('hibiki_dict_precheck_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  File touch(Directory dir, String name, [String body = '{}']) {
    dir.createSync(recursive: true);
    final File f = File(path.join(dir.path, name))..writeAsStringSync(body);
    return f;
  }

  group('DictionaryImportManager.directoryContainsImportableDictionary', () {
    test('顶层有 index.json 的 yomitan 目录 → true', () {
      touch(tempRoot, 'index.json');
      touch(tempRoot, 'term_bank_1.json');
      expect(
        DictionaryImportManager.directoryContainsImportableDictionary(tempRoot),
        isTrue,
      );
    });

    test('词典在子目录里（嵌套）→ true（不能因只看顶层而误杀）', () {
      final Directory sub = Directory(path.join(tempRoot.path, 'mydict'));
      touch(sub, 'index.json');
      // 顶层只放一个无关文件，模拟用户把解压目录又套了一层。
      touch(tempRoot, '879-11f1-ab07-7df86a9e5503.conf', 'binary');
      expect(
        DictionaryImportManager.directoryContainsImportableDictionary(tempRoot),
        isTrue,
      );
    });

    test('只有散 .json（migaku 路径）→ true', () {
      touch(tempRoot, 'something.json');
      expect(
        DictionaryImportManager.directoryContainsImportableDictionary(tempRoot),
        isTrue,
      );
    });

    test('真词典 + 混入无关 .conf → 仍 true（无关文件不影响识别）', () {
      touch(tempRoot, 'index.json');
      touch(tempRoot, '879-11f1-ab07-7df86a9e5503.conf', 'noise');
      expect(
        DictionaryImportManager.directoryContainsImportableDictionary(tempRoot),
        isTrue,
      );
    });

    test('用户场景：目录里只有一个无关 .conf 文件 → false', () {
      touch(tempRoot, '879-11f1-ab07-7df86a9e5503.conf', 'noise');
      expect(
        DictionaryImportManager.directoryContainsImportableDictionary(tempRoot),
        isFalse,
      );
    });

    test('目录里全是非 json 杂项（.txt/.png/.conf）→ false', () {
      touch(tempRoot, 'readme.txt', 'hi');
      touch(tempRoot, 'cover.png', 'png');
      touch(tempRoot, 'config.conf', 'noise');
      expect(
        DictionaryImportManager.directoryContainsImportableDictionary(tempRoot),
        isFalse,
      );
    });

    test('空目录 → false', () {
      expect(
        DictionaryImportManager.directoryContainsImportableDictionary(tempRoot),
        isFalse,
      );
    });
  });
}
