import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';

// BUG-3482：iOS 滚动模式下手指沿交叉轴（竖排上下 / 横排左右）拖动，整页跟着移了
// 约 9pt。`html { overflow-<交叉轴>: hidden }` 锁不住 WKWebView 的 UIScrollView——它
// 的内容尺寸取文档的可滚动溢出，正文里任何沿交叉轴越界的后代都让交叉轴可拖。
//
// 真 WebKit 真触摸实测（iPhone 17 Pro 模拟器 / iOS 26.5，纯 WKWebView 加载本生成器
// 的 CSS + 一个沿交叉轴越界 16px 的块，`support/ios_webkit_pan_probe/`）：
//   修复前  竖排 contentSize 高 890 > 874，上下拖 contentOffset.y 在 0..16 之间；
//           横排 contentSize 宽 418 > 402，左右拖 contentOffset.x 在 0..16 之间；
//   修复后  内容尺寸 == 视口，上下 / 左右 / 斜拖交叉轴恒 0，主轴照常滚。
//   只加 body clip 或只加 touch-action 各自都挡得住手指；clip 另外让程序化滚动
//   （scrollBy / scrollIntoView）沿交叉轴无处可去，两层一起上。
//
// 本测试钉生成器输出：滚动模式两种书写方向各带一条锁轴规则（touch-action 只放主轴
// + body 交叉轴 clip），且 body 绝不能用 hidden（TODO-718：hidden 会让 body 另一轴变
// auto、body 自成滚动容器）；翻页 / VN（html、body 两轴 hidden）不受影响。
Future<String> _css({
  required String viewMode,
  required String writingMode,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  await settings.setViewMode(viewMode);
  await settings.setWritingMode(writingMode);
  return ReaderContentStyles.css(settings: settings);
}

void main() {
  group('BUG-3482 continuous mode locks the cross axis', () {
    test('vertical-rl: pan-x only + body overflow-y: clip', () async {
      final String css = await _css(
        viewMode: 'continuous',
        writingMode: 'vertical-rl',
      );
      expect(
        css,
        contains(
          'html, body {\n  touch-action: pan-x !important;\n}\n'
          'body {\n  overflow-y: clip !important;\n}',
        ),
      );
      expect(css, contains('html {\n  overflow-y: hidden !important;\n}'));
      expect(css, isNot(contains('touch-action: pan-y')));
      expect(
        css,
        isNot(matches(RegExp(r'body \{[^}]*overflow-y: hidden'))),
        reason: 'TODO-718: body must not become a scroll container',
      );
    });

    test('horizontal-tb: pan-y only + body overflow-x: clip', () async {
      final String css = await _css(
        viewMode: 'continuous',
        writingMode: 'horizontal-tb',
      );
      expect(
        css,
        contains(
          'html, body {\n  touch-action: pan-y !important;\n}\n'
          'body {\n  overflow-x: clip !important;\n}',
        ),
      );
      expect(css, contains('html {\n  overflow-x: hidden !important;\n}'));
      expect(css, isNot(contains('touch-action: pan-x')));
      expect(
        css,
        isNot(matches(RegExp(r'body \{[^}]*overflow-x: hidden'))),
        reason: 'TODO-718: body must not become a scroll container',
      );
    });

    for (final String mode in <String>['paginated', 'vn']) {
      for (final String wm in <String>['vertical-rl', 'horizontal-tb']) {
        test('$mode / $wm: no axis lock rule', () async {
          final String css = await _css(viewMode: mode, writingMode: wm);
          if (mode == 'paginated') {
            expect(css, contains('touch-action: none !important;'));
          }
          expect(css, isNot(contains('touch-action: pan-')));
          expect(css, isNot(contains(': clip !important;\n}')));
        });
      }
    }
  });
}
