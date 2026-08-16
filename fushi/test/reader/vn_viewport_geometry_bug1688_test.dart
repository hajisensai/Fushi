import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

/// BUG-1688 守卫 —— VN view-mode 的可用盒必须与分页/连续 shell 同源。
///
/// 回归形态（已在 macOS live WebView 上复现，见
/// `integration_test/reader_vn_chrome_inset_dom_test.dart`）：VN shell 从不写
/// `--chrome-top-inset / --chrome-bottom-inset / --page-width / --page-height`，
/// `setChromeInsets` 还是个 `return null` 的空壳、`updatePageSize` 整个忽略入参。
/// 于是 `.fushi-vn-stage` 的 `padding: calc(...vh + var(--chrome-*-inset, 0px))`
/// 恒取 0px、量尺 `createScreenMeasurement` 恒退回 `100vw/100vh`，每屏都被切成
/// "刚好填满整个视口" → 首尾行落进顶栏/底栏覆盖区。iOS 上再叠刘海与 home
/// indicator，预留带最厚，所以表现最严重（"VN 模式基本不可用"）。
///
/// headless WebView 在 CI 跑不到，几何行为由上面那条集成测试在真实 WebView 上守；
/// 本文件只锁源码结构不回退——即"这四个变量确实有人写、量尺确实照真实屏盒量"。
void main() {
  late String shell;

  setUpAll(() {
    shell = ReaderVisualNovelScripts.vnShellScript();
  });

  group('BUG-1688 VN viewport geometry guard', () {
    test('VN rewrites the viewport meta exactly like the other two shells', () {
      // iOS 真机实测：缺这段时 WKWebView 按默认 980 CSS px 布局再整体缩放
      // （innerWidth=980 对 dartPageWidth=375），正文缩到约四成大小、所有按 px
      // 下发的量全被按错单位解释。Android 默认 device-width、桌面窗口普遍 ≥980，
      // 所以这个缺口只在 iOS 上显形——即"iOS 上 VN 不可用"的主因。
      expect(
        shell.contains(ReaderPaginationScripts.sharedInitViewportJs),
        isTrue,
        reason: 'VN shell must inline the SAME viewport-meta rewrite the '
            'paginated/continuous shells run in their initialize()',
      );
      expect(
        shell.contains('applyViewportMeta: function()'),
        isTrue,
        reason: 'VN shell must own a viewport-meta applier',
      );
      // 必须排在写几何变量之前：meta 改的是 CSS 像素空间本身。
      final int metaAt = shell.indexOf('this.applyViewportMeta();');
      final int varsAt = shell.indexOf('this.applyViewportVars();');
      expect(metaAt, greaterThan(-1),
          reason: 'initialize must call applyViewportMeta');
      expect(metaAt, lessThan(varsAt),
          reason: 'the viewport meta defines the CSS pixel space, so it must '
              'land before any px-valued geometry var is written');
    });

    test('VN initialize applies the chrome insets + page box from the config',
        () {
      expect(
        shell.contains('applyViewportVars: function()'),
        isTrue,
        reason: 'VN shell must own a viewport-var applier',
      );
      for (final String pair in <String>[
        "setProperty('--chrome-top-inset', (Number(C.chromeTopInset) || 0)",
        "setProperty('--chrome-bottom-inset', (Number(C.chromeBottomInset) || 0)",
      ]) {
        expect(
          shell.contains(pair),
          isTrue,
          reason: 'VN must push the Dart-side chrome insets into the document '
              '($pair missing) — otherwise the stage lays out over the chrome',
        );
      }
      expect(
        shell.contains("setProperty('--page-width', pageWidth + 'px')"),
        isTrue,
        reason: 'VN must publish --page-width for the screen measurement',
      );
      expect(
        shell.contains("setProperty('--page-height', pageHeight + 'px')"),
        isTrue,
        reason: 'VN must publish --page-height for the screen measurement',
      );
      // 必须排在建舞台/切屏之前：fitScreensToViewport 是按当前屏盒切的。
      final int applyAt = shell.indexOf('this.applyViewportVars();');
      final int stageAt = shell.indexOf('this.ensureStage();');
      final int buildAt = shell.indexOf('this.buildScreens();');
      expect(applyAt, greaterThan(-1),
          reason: 'initialize must call applyViewportVars');
      expect(applyAt, lessThan(stageAt),
          reason: 'viewport vars must land before the stage is built');
      expect(applyAt, lessThan(buildAt),
          reason: 'viewport vars must land before screens are split');
    });

    test('setChromeInsets is a real implementation, not the old no-op stub',
        () {
      expect(
        shell.contains(
          'vn.setChromeInsets = function(topPx, bottomPx) { return null; };',
        ),
        isFalse,
        reason: 'the no-op setChromeInsets stub dropped every inset update '
            'Dart pushed (chrome.part.dart _applyChromeInsets) — VN then laid '
            'out under the top/bottom chrome',
      );
      expect(
        shell
            .contains("setProperty('--chrome-top-inset', (Number(topPx) || 0)"),
        isTrue,
        reason: 'setChromeInsets must write the top inset variable',
      );
      expect(
        shell.contains(
          "setProperty('--chrome-bottom-inset', (Number(bottomPx) || 0)",
        ),
        isTrue,
        reason: 'setChromeInsets must write the bottom inset variable',
      );
      expect(
        shell.contains('this.refitScreensToCurrentViewport();'),
        isTrue,
        reason: 'an inset change resizes the usable box, so the screens must '
            'be re-split — padding alone leaves the old overflowing screen',
      );
    });

    test('updatePageSize consumes its arguments', () {
      expect(
        shell.contains('vn.updatePageSize = function(width, height)'),
        isTrue,
        reason: 'VN must keep the host-compat updatePageSize shim',
      );
      expect(
        shell.contains('var w = Math.round(Number(width) || 0);'),
        isTrue,
        reason: 'updatePageSize must read its width argument (it used to '
            'ignore both, leaving --page-width unset forever)',
      );
      expect(
        shell.contains('var h = Math.round(Number(height) || 0);'),
        isTrue,
        reason: 'updatePageSize must read its height argument',
      );
    });

    test('the screen measurement mirrors the real .fushi-vn-screen box', () {
      expect(
        shell.contains("root.style.width = screenBox.width + 'px';"),
        isTrue,
        reason: 'the measurement probe must be sized from the live screen rect',
      );
      expect(
        shell.contains("root.style.height = screenBox.height + 'px';"),
        isTrue,
        reason: 'the measurement probe must be sized from the live screen rect',
      );
      // 兜底分支保留（首屏极早期还没有屏盒），但不能是唯一路径。
      expect(
        shell.contains("root.style.width = 'var(--page-width, 100vw)';"),
        isTrue,
        reason: 'the pre-layout fallback sizing must stay as a fallback',
      );
    });
  });
}
