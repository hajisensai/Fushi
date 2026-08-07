// 注音标记在两条真实链路上的落地契约。
//
// 解析器本身的语法矩阵在 test/utils/ruby_markup_test.dart；这里只守一件事，也是
// 整个改动的命门：**剥离必须发生在文本成为下游唯一坐标系之前**。
//
// gal hook 链路上，`entry.text` 同时是浮窗显示串、点字查词的 `wordFromIndex` 输入、
// 制卡 sentence 和字数统计输入，而 `_onLookupText` 有一道
// `entry.text != text`（native 回传串）的等值守卫。若在显示层才剥标记，这道守卫
// 会恒真，点字直接弹「行不可用」——所以剥离点必须在 appendLine。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/misc/ruby_markup.dart';

/// 断言注音区间确实落在该行纯文本的期望基准上。
void expectAlignedSpan(
  String text,
  List<RubySpan> spans,
  int index, {
  required String base,
  required String ruby,
}) {
  expect(spans.length, greaterThan(index), reason: '缺少第 $index 段注音：$spans');
  final RubySpan span = spans[index];
  expect(span.ruby, ruby);
  expect(
    text.substring(span.start, span.end),
    base,
    reason: 'span $span 没有落在 "$base" 上（文本 "$text"）',
  );
}

void main() {
  group('gal hook：TexthookerService.appendLine 是唯一剥离点', () {
    test('台词行存的是纯基准文本，注音落到旁路区间', () {
      final TexthookerService service = TexthookerService.test();
      final TexthookerLineEntry? entry = service.appendLine(
        '今もピリピリと空気を<rふる>震</r>わせている。',
        source: TexthookerLineSource.engineHook,
      );
      expect(entry, isNotNull);
      // 显示串 / 查词串 / 制卡 sentence 共用的这一份，必须已经没有标记。
      expect(entry!.text, '今もピリピリと空気を震わせている。');
      expectAlignedSpan(entry.text, entry.rubySpans, 0, base: '震', ruby: 'ふる');
    });

    test('无注音的行逐字不变（never break userspace）', () {
      final TexthookerService service = TexthookerService.test();
      const String raw = '良かれと思って案内役に優等生を選んでみたものの。';
      final TexthookerLineEntry? entry = service.appendLine(raw);
      expect(entry!.text, raw);
      expect(entry.rubySpans, isEmpty);
    });

    test('前后空白被 trim 后注音区间跟着平移', () {
      final TexthookerService service = TexthookerService.test();
      final TexthookerLineEntry? entry =
          service.appendLine('   <rふる>震</r>わせる   ');
      expect(entry!.text, '震わせる');
      expectAlignedSpan(entry.text, entry.rubySpans, 0, base: '震', ruby: 'ふる');
    });

    test('只剩标记的行仍按空行丢弃', () {
      final TexthookerService service = TexthookerService.test();
      expect(service.appendLine('<ruby><rt>ふる</rt></ruby>'), isNull);
    });

    test('copyWith（配音状态回写等）不得丢掉注音', () {
      final TexthookerService service = TexthookerService.test();
      final TexthookerLineEntry entry = service.appendLine('<rふる>震</r>')!;
      final TexthookerLineEntry updated = entry.copyWith(mined: true);
      expect(updated.mined, isTrue);
      expect(updated.rubySpans, entry.rubySpans);
    });

    test('剥离后的文本才是字数统计口径（注音假名不再被算成正文）', () {
      final TexthookerService service = TexthookerService.test();
      final TexthookerLineEntry entry = service.appendLine('空気を<rふる>震</r>わせる')!;
      // 若不剥标记，这行会多出 `<r`/`>`/`</r>` 与 `ふる` 两个假名。
      expect(entry.text.length, '空気を震わせる'.length);
    });
  });

  group('剪切板：DesktopLookupService 请求携带纯文本 + 注音区间', () {
    setUp(() => DesktopLookupService.instance.debugReset());
    tearDown(() => DesktopLookupService.instance.debugReset());

    test('剪贴板文本剥标记后进请求，区间对齐', () {
      DesktopLookupService.instance.processClipboardText('空気を<rふる>震</r>わせる');
      final DesktopLookupRequest? request =
          DesktopLookupService.instance.pendingRequest;
      expect(request, isNotNull);
      expect(request!.text, '空気を震わせる');
      expectAlignedSpan(request.text, request.rubySpans, 0,
          base: '震', ruby: 'ふる');
    });

    test('无注音时请求不带区间（native 走老渲染路径）', () {
      DesktopLookupService.instance.processClipboardText('ただの文章');
      final DesktopLookupRequest? request =
          DesktopLookupService.instance.pendingRequest;
      expect(request!.text, 'ただの文章');
      expect(request.rubySpans, isEmpty);
    });

    test('热键 / 点词来源同样收口（解析在 _queueLookupRequest 一处生效）', () {
      DesktopLookupService.instance.triggerLookup('<rふる>震</r>');
      final DesktopLookupRequest? request =
          DesktopLookupService.instance.pendingRequest;
      expect(request!.text, '震');
      expectAlignedSpan(request.text, request.rubySpans, 0,
          base: '震', ruby: 'ふる');
    });

    test('青空文庫式长文也认（剪贴板会喂到任意文本）', () {
      DesktopLookupService.instance
          .processClipboardText('その優等生《ゆうとうせい》はご機嫌ななめ。');
      final DesktopLookupRequest? request =
          DesktopLookupService.instance.pendingRequest;
      expect(request!.text, 'その優等生はご機嫌ななめ。');
      expectAlignedSpan(request.text, request.rubySpans, 0,
          base: '優等生', ruby: 'ゆうとうせい');
    });
  });
}
