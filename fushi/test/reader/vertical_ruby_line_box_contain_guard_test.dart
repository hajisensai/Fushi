import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';

import '../helpers/source_guard.dart';

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
/// 用共享的 CSS 掩码：等长（下标可回原串）、块注释不嵌套（Dart 规则会在
/// 「注释掉一段本身含注释的规则」时吞掉文件剩余部分，之后断言全对空串跑 ⇒ 静默全绿）。
String _stripCssComments(String css) => maskCssComments(css);

Future<String> _readerCss({
  required String writingMode,
  required String viewMode,
  double? lineHeight,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final ReaderSettings settings = ReaderSettings(db);
  await settings.refreshFromDb();
  await settings.setWritingMode(writingMode);
  await settings.setViewMode(viewMode);
  if (lineHeight != null) await settings.setLineHeight(lineHeight);
  return ReaderContentStyles.css(settings: settings);
}

/// 「含 `rt` 的选择器块里带一个负的 `margin-block-start`」——BUG-2472 现行修法的
/// 不变式。刻意不钉数值、单位、`!important` 与排版：那些都是等价可换的写法，
/// 钉住它们只会让下一次无害改写假红（本仓反复踩过的「钉写法不钉不变式」）。
final RegExp _kNegativeRtMarginBlockStart = RegExp(
    r'rt\b[^{}]*\{[^}]*margin-block-start:\s*-\s*[\d.]+[a-z]+',
    dotAll: true);

/// 「压根没有负的 `margin-block-start`」——非 Apple 端的不变式。用它而不是某个
/// 具体数值，Apple 端换值时这条不会跟着退化成恒真空壳。
final RegExp _kAnyNegativeMarginBlockStart = RegExp(r'margin-block-start:\s*-');

/// BUG-2724：「含 `rt` 的选择器块里带一个负的 `margin-block-end`」——WebKit
/// 注音贴回本行的不变式，同样不钉数值与写法（字面负值或以负项开头的 `calc()`，
/// BUG-2779 起是后者）。
final RegExp _kNegativeRtMarginBlockEnd = RegExp(
    r'rt\b[^{}]*\{[^}]*margin-block-end:\s*(?:-\s*[\d.]+[a-z]+|calc\(\s*-)',
    dotAll: true);

/// 非 Apple 端：压根没有负的 `margin-block-end`（字面负值或负项 `calc()`）。
final RegExp _kAnyNegativeMarginBlockEnd =
    RegExp(r'margin-block-end:\s*(?:-|calc\(\s*-)');

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

    test(
        'BUG-2472 / BUG-2482：任何平台都不再发出 -webkit-line-box-contain；'
        'Apple 端（WebKit）改发 ruby 注音盒的负 margin-block-start，'
        'Android / Windows 不发（Linux 走 WPE WebKit，同 Apple 端）', () async {
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux, // WPE WebKit
      ]) {
        debugDefaultTargetPlatformOverride = p;
        try {
          final String css = _stripCssComments(await _readerCss(
              writingMode: 'vertical-rl', viewMode: 'paginated'));
          expect(css.contains('-webkit-line-box-contain'), isFalse,
              reason: '$p：`block replaced` 在 quirks 模式下把整行 strut 一并剔掉，'
                  '整行文字都在 inline 盒里的行与 <br/> 空行行盒归零'
                  '（BUG-2482：目录列叠印、空行消失）——任何平台都不得再发');
          expect(
              css,
              matches(_kNegativeRtMarginBlockStart),
              reason: '$p：WebKit 首行含注音的段落被撑高 ≈0.215em（BUG-2472），'
                  '修法是只把注音盒在流中的高度用负 margin 抵消掉，不碰行盒 strut。'
                  '钉的是「注音选择器块里有负的 margin-block-start」这条不变式，'
                  '不是具体数值/单位/排版——换等价写法不该假红');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        try {
          final String css = _stripCssComments(await _readerCss(
              writingMode: 'vertical-rl', viewMode: 'paginated'));
          expect(css.contains('-webkit-line-box-contain'), isFalse,
              reason: '$p：Blink / 旧 Android WebView 不得收到该属性（BUG-611）');
          expect(css, isNot(matches(_kAnyNegativeMarginBlockStart)),
              reason: '$p：Blink 本就不为注音长高，负 margin 只发给 WebKit。'
                  '钉「任何负 margin-block-start 都不得出现」而不是钉某个数值——'
                  '否则 Apple 端一改数值，这条就退化成恒真空壳');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });

    test(
        'BUG-2724：Apple 端（WebKit）给注音盒负 margin-block-end，把注音贴回本行'
        '（横排）/本列（竖排）；Android / Windows 不发（Linux 走 WPE WebKit，同 Apple 端）', () async {
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux, // WPE WebKit
      ]) {
        for (final String wm in <String>['horizontal-tb', 'vertical-rl']) {
          debugDefaultTargetPlatformOverride = p;
          try {
            final String css = _stripCssComments(
                await _readerCss(writingMode: wm, viewMode: 'paginated'));
            expect(
                css,
                matches(_kNegativeRtMarginBlockEnd),
                reason: '$p/$wm：WebKit 把注音边框盒底贴在基字内容区顶，Hiragino 的 '
                    'ascent 空白 + 注音半行距全落在注音与本行之间，注音贴近上一行'
                    '（iOS 实拍本行 3.3px / 上一行 5.3px）。注音盒底 = 基字顶 − '
                    'margin-block-end，负值才能把注音挪回基字。钉「注音选择器块里'
                    '有负的 margin-block-end」这条不变式，不钉数值');
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        }
      }
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        try {
          final String css = _stripCssComments(await _readerCss(
              writingMode: 'vertical-rl', viewMode: 'paginated'));
          expect(css, isNot(matches(_kAnyNegativeMarginBlockEnd)),
              reason: '$p：Blink 的注音本就紧贴基字，这条 WebKit 位置补偿不得发给它');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });

    test(
        'BUG-2779：Apple 端注音负块尾边距吃运行时量出的字体度量变量（缺省即 '
        'BUG-2724 的 -0.2em），并打出给度量脚本的开关；其它平台都不发', () async {
      // 变量缺省值必须让 calc 退回旧的 -0.2em：脚本没跑到（首帧 / 无 ruby）时行为不变。
      final RegExp pullRule = RegExp(
          r'rt\b[^{}]*\{[^}]*margin-block-end:\s*calc\(\s*-1em\s*\*\s*'
          r'var\(--fushi-ruby-pull,\s*([\d.]+)\)\s*-\s*([\d.]+)em\s*\)',
          dotAll: true);
      final RegExp snap = RegExp(r'--fushi-ruby-snap:\s*1');
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux, // WPE WebKit
      ]) {
        for (final String wm in <String>['horizontal-tb', 'vertical-rl']) {
          for (final String vm in <String>['paginated', 'continuous', 'vn']) {
            debugDefaultTargetPlatformOverride = p;
            try {
              final String css = _stripCssComments(
                  await _readerCss(writingMode: wm, viewMode: vm));
              final RegExpMatch? m = pullRule.firstMatch(css);
              expect(m, isNotNull,
                  reason: '$p/$wm/$vm：注音与基字之间的空白由字体 ascent/descent 决定，'
                      '固定 em 值只对 Hiragino 成立（Klee One 下 iOS 实测离本列 8.3px、'
                      '贴上一列）；必须吃 reader_ruby_metrics_script 量出的 '
                      '--fushi-ruby-pull');
              expect(double.parse(m!.group(1)!) + double.parse(m.group(2)!),
                  closeTo(0.2, 1e-9),
                  reason: '$p/$wm/$vm：变量缺省时必须等于 BUG-2724 已验证的 -0.2em');
              expect(css, matches(snap),
                  reason: '$p/$wm/$vm：度量脚本只认这个开关，缺了它变量永远不写');
            } finally {
              debugDefaultTargetPlatformOverride = null;
            }
          }
        }
      }
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        try {
          final String css = _stripCssComments(await _readerCss(
              writingMode: 'vertical-rl', viewMode: 'paginated'));
          expect(css, isNot(matches(snap)),
              reason: '$p：Blink 注音本就贴基字，度量脚本不得在这里写变量');
          expect(css.contains('--fushi-ruby-pull'), isFalse);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });

    test(
        'BUG-2761：Apple 端分页给段落块首预留注音位置，并用 p::after 的负块尾边距'
        '抵消（页中零位移、页顶边距截断后留出预留）；其它平台 / 滚动 / VN 不发',
        () async {
      // 段落块首预留 R，与 p::after 块尾 −R 等量相抵：页中段落位置不变，只有落在
      // 页顶（分栏处边距被截断）时 R 留下来装注音。钉「两者同值且都在」，不钉数值。
      final RegExp reserve = RegExp(
          r'(?:^|[\s,}])p\s*\{[^}]*padding-block-start:\s*([\d.]+)em',
          multiLine: true);
      final RegExp cancel = RegExp(
          r'p::after\s*\{[^}]*display:\s*block[^}]*margin-block-end:\s*-\s*([\d.]+)em');
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux, // WPE WebKit
      ]) {
        for (final String wm in <String>['horizontal-tb', 'vertical-rl']) {
          debugDefaultTargetPlatformOverride = p;
          try {
            final String css = _stripCssComments(
                await _readerCss(writingMode: wm, viewMode: 'paginated'));
            final RegExpMatch? r = reserve.firstMatch(css);
            final RegExpMatch? c = cancel.firstMatch(css);
            expect(r, isNotNull,
                reason: '$p/$wm：WebKit 多列把伸出列顶的注音画进上一列底部，'
                    '页顶那一行必须在段落块首留出注音的位置');
            expect(c, isNotNull,
                reason: '$p/$wm：预留必须由可在分栏处被截断的负边距抵消，'
                    '否则每个段落都多出一截、整本书排版变样');
            expect(double.parse(r!.group(1)!), greaterThan(0));
            expect(c!.group(1), r.group(1),
                reason: '$p/$wm：预留与抵消必须等量，页中段落才零位移');
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        }
        debugDefaultTargetPlatformOverride = p;
        try {
          for (final String vm in <String>['continuous', 'vn']) {
            final String css = _stripCssComments(
                await _readerCss(writingMode: 'vertical-rl', viewMode: vm));
            expect(css, isNot(matches(cancel)),
                reason: '$p/$vm：不经多列分页，没有跨列问题，不发');
          }
          final String loose = _stripCssComments(await _readerCss(
              writingMode: 'horizontal-tb',
              viewMode: 'paginated',
              lineHeight: 2.4));
          expect(loose, isNot(matches(cancel)),
              reason: '$p：行高 2.4 的上半 leading 已容得下注音，不需要预留');
          final String tight = _stripCssComments(await _readerCss(
              writingMode: 'horizontal-tb',
              viewMode: 'paginated',
              lineHeight: 1.0));
          final String normal = _stripCssComments(await _readerCss(
              writingMode: 'horizontal-tb', viewMode: 'paginated'));
          expect(
              double.parse(reserve.firstMatch(tight)!.group(1)!),
              greaterThan(double.parse(reserve.firstMatch(normal)!.group(1)!)),
              reason: '$p：行高越小 leading 越装不下注音，预留要跟着变大');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = p;
        try {
          final String css = _stripCssComments(await _readerCss(
              writingMode: 'vertical-rl', viewMode: 'paginated'));
          expect(css, isNot(matches(cancel)),
              reason: '$p：Blink 按行片段所在列绘制注音，不跨列，不发');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });

    test(
        'BUG-2799：页顶注音预留的正负两半都必须 !important，书样式压不掉其中一半',
        () async {
      // 阅读器样式表注在书之后，但书里更高权重的 `.main p { padding: 0 }` 会压掉
      // 不带 !important 的块首预留，负的 p::after 却照常生效 → 每个段落边界净少 R
      // （用户 iOS 竖排截图：段间列距只剩段内的 0.80）。两半必须同进同退。
      final RegExp reserveBlock =
          RegExp(r'(?:^|[\s,}])p\s*\{([^}]*padding-block-start[^}]*)\}',
              multiLine: true);
      final RegExp cancelBlock = RegExp(r'p::after\s*\{([^}]*)\}');
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux, // WPE WebKit
      ]) {
        for (final String wm in <String>['horizontal-tb', 'vertical-rl']) {
          debugDefaultTargetPlatformOverride = p;
          try {
            final String css = _stripCssComments(
                await _readerCss(writingMode: wm, viewMode: 'paginated'));
            final String reserve = reserveBlock.firstMatch(css)!.group(1)!;
            final String cancel = cancelBlock.firstMatch(css)!.group(1)!;
            expect(reserve, matches(r'padding-block-start:[^;]*!important'),
                reason: '$p/$wm：块首预留可被书的高权重 reset 压掉，'
                    '负边距留下来就让每个段落边界少 R');
            for (final String prop in <String>[
              'content',
              'display',
              'margin-block-end',
            ]) {
              expect(cancel, matches('$prop:[^;]*!important'),
                  reason: '$p/$wm：p::after 的 $prop 被书改掉会让抵消失效，'
                      '段落多出 R');
            }
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        }
      }
    });

    test('文档注释里仍可提及属性名(仅剥注释后才断言，避免误判)', () async {
      // 完整 CSS(含注释)里允许出现属性名(记录决策的注释)；只有剥掉注释后才不能有声明。
      final String rawCss =
          await _readerCss(writingMode: 'vertical-rl', viewMode: 'continuous');
      final String stripped = _stripCssComments(rawCss);
      // 剥注释后不含 → 守卫本体；下面两条保证 stripper 真的把注释剥掉了(否则上面的
      // 守卫失效)。判据从「长度变短」改成「内容变了 + 注释标记没了」：共享掩码是
      // **等长**替换（下标可回原串切片），长度不再变短，旧判据会永远红。
      expect(stripped.length, rawCss.length,
          reason: 'maskCssComments 是等长掩码，长度必须守恒');
      expect(stripped, isNot(rawCss),
          reason: 'CSS 应含注释，_stripCssComments 必须真的把注释掩掉了');
      expect(stripped.contains('/*'), isFalse, reason: '掩码后不该再有块注释起始标记');
    });
  });
}
