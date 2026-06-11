import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

/// BUG-210 / TODO-146：阅读器「翻页有时跳回章节开头」。
///
/// 根因不在 JS `paginate`（真实 Chromium/WebView2 引擎下逐页步进稳健，已用 CDP
/// 注入真实分页脚本验证；BUG-169 的 floor/ceil 步进修复有效），而在
/// `_syncPageSize` 的视口变化判定：**宽度**用零容差精确浮点不等
/// `w != _lastSyncedWidth`，**高度**才用 `(h-last).abs() >= 1` 的 1px 容差。
/// Windows 桌面（flutter_inappwebview_windows fork 渲染 EPUB）在翻页/重绘时报
/// sub-pixel 视口宽抖动，零容差让任意 0.x px 宽差都判 widthChanged → 走整章重载
/// （`_navigateToChapter` 重新 load + 粗粒度 progress 恢复）→ 落到更靠前的页 /
/// 章节开头。
///
/// 修复 = 宽、高共用 1px 容差（[readerViewportNeedsRepaginate]）。本测试覆盖该纯
/// 函数：sub-pixel 宽抖动不再触发重排，真正的旋转/resize 大变仍触发。
void main() {
  group('readerViewportNeedsRepaginate width tolerance (BUG-210 regression)',
      () {
    test('sub-pixel width jitter does NOT trigger widthChanged', () {
      // 这是核心回归断言：撤回修复（改回 `w != lastWidth` 零容差）会让此用例变红。
      final r = readerViewportNeedsRepaginate(
        width: 1280.4,
        height: 800.0,
        lastWidth: 1280.0,
        lastHeight: 800.0,
      );
      expect(r.width, isFalse, reason: '0.4px 宽抖动不得触发整章重载（否则翻页被弹回更靠前的页/章节开头）');
      expect(r.height, isFalse);
    });

    test('a >= 1px width change (real resize/rotation) triggers widthChanged',
        () {
      final r = readerViewportNeedsRepaginate(
        width: 1281.0,
        height: 800.0,
        lastWidth: 1280.0,
        lastHeight: 800.0,
      );
      expect(r.width, isTrue, reason: '真实窗口 resize / 旋转（>=1px 宽变）仍要重排');
    });

    test('large rotation-scale width change still triggers widthChanged', () {
      final r = readerViewportNeedsRepaginate(
        width: 800.0,
        height: 1280.0,
        lastWidth: 1280.0,
        lastHeight: 800.0,
      );
      expect(r.width, isTrue);
      expect(r.height, isTrue);
    });

    test('first sync (lastWidth==0) never reports widthChanged', () {
      // _lastSyncedWidth>0 的门控保留：首帧基线尚未建立时不应判为宽变。
      final r = readerViewportNeedsRepaginate(
        width: 1280.0,
        height: 800.0,
        lastWidth: 0.0,
        lastHeight: 0.0,
      );
      expect(r.width, isFalse);
    });
  });

  group('readerViewportNeedsRepaginate height tolerance unchanged', () {
    test('sub-pixel height jitter does NOT trigger heightChanged', () {
      final r = readerViewportNeedsRepaginate(
        width: 1280.0,
        height: 800.4,
        lastWidth: 1280.0,
        lastHeight: 800.0,
      );
      expect(r.height, isFalse);
    });

    test(
        '>= 1px height change (chrome toggle / keyboard) triggers heightChanged',
        () {
      final r = readerViewportNeedsRepaginate(
        width: 1280.0,
        height: 760.0,
        lastWidth: 1280.0,
        lastHeight: 800.0,
      );
      expect(r.height, isTrue);
      expect(r.width, isFalse);
    });
  });
}
