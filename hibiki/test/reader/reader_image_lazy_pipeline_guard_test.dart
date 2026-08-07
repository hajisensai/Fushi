import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_resource_sanitizer.dart';
import '../helpers/source_guard.dart';

/// BUG-1140 第二轮守卫：`loading` 属性的**Dart 侧**流水线。
///
/// 为什么单独一条守卫：仓库里三条既有图片守卫
/// （`image_chapter_lazy_load_guard_test` / `merged_image_eager_guard_test` /
/// `prev_chapter_landing_guard_test`）**全是扫 `reader_pagination_scripts.dart` 这份 JS
/// 源码**的。BUG-1140 第二轮把「哪些图挂 lazy」的判定提前到 Dart 侧
/// （`webview.part.dart` → `ReaderResourceSanitizer.markImagesLazy`），因为属性只有写进
/// HTML 源码才对**本次**加载生效。于是同一条业务规则有了第二份实现，而那三条守卫对它
/// 一个字都管不到 —— 改坏了 CI 照样全绿。这条守卫补的就是这个洞。
///
/// 钉三件事：
///   1. 合并前导插图（TODO-1339）必须自带显式 `loading="eager"`，让「保持 eager」不再
///      依赖 `markImagesLazy` 与 `_injectMergedChapterImages` 的**调用顺序**。
///   2. `markImagesLazy` 尊重已有 `loading=`（第 1 条成立的另一半）。
///   3. 调用顺序本身仍锁住（第二道防线：万一有人删了显式 eager，顺序还在）。
void main() {
  final File webviewFile = File(
    'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
  );
  String webviewSrc() => webviewFile.readAsStringSync();

  /// 去掉 `//` 行注释再扫——否则「注释里写了 `loading="eager"`」也能让守卫变绿，
  /// 而真正 emit 的标签已经没有这个属性了（本守卫的负向验证踩过这个坑）。
  String stripLineComments(String s) => maskCommentsAndScriptLines(s);

  group('TODO-1339：合并前导插图的 eager 不再靠调用顺序', () {
    test('_injectMergedChapterImages 注入的 <img> 自带 loading="eager"', () {
      final String src = webviewSrc();
      final int injectIdx = src.indexOf('String _injectMergedChapterImages(');
      expect(injectIdx, isNonNegative, reason: '合并注入方法必须存在');
      final int endIdx = src.indexOf('String? _chapterFilePath(', injectIdx);
      expect(endIdx, greaterThan(injectIdx));
      final String body = stripLineComments(src.substring(injectIdx, endIdx));
      expect(body.contains('class="hoshi-merged-image"'), isTrue,
          reason: 'JS 侧靠这个 marker 放行，两端接线必须一致');
      expect(body.contains('loading="eager"'), isTrue,
          reason: '注入的前导插图必须显式 eager —— 否则 eager 只由调用顺序保证，'
              '谁调换顺序 TODO-1339 就复活而三条 JS 守卫全绿');
    });

    test('markImagesLazy 跳过显式 loading="eager"（顺序无关的另一半）', () {
      const String merged = '<body><div class="hoshi-merged-image">'
          '<img src="hoshi://a.png" class="block-img" loading="eager"/>'
          '</div><p>本文</p><img src="b.png"/></body>';
      final String out = ReaderResourceSanitizer.markImagesLazy(merged);
      // 前导插图原样保留 eager；正文普通插图仍挂 lazy（不回退 TODO-1074）。
      expect(out, contains('class="block-img" loading="eager"'));
      expect(
          out, isNot(contains('loading="lazy" decoding="async" src="hoshi:')));
      expect('loading="lazy"'.allMatches(out).length, 1,
          reason: '只有正文那张普通插图该被挂 lazy');
    });

    test('顺序仍锁住（第二道防线）：markImagesLazy 早于 _injectMergedChapterImages', () {
      final String src = webviewSrc();
      final int buildIdx =
          src.indexOf('Uint8List _buildSanitizedChapterHtmlBytes(');
      expect(buildIdx, isNonNegative);
      final int endIdx =
          src.indexOf('String _injectMergedChapterImages(', buildIdx);
      expect(endIdx, greaterThan(buildIdx));
      final String body = src.substring(buildIdx, endIdx);
      final int lazyIdx =
          body.indexOf('ReaderResourceSanitizer.markImagesLazy(');
      final int injectIdx = body.indexOf('_injectMergedChapterImages(html');
      expect(lazyIdx, isNonNegative, reason: 'Dart 侧 lazy 标记必须接在净化流水线里');
      expect(injectIdx, isNonNegative);
      expect(lazyIdx, lessThan(injectIdx),
          reason: 'markImagesLazy 必须先于 _injectMergedChapterImages');
    });
  });

  group('Dart 侧 eager 集合与 JS 侧不倒挂', () {
    test('eagerAll 绑定纯图片章判定（TODO-1349 几何要靠插图真实撑开）', () {
      final String src = webviewSrc();
      // 窗口=这次调用的实参表（圆括号配对），不再是 `lazyIdx + 200` 的定长切片：
      // 实参一旦换行/多传一个参数就把 `eagerAll:` 挤出旧窗口凭空变红。锚点取 `(` 之后
      // 的第一个字符，enclosingCall 于是返回 markImagesLazy 这一层调用本身（而不是包在
      // 外面的那层）；再断 call.name 自证窗口锚对了对象。
      const String anchor = 'ReaderResourceSanitizer.markImagesLazy(';
      final int lazyIdx = src.indexOf(anchor);
      expect(lazyIdx, isNonNegative);
      final EnclosingCall call = enclosingCall(src, lazyIdx + anchor.length);
      expect(call.name, 'ReaderResourceSanitizer.markImagesLazy',
          reason: '窗口必须正好是 markImagesLazy 这一层调用');
      expect(call.text.contains('eagerAll: _isImageOnlyChapterCached('), isTrue,
          reason: '纯图片章必须整章 eager，否则离屏图 0 尺寸 → maxScroll 塌缩');
    });

    test('纯图片章：eagerAll 下一个 lazy 都不加', () {
      const String html = '<body><img src="p1.png"/><img src="p2.png"/></body>';
      expect(
          ReaderResourceSanitizer.markImagesLazy(html, eagerAll: true), html);
    });

    test('gaiji 内联小图无论哪条路径都不挂 lazy（参与文字排版几何）', () {
      const String html = '<p>文<img class="gaiji-line" src="g.png"/>字</p>';
      expect(ReaderResourceSanitizer.markImagesLazy(html), html);
    });
  });

  group('预热配额与阅读方向（PR#469 审查）', () {
    test('预热按张数 + 字节双封顶', () {
      final String src = webviewSrc();
      // 窗口=方法体（花括号配对），不再是 `idx + 1800`：该方法体实测 1483 字符，
      // 旧窗口越过方法末尾 317 字符读进下一个方法，两条配额断言可能命中错对象。
      final String body =
          methodBody(src, 'void _prefetchAdjacentChapterImages(');
      expect(body.contains('_kImagePrefetchMaxCount'), isTrue,
          reason: '预热必须有张数上限');
      expect(body.contains('_kImagePrefetchMaxBytes'), isTrue,
          reason: '预热必须有字节上限（整页插图书的内存压力是实打实的）');
    });

    test('预热跟随阅读方向，而不是写死 +1', () {
      final File navFile = File(
        'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
      );
      final String src =
          navFile.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      expect(
          src.contains(
              '_prefetchAdjacentChapterImages( _currentChapter + _chapterAdvanceDirection)'),
          isTrue,
          reason: '倒着读时必须预热上一章，而不是刚离开的那一章');
      expect(
          src.contains(
              '_chapterAdvanceDirection = chapter > _currentChapter ? 1 : -1;'),
          isTrue,
          reason: '方向必须在唯一的导航采样点 _beginNavigation 更新');
    });
  });
}
