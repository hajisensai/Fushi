import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';

/// 章节 HTML 流水线里与插图有关的两件事：
///   1. 生成章节 HTML 时去掉 `<img>` 的 `loading` 属性（分页几何要计入每张插图的真实
///      尺寸，懒图在远列永不加载会把章节算短、提前跨章）。
///   2. 预热下一章插图（承担不懒加载后的首开读图开销）有配额、跟随阅读方向。
void main() {
  final File webviewFile = File(
    'lib/src/pages/implementations/reader_fushi/webview.part.dart',
  );
  String webviewSrc() => webviewFile.readAsStringSync();

  test('章节 HTML 流水线去掉 <img> 的 loading 属性', () {
    final String body = methodBody(
      webviewSrc(),
      'Uint8List _buildSanitizedChapterHtmlBytes(',
    );
    expect(
      body.contains(
        'ReaderResourceSanitizer.stripImageLoadingAttributes(html)',
      ),
      isTrue,
      reason: '原书自带的 loading="lazy" 也必须去掉，否则分页几何塌缩、提前跨章',
    );
  });

  group('预热配额与阅读方向（PR#469 审查）', () {
    test('预热按张数 + 字节双封顶', () {
      final String src = webviewSrc();
      // 窗口=方法体（花括号配对），不再是 `idx + 1800`：该方法体实测 1483 字符，
      // 旧窗口越过方法末尾 317 字符读进下一个方法，两条配额断言可能命中错对象。
      final String body = methodBody(
        src,
        'void _prefetchAdjacentChapterImages(',
      );
      expect(
        body.contains('_kImagePrefetchMaxCount'),
        isTrue,
        reason: '预热必须有张数上限',
      );
      expect(
        body.contains('_kImagePrefetchMaxBytes'),
        isTrue,
        reason: '预热必须有字节上限（整页插图书的内存压力是实打实的）',
      );
    });

    test('预热跟随阅读方向，而不是写死 +1', () {
      final File navFile = File(
        'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
      );
      final String src = navFile.readAsStringSync().replaceAll(
        RegExp(r'\s+'),
        ' ',
      );
      // 格式无关：src 已折叠空白，但 tall style 折行会补出尾逗号
      // （`...direction, )`），判据只钉「预热实参是 当前章 + 方向」。
      expect(
        RegExp(
          r'_prefetchAdjacentChapterImages\(\s*_currentChapter\s*\+\s*_chapterAdvanceDirection\s*,?\s*\)',
        ).hasMatch(src),
        isTrue,
        reason: '倒着读时必须预热上一章，而不是刚离开的那一章',
      );
      expect(
        src.contains(
          '_chapterAdvanceDirection = chapter > _currentChapter ? 1 : -1;',
        ),
        isTrue,
        reason: '方向必须在唯一的导航采样点 _beginNavigation 更新',
      );
    });
  });
}
