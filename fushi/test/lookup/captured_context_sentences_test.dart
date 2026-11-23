import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/captured_context_sentences.dart';
import 'package:fushi/src/lookup/selection_capture_ffi.dart';
import 'package:fushi/src/lookup/sentence_extraction.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';

/// 拍板台 rf--UcsGta：应用外查词「抓取上下文」的整段文本 → 高级制卡前后句。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CapturedSentenceContext split(String text, String term, {int? maxExpand}) {
    final int at = text.indexOf(term);
    expect(at, greaterThanOrEqualTo(0), reason: 'fixture must contain $term');
    return splitCapturedContext(
      contextText: text,
      selStart: at,
      selLen: term.length,
      maxExpand: maxExpand,
    )!;
  }

  group('splitCapturedContext', () {
    test('切出当前句与前后各句（阅读顺序），当前句与 extractSentenceAt 一致', () {
      const String text = '一つ目の文。二つ目の文！三つ目に猫がいる。四つ目？五つ目。';
      final CapturedSentenceContext c = split(text, '猫');
      expect(c.current, '三つ目に猫がいる。');
      expect(c.current, extractSentenceAt(text, text.indexOf('猫'), 1).sentence);
      expect(c.currentSelStart, '三つ目に'.length);
      expect(c.before, <String>['一つ目の文。', '二つ目の文！']);
      expect(c.after, <String>['四つ目？', '五つ目。']);
      expect(c.hasNeighbours, isTrue);
    });

    test('句末闭括号归前一句，前后句与当前句不重叠、不丢字', () {
      const String text = '「行こう。」彼は猫を見た。「待って！」';
      final CapturedSentenceContext c = split(text, '猫');
      expect(c.before.single, '「行こう。」');
      expect(c.current, '彼は猫を見た。');
      expect(c.after.single, '「待って！」');
      expect(<String>[...c.before, c.current, ...c.after].join(), text);
      // 与单句提取同一个切句器：当前句不再以上一句的「」」开头。
      expect(extractSentenceAt(text, text.indexOf('猫'), 1).sentence, '彼は猫を見た。');
    });

    test('换行也是句界；空白行不产生空句', () {
      const String text = '前の段落\n\n猫の段落\n\n後の段落';
      final CapturedSentenceContext c = split(text, '猫');
      expect(c.current, '猫の段落');
      expect(c.before, <String>['前の段落']);
      expect(c.after, <String>['後の段落']);
    });

    test('两端被 maxExpand 截断时丢掉贴边的半句', () {
      const String text = 'ちぎれた半句。完全な前文。猫がいる。完全な後文。ちぎれた後';
      final int at = text.indexOf('猫');
      final CapturedSentenceContext c = splitCapturedContext(
        contextText: text,
        selStart: at,
        selLen: 1,
        // 选区到两端的距离都 >= maxExpand：两端都是截断的。
        maxExpand: at,
      )!;
      expect(c.before, <String>['完全な前文。']);
      expect(c.after, <String>['完全な後文。']);
    });

    test('没截断（距离 < maxExpand）时贴边句完整保留', () {
      const String text = '最初の文。猫がいる。最後の文';
      final CapturedSentenceContext c = split(text, '猫', maxExpand: 600);
      expect(c.before, <String>['最初の文。']);
      expect(c.after, <String>['最後の文']);
    });

    test('截断端恰以句末标点收尾时最后一句是完整的', () {
      const String text = '猫がいる。次の文。';
      final CapturedSentenceContext c = splitCapturedContext(
        contextText: text,
        selStart: 0,
        selLen: 1,
        maxExpand: 2,
      )!;
      expect(c.after, <String>['次の文。']);
    });

    test('缓冲里只有一句：没有前后句（对话框保持原样）', () {
      final CapturedSentenceContext c = split('猫がいる。', '猫');
      expect(c.before, isEmpty);
      expect(c.after, isEmpty);
      expect(c.hasNeighbours, isFalse);
    });

    test('空缓冲 / 选区越界返回 null', () {
      expect(
        splitCapturedContext(contextText: '', selStart: 0, selLen: 1),
        isNull,
      );
      expect(
        splitCapturedContext(contextText: 'abc', selStart: 2, selLen: 5),
        isNull,
      );
      expect(
        splitCapturedContext(contextText: 'abc', selStart: 0, selLen: 0),
        isNull,
      );
    });

    test('around 取紧挨当前句的 N 句，超出时取到头', () {
      const CapturedSentenceContext c = CapturedSentenceContext(
        before: <String>['a', 'b', 'c'],
        current: 'X',
        after: <String>['d', 'e'],
      );
      final ({List<String> prev, List<String> next}) one = c.around(
        prevCount: 1,
        nextCount: 1,
      );
      expect(one.prev, <String>['c']);
      expect(one.next, <String>['d']);
      final ({List<String> prev, List<String> next}) all = c.around(
        prevCount: 9,
        nextCount: 9,
      );
      expect(all.prev, <String>['a', 'b', 'c']);
      expect(all.next, <String>['d', 'e']);
    });
  });

  group('SelectionCapture.contextFromCapture', () {
    test('抓取结果带上切好的前后句，当前句不变', () {
      const String text = '前の文。猫がいる。後の文。';
      final ForegroundSelectionContext ctx =
          SelectionCapture.contextFromCapture(
            source: 'UIA',
            contextText: text,
            selStart: text.indexOf('猫'),
            selLen: 1,
            elapsedMs: 0,
            maxExpand: 600,
          )!;
      expect(ctx.selectedText, '猫');
      expect(ctx.sentence, '猫がいる。');
      expect(ctx.sentences!.current, ctx.sentence);
      expect(ctx.sentences!.before, <String>['前の文。']);
      expect(ctx.sentences!.after, <String>['後の文。']);
    });
  });

  group('capturedContextSentenceSection', () {
    const CapturedSentenceContext context = CapturedSentenceContext(
      before: <String>['前一。', '前二。'],
      current: '猫がいる。',
      currentSelStart: 0,
      after: <String>['後一。', '後二。'],
    );

    test('setContext 把选中的前后句整体设进草稿，返回总句数', () async {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      final AdvancedMiningSentenceSection section =
          capturedContextSentenceSection(draft: draft, context: context);
      expect(await section.setContext(1, 2), 3);
      expect(draft.composeText(context.current), '前二。\n猫がいる。\n後一。\n後二。');
      // 再设一次是整体替换，不叠加。
      expect(await section.setContext(0, 1), 1);
      expect(draft.composeText(context.current), '猫がいる。\n後一。');
      // 超出可用句数时停在头（对话框据此判断到顶）。
      expect(await section.setContext(9, 9), 4);
    });

    test('fetchPreview 给出前文 / 当前句（带偏移）/ 后文', () async {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      final AdvancedMiningSentenceSection section =
          capturedContextSentenceSection(draft: draft, context: context);
      await section.setContext(1, 1);
      final Map<String, Object?> preview = await section.fetchPreview();
      expect(preview['prev'], <String>['前二。']);
      expect(preview['current'], '猫がいる。');
      expect(preview['currentOffset'], 0);
      expect(preview['next'], <String>['後一。']);
      expect(preview['total'], 2);
    });

    test('手改与移除落进草稿', () async {
      final MiningSentenceDraft draft = MiningSentenceDraft();
      final AdvancedMiningSentenceSection section =
          capturedContextSentenceSection(draft: draft, context: context);
      await section.setContext(2, 1);
      await section.removeSentence!(SentenceContextSlot.prev, 0, true);
      await section.editSentence!(SentenceContextSlot.next, 0, '後一（改）。');
      expect(draft.composeText(context.current), '前二。\n猫がいる。\n後一（改）。');
    });
  });

  group('withSurfaceSentenceSection', () {
    final AdvancedMiningSentenceSection surface =
        capturedContextSentenceSection(
          draft: MiningSentenceDraft(),
          context: const CapturedSentenceContext(
            before: <String>['a'],
            current: 'b',
            after: <String>[],
          ),
        );

    test('页面没给句子分区时补上表面级分区，其余分区原样保留', () {
      Future<void> closed() async {}
      final AdvancedMiningSections merged = withSurfaceSentenceSection(
        AdvancedMiningSections(onClosed: closed),
        surface,
      );
      expect(merged.sentence, same(surface));
      expect(merged.onClosed, same(closed));
    });

    test('页面自己的句子分区优先；表面级为 null 时原样返回', () {
      final AdvancedMiningSections page = AdvancedMiningSections(
        sentence: capturedContextSentenceSection(
          draft: MiningSentenceDraft(),
          context: const CapturedSentenceContext(
            before: <String>[],
            current: 'x',
            after: <String>[],
          ),
        ),
      );
      expect(withSurfaceSentenceSection(page, surface), same(page));
      expect(
        withSurfaceSentenceSection(AdvancedMiningSections.none, null),
        same(AdvancedMiningSections.none),
      );
    });
  });

  group('DesktopLookupService', () {
    setUp(() => DesktopLookupService.instance.debugReset());
    tearDown(() => DesktopLookupService.instance.debugReset());

    test('排队请求带上抓取上下文；不给时为 null', () {
      const CapturedSentenceContext context = CapturedSentenceContext(
        before: <String>['前。'],
        current: '猫。',
        after: <String>[],
      );
      expect(
        DesktopLookupService.instance.triggerLookup(
          '猫',
          capturedContext: context,
        ),
        isTrue,
      );
      expect(
        DesktopLookupService.instance.pendingRequest!.capturedContext,
        same(context),
      );
      DesktopLookupService.instance.triggerLookup('犬');
      expect(
        DesktopLookupService.instance.pendingRequest!.capturedContext,
        isNull,
      );
    });
  });
}
