import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';

/// BUG-2638 守卫 —— VN 舞台 `.fushi-vn-stage` 不能是 `position: fixed`。
///
/// macOS WebKit 把 fixed 舞台单独合成成一层；竖排切屏让内容盒尺寸变化时，它只
/// 重绘**旧**内容盒那块区域，新屏落在旧框外的列不画（字形被竖着切掉半边），直到
/// 查词高亮之类的无关重绘才补上。真机 WKWebView 实测（离屏层树 vs takeSnapshot
/// 逐像素比对）：fixed 下「うまかった」→ 两列新屏稳定只剩中段，改 absolute 后
/// 8/8 屏一致；横排、内容盒铺满、舞台单独 will-change 也都不触发。VN 文档从不
/// 滚动（body 只剩舞台，html/body 100vw×100vh + overflow hidden），absolute 的
/// 包含块就是视口，几何与 fixed 相同。
///
/// 像素层面的行为只能在真 WKWebView 上验（CI 无 WebKit 合成）；这里锁生成器的
/// 输出不回退到 fixed，并锁住 absolute 等价于 fixed 所依赖的「文档不滚动」前提。
Future<ReaderSettings> _vnSettings(String writingMode) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  await settings.setViewMode('vn');
  await settings.setWritingMode(writingMode);
  return settings;
}

String _ruleBody(String css, String selector) {
  final int start = css.indexOf('$selector {');
  expect(start, greaterThan(-1), reason: 'VN CSS must define `$selector`');
  final int open = css.indexOf('{', start);
  final int close = css.indexOf('}', open);
  return css.substring(open + 1, close);
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.macOS,
    TargetPlatform.iOS,
    TargetPlatform.android,
    TargetPlatform.windows,
  ]) {
    for (final String writingMode in <String>['vertical-rl', 'horizontal-tb']) {
      test(
          'BUG-2638 VN stage is absolute, not fixed '
          '(${platform.name}, $writingMode)', () async {
        debugDefaultTargetPlatformOverride = platform;
        final ReaderSettings settings = await _vnSettings(writingMode);
        final String css = ReaderContentStyles.css(settings: settings);
        // 掩掉注释再查，免得解释性注释里的 "fixed" 字样误伤。
        final String stage = maskCssComments(_ruleBody(css, '.fushi-vn-stage'));
        expect(stage, contains('position: absolute !important'),
            reason: 'the VN stage must be absolutely positioned (BUG-2638)');
        expect(stage.contains('position: fixed'), isFalse,
            reason: 'a fixed VN stage leaves vertical-rl screen swaps '
                'half-painted on macOS WebKit (BUG-2638)');
        expect(stage, contains('inset: 0 !important'));

        // absolute == fixed 的前提：文档本身不可滚动、占满视口。
        final String root = _ruleBody(css, 'html, body');
        expect(root, contains('width: 100vw !important'));
        expect(root, contains('height: 100vh !important'));
        expect(root, contains('overflow: hidden !important'));
      });
    }
  }
}
