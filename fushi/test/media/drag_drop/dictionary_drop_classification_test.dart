import 'package:test/test.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/models/dictionary_import_manager.dart';

/// TODO-059: 词典管理页拖放导入。验证拖入文件 -> 词典包筛选的纯逻辑
/// （[classifyDroppedFilesForDictionary]）：词典包识别、css 样式附件随带、
/// 大小写不敏感、无词典包时不导入。
void main() {
  group('classifyDroppedFilesForDictionary', () {
    test('zip / dsl / mdx 被收为词典包导入路径', () {
      final List<String> r = classifyDroppedFilesForDictionary(<String>[
        '/x/a.zip',
        '/x/b.dsl',
        '/x/c.mdx',
      ]);
      expect(r, <String>['/x/a.zip', '/x/b.dsl', '/x/c.mdx']);
    });

    test('同批拖入的 css 作为样式附件排在词典包之后', () {
      final List<String> r = classifyDroppedFilesForDictionary(<String>[
        '/x/style.css',
        '/x/dict.zip',
      ]);
      // 词典包在前，css 附件在后。
      expect(r, <String>['/x/dict.zip', '/x/style.css']);
    });

    test('没有词典包时返回空（单拖 css 不构成导入）', () {
      expect(
        classifyDroppedFilesForDictionary(<String>['/x/style.css']),
        isEmpty,
      );
    });

    test('非词典文件（视频/字幕/书）被过滤掉', () {
      final List<String> r = classifyDroppedFilesForDictionary(<String>[
        '/x/movie.mp4',
        '/x/sub.srt',
        '/x/book.epub',
        '/x/d.zip',
      ]);
      expect(r, <String>['/x/d.zip']);
    });

    test('大小写不敏感', () {
      final List<String> r = classifyDroppedFilesForDictionary(<String>[
        '/x/A.ZIP',
        '/x/S.CSS',
      ]);
      expect(r, <String>['/x/A.ZIP', '/x/S.CSS']);
    });

    test('.7z / .rar 词典压缩包与选文件按钮一致，被收为词典包（拍板 design-dict-drop-7z-rar）', () {
      final List<String> r = classifyDroppedFilesForDictionary(<String>[
        '/x/style.css',
        '/x/a.7z',
        '/x/B.RAR',
      ]);
      expect(r, <String>['/x/a.7z', '/x/B.RAR', '/x/style.css']);
    });

    test('只有 .7z / .rar 加 css 时同样构成一次导入', () {
      expect(classifyDroppedFilesForDictionary(<String>['/x/a.rar']), <String>[
        '/x/a.rar',
      ]);
    });

    test('分卷 / 漫画载体 / URL 不被当成词典包', () {
      expect(
        classifyDroppedFilesForDictionary(<String>[
          '/x/a.7z.001',
          '/x/b.cbr',
          '/x/c.cb7',
          'https://example.com/d.zip',
        ]),
        isEmpty,
      );
    });

    test('拖放收的压缩包 = 导入器先解包再判定的扩展名（防漂移）', () {
      expect(
        kDictionarySurfaceArchiveExtensions,
        DictionaryImportManager.kUnpackFirstDictionaryExtensions
            .map((String e) => e.substring(1))
            .toSet(),
      );
      expect(
        kDictionarySurfaceDropExtensions,
        containsAll(kDragDictionaryExtensions),
      );
    });

    test('空输入返回空', () {
      expect(classifyDroppedFilesForDictionary(const <String>[]), isEmpty);
    });
  });
}
