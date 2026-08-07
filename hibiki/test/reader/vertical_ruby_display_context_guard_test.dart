import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

import '../helpers/source_guard.dart';

// TODO-1308 (BUG-611 follow-up): 竖排(vertical-rl)阅读器里，貫(かん)禄(ろく) 这类带
// 振假名的内容，从目录/书签跳转后振假名错位——かん 挤到两个汉字之间、ろく 浮到基字
// 右侧下方。真机复现(reader_vertical_ruby_probe_itest.dart)证实：根因是真书 EPUB 自带
// 的 legacy 振假名 CSS（`rt { display: inline-block }` / `ruby { display: inline-block }`
// 之类，旧 WebKit ruby 模型的遗留写法）在现代 Blink 下破坏 <ruby> 格式化上下文，把 <rt>
// 从注音盒里挤出去 → 竖排下沿列向下塌约一整字(实测 dyRatio≈0.95 vs 0 正确)。
//
// 修复=reader 拥有写向就该拥有 ruby 结构：reader 的 <style> 注入在 <head> 末尾(书本
// 样式之后，webview.part.dart)，故用 !important 强制 `ruby{display:ruby}` /
// `rt{display:ruby-text}` / `ruby>rp{display:none}` 能在级联里压过书本的 display 覆盖，
// 重新确立正确的 ruby 结构。rt display 由 _furiganaCss 拥有，故 hide 模式的 display:none
// 仍在那里胜出(振假名隐藏时不被强制显示)。
//
// 真机竖排 ruby 渲染无法在 headless 复现(需真 WebView2 + 书本 display 覆盖)，故本守卫
// 锁在 CSS 生成层：任何写向/视图/振假名模式下，生成的正文 CSS 都必须发出这些强制声明。

/// 用共享的 CSS 掩码：等长（下标可回原串）、块注释不嵌套（Dart 规则会在
/// 「注释掉一段本身含注释的规则」时吞掉文件剩余部分，之后断言全对空串跑 ⇒ 静默全绿）。
String _stripCssComments(String css) => maskCssComments(css);

String _collapseWs(String css) => css.replaceAll(RegExp(r'\s+'), ' ').trim();

Future<String> _readerCss({
  required String writingMode,
  required String viewMode,
  required String furiganaMode,
}) async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  await settings.setWritingMode(writingMode);
  await settings.setViewMode(viewMode);
  await settings.setFuriganaMode(furiganaMode);
  return _collapseWs(
      _stripCssComments(ReaderContentStyles.css(settings: settings)));
}

void main() {
  group('TODO-1308 reader 强制 <ruby> 格式化上下文防书本 display 覆盖', () {
    const List<({String wm, String vm})> layouts = <({String wm, String vm})>[
      (wm: 'vertical-rl', vm: 'continuous'),
      (wm: 'vertical-rl', vm: 'paginated'),
      (wm: 'horizontal-tb', vm: 'continuous'),
      (wm: 'horizontal-tb', vm: 'paginated'),
    ];

    test('ruby 容器与 rp 在所有布局都强制 display(!important)', () async {
      for (final ({String wm, String vm}) c in layouts) {
        final String css = await _readerCss(
            writingMode: c.wm, viewMode: c.vm, furiganaMode: 'show');
        expect(
            css.contains(
                'ruby { display: ruby !important; ruby-position: over !important; }'),
            isTrue,
            reason: '${c.wm}/${c.vm}: 必须强制 ruby{display:ruby!important}，否则书本 '
                '`ruby{display:inline-block}` 会破坏 ruby 上下文 → 竖排振假名塌进基字列');
        expect(css.contains('ruby rp { display: none !important; }'), isTrue,
            reason:
                '${c.wm}/${c.vm}: 必须强制 ruby rp{display:none!important}(后代选择器，'
                '覆盖 rtc/rb 嵌套里的 rp)，防书本让 rp 括注显示');
        expect(css.contains('ruby rb { display: inline !important; }'), isTrue,
            reason:
                '${c.wm}/${c.vm}: 必须强制 ruby rb{display:inline!important}——Blink 无 '
                'rb 支持，书本 rb{display:block/inline-block} 会改变基字几何');
      }
    });

    test('ruby-position: over 在所有布局都强制(!important) — 竖排振假名右侧+高亮对齐', () async {
      // BUG-666：只拥有 display/writing-mode 不够，还得拥有 ruby-position。真书 legacy
      // CSS 的 `ruby{ruby-position:under}`(或 -webkit-ruby-position:after) 在 vertical-rl
      // 下把振假名甩到基字**左侧**(正确日文侧是右侧=over)，且让高亮 lane(竖排画 left
      // center=基字列)错位到振假名列。over 横排=基字上方、竖排=基字右侧，两写向都对。
      for (final ({String wm, String vm}) c in layouts) {
        final String css = await _readerCss(
            writingMode: c.wm, viewMode: c.vm, furiganaMode: 'show');
        expect(css.contains('ruby-position: over !important'), isTrue,
            reason: '${c.wm}/${c.vm}: 必须强制 ruby-position:over!important，否则书本 '
                '`ruby{ruby-position:under}` 竖排把振假名翻到基字左侧 + 高亮带错位');
        // over 必须直接挂在 ruby 容器规则上(与 display:ruby 同一块)，不得写成 under。
        expect(css.contains('ruby-position: under'), isFalse,
            reason: '${c.wm}/${c.vm}: 阅读器不得发出 ruby-position:under(会把振假名翻错侧)');
      }
    });

    test('竖排 ruby 高亮整句填充 + ruby-position:over 让振假名留在背景盒外', () async {
      // BUG-716：原 narrow-lane(_highlightLaneCss 竖排 background-position:left center)
      // 靠「振假名在右(over)、基字在左」把 1em 窄条钉到基字列，但 left 落点在书籍行距≠
      // 字号或 <ruby> 盒宽不同(有无振假名)时错位 → 用户报有声书/查词注音高亮偏移。现回到
      // 整句 background-color 填充：背景只刷 ruby 元素盒(不含 rt 注音轨)，over 仍保证振假名
      // 在其自己的注音道(竖排右/横排上)、留在高亮基字盒外 → 有无振假名一致、无窄条 left 偏移。
      final String css = await _readerCss(
          writingMode: 'vertical-rl',
          viewMode: 'continuous',
          furiganaMode: 'show');
      expect(css.contains('ruby-position: over !important'), isTrue,
          reason: '竖排必须 ruby-position:over(振假名在右、留在基字高亮盒外)');
      expect(
          css.contains(
              'background-color: var(--hoshi-sentence-audio-background-color) !important'),
          isTrue,
          reason: 'BUG-716：ruby 有声书高亮整句 background-color 填充');
      expect(css.contains('--hoshi-highlight-lane-color'), isFalse,
          reason: 'BUG-716：不再有 narrow-lane 窄条(避免 left 落点在宽盒/含注音轨时偏移)');
    });

    test('振假名显示态(show/partial/toggle) rt 强制 display:ruby-text(!important)',
        () async {
      for (final String fm in <String>['show', 'partial', 'toggle']) {
        final String css = await _readerCss(
            writingMode: 'vertical-rl',
            viewMode: 'continuous',
            furiganaMode: fm);
        expect(css.contains('display: ruby-text !important'), isTrue,
            reason: 'furigana=$fm: 显示态 rt 必须强制 display:ruby-text!important，'
                '否则书本 `rt{display:inline-block}` 把 <rt> 挤出注音盒 → 竖排错位');
        // 显示态不得把 rt 藏掉(display:none 只属于 hide 模式)。
        expect(css.contains('rt { display: none !important; }'), isFalse,
            reason: 'furigana=$fm: 显示态不应发出 rt{display:none}(那是 hide 模式)');
      }
    });

    test('振假名显示态接管 <rtc>(Blink 无 rtc 支持) — rtc=注音级、rtc>rt=内联', () async {
      // TODO-1308 复诉：真机(WebView2)量测证实 CSS.supports('display','ruby-base'|
      // 'ruby-text-container')=false，rb/rtc 默认 inline。裸 rt{display:ruby-text}
      // 会把 rtc 里的每个 <rt> 包进匿名 ruby，落在正文流原位=注音以整字格内联进基字列
      // (用户截图：かん挤在貫/禄之间、ろく掉到词下方)。修复=显示态把 rtc 整个映射为
      // 单一注音级(display:ruby-text)、其 rt 子元素归位 inline(在注音里当普通文本跑)。
      for (final String fm in <String>['show', 'partial', 'toggle']) {
        final String css = await _readerCss(
            writingMode: 'vertical-rl',
            viewMode: 'continuous',
            furiganaMode: fm);
        expect(
            css.contains(
                'rtc { display: ruby-text !important; font-size: 0.45em; }'),
            isTrue,
            reason: 'furigana=$fm: 显示态必须把 rtc 映射为单一注音级(ruby-text)');
        expect(
            css.contains(
                'rtc > rt { display: inline !important; font-size: 1em; }'),
            isTrue,
            reason: 'furigana=$fm: rtc 里的 rt 必须归位 inline，否则被裸 rt 规则包成'
                '匿名 ruby 内联进基字列(TODO-1308 复诉截图)');
      }
    });

    test('振假名 hide 模式 rt 仍是 display:none(强制显示不得覆盖隐藏)', () async {
      final String css = await _readerCss(
          writingMode: 'vertical-rl',
          viewMode: 'continuous',
          furiganaMode: 'hide');
      expect(css.contains('rt, rtc { display: none !important; }'), isTrue,
          reason: 'hide 模式必须保留 rt,rtc{display:none!important}(振假名与 rtc 注音容器'
              '一起隐藏，防空 rtc 注音盒继续占注音道)');
      expect(css.contains('display: ruby-text !important'), isFalse,
          reason: 'hide 模式不得强制 rt/rtc display:ruby-text，否则会把隐藏的振假名显示出来');
      expect(css.contains('rtc > rt { display: inline !important'), isFalse,
          reason: 'hide 模式不得发出 rtc>rt{display:inline!important}——它比裸 rt 选择器'
              '更特异，会压过 rt{display:none} 把 rtc 里的振假名显示出来');
      // ruby 容器仍强制(与振假名显隐无关)。
      expect(
          css.contains(
              'ruby { display: ruby !important; ruby-position: over !important; }'),
          isTrue,
          reason: 'ruby 容器强制与 furigana 显隐正交，hide 模式也应保留');
    });
  });
}
