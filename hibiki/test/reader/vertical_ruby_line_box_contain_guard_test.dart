import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

// BUG-611 / TODO-1308: 竖排(vertical-rl)+滚动(连续)模式下，经目录/书签/搜索跳转后，
// 振假名(ruby <rt>)塌进基字/正文中间。根因是 html 规则里 legacy WebKit 属性
// `-webkit-line-box-contain: block glyphs replaced`（从 Hoshi 整体搬来，注释自陈意图是
// 「让 ruby/furigana 不撑高 line-box」）——它命令引擎把 line-box 尺寸只按 glyph 算，
// 不为 <ruby> 的 <rt> 标注预留 leading。现代 Blink 已完全丢弃该属性(no-op)，但仍解析它的
// 旧版 Android WebView 会据此抹掉竖排振假名在交叉轴(列宽方向)的预留 → <rt> 塌进基字列。
// 导航后 _applyChapterHighlights 强制样式重算把该约束重贴到刚滚动的内容上，故「导航后」
// 才显形。修复=删除该声明，让所有引擎回到会为 ruby 预留空间的默认 line-box 行为(现代
// Blink 早已如此，零回归)。
//
// 该属性在现代 Blink 上是 no-op，无法在 headless 复现旧引擎的抹除行为，故守卫锁在 CSS
// 生成层：任何写向/视图模式下生成的正文 CSS 都不得再发出该属性声明。
String _stripCssComments(String css) =>
    css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');

Future<String> _readerCss({
  required String writingMode,
  required String viewMode,
}) async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  await settings.setWritingMode(writingMode);
  await settings.setViewMode(viewMode);
  return ReaderContentStyles.css(settings: settings);
}

void main() {
  group('BUG-611 竖排 ruby 不被 -webkit-line-box-contain 抹掉标注预留', () {
    test(
        '四组合(竖排/横排 × 连续/分页)生成的正文 CSS 都不含活的 '
        '-webkit-line-box-contain 声明', () async {
      const List<({String wm, String vm})> combos = <({String wm, String vm})>[
        (wm: 'vertical-rl', vm: 'continuous'),
        (wm: 'vertical-rl', vm: 'paginated'),
        (wm: 'horizontal-tb', vm: 'continuous'),
        (wm: 'horizontal-tb', vm: 'paginated'),
      ];
      for (final ({String wm, String vm}) c in combos) {
        final String css = _stripCssComments(
            await _readerCss(writingMode: c.wm, viewMode: c.vm));
        expect(
          css.contains('-webkit-line-box-contain'),
          isFalse,
          reason: '${c.wm}/${c.vm}: 正文 CSS 不得发出 -webkit-line-box-contain '
              '声明——它会抹掉竖排 ruby 交叉轴预留 → 振假名塌进基字(BUG-611)。'
              '删除后所有引擎回到默认 line-box 行为(为 ruby 预留空间)。',
        );
      }
    });

    test('文档注释里仍可提及属性名(仅剥注释后才断言，避免误判)', () async {
      // 完整 CSS(含注释)里允许出现属性名(记录决策的注释)；只有剥掉注释后才不能有声明。
      final String rawCss =
          await _readerCss(writingMode: 'vertical-rl', viewMode: 'continuous');
      final String stripped = _stripCssComments(rawCss);
      // 剥注释后不含 → 守卫本体；此断言保证 stripper 真的把注释剥掉了(否则上面的守卫失效)。
      expect(stripped.length, lessThan(rawCss.length),
          reason: 'CSS 应含注释，_stripCssComments 必须真的剥掉了内容');
    });
  });
}
