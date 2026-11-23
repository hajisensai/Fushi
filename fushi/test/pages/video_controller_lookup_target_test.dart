import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show capSubtitleLookupTerm, lookupHighlightGraphemeCount;

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 视频页的手柄查词目标（`video_fushi/controller_lookup.part.dart`，2026-11-22 手柄
/// 查词统一，docs/specs/2026-11-22-gamepad-lookup-unification-design.md）。
///
/// 纯逻辑：选区右端上限截查询串（[capSubtitleLookupTerm]）。页面接线（目标要经
/// 页面私有态，无法脱离整页实例化）以源码断言钉住：
///  * lookupAtCursor 走点击查词同链路并把上限透传到 `_lookupAt`，返回命中长度；
///  * 查词后光标留在字幕上（手柄查词模式持有光标时不 transfer 进弹窗）；
///  * enterResult 才 transfer；手柄只接管弹窗面上的光标。
void main() {
  group('capSubtitleLookupTerm（选区右端上限）', () {
    test('null = 不截（交给词典最长匹配）', () {
      expect(capSubtitleLookupTerm('食べられない', null), '食べられない');
    });

    test('截到前 N 个字素', () {
      expect(capSubtitleLookupTerm('食べられない', 1), '食');
      expect(capSubtitleLookupTerm('食べられない', 3), '食べら');
    });

    test('上限不小于串长时原样返回', () {
      expect(capSubtitleLookupTerm('食べる', 3), '食べる');
      expect(capSubtitleLookupTerm('食べる', 10), '食べる');
    });

    test('上限至少 1 个字素', () {
      expect(capSubtitleLookupTerm('食べる', 0), '食');
      expect(capSubtitleLookupTerm('食べる', -2), '食');
    });

    test('按字素截：组合浊点 / emoji 不被劈开', () {
      // か + U+3099（组合浊点）= 一个字素「が」。
      const String combining = 'がくせい';
      expect(capSubtitleLookupTerm(combining, 1), 'が');
      expect(capSubtitleLookupTerm('👍🏽いい', 1), '👍🏽');
    });

    test('截后的命中长度与高亮同口径（字素数）', () {
      final String capped = capSubtitleLookupTerm('がくせい', 2);
      // 引擎按码点回报：「が」= 2 码点 + 「く」1 码点 = 3。
      expect(lookupHighlightGraphemeCount(capped, 3), 2);
    });

    test('空串原样', () {
      expect(capSubtitleLookupTerm('', 2), '');
    });
  });

  group('页面接线（源码）', () {
    final String src = maskComments(readVideoFushiSource());

    test('lookupAtCursor 走点击查词链路并透传上限、返回命中长度', () {
      final String body = methodBody(
        src,
        'Future<int> lookupAtCursor({int? maxGraphemes}) async {',
      );
      expect(body, contains('return _s._handleSubtitleLookupTap('));
      expect(body, contains('maxGraphemes: maxGraphemes'));
      expect(
        body,
        contains('_s._caretOnSubtitleSurface'),
        reason: '光标已进弹窗时不再从字幕查词',
      );

      final String tap = methodBody(
        src,
        'Future<int> _handleSubtitleLookupTap(',
      );
      expect(tap, contains('maxGraphemes: maxGraphemes'));
      expect(tap, contains('return _lookupAt('));

      final String lookupAt = methodBody(src, 'Future<int> _lookupAt(');
      expect(
        lookupAt,
        contains('capSubtitleLookupTerm(span.term, maxGraphemes)'),
        reason: '上限只截查询串，其余链路（热槽复用、暂停、锚点）不变',
      );
      expect(lookupAt, contains('replaceStack: true'));
      expect(lookupAt, contains('reuseWarmSlot: true'));
      expect(lookupAt, contains('return graphemeCount;'));
    });

    test('查词后光标留在字幕上：模式持有光标时不 transfer 进弹窗', () {
      final String rendered = methodBody(
        src,
        'void onNestedPopupRendered(int index) {',
      );
      final int gate = rendered.indexOf(
        'if (_controllerLookupHoldsCaret) return;',
      );
      final int transfer = rendered.indexOf(
        '_videoCaret.onDictionaryPopupRendered(index)',
      );
      expect(gate, isNonNegative);
      expect(transfer, greaterThan(gate));

      final String holds = methodBody(
        src,
        'bool get _controllerLookupHoldsCaret {',
      );
      expect(holds, contains('mode.active'));
      expect(holds, contains('identical(mode.target, target)'));
      expect(
        holds,
        contains('_caretOnSubtitleSurface'),
        reason: '进入结果之后（光标在弹窗上）嵌套查词仍要跟到新顶层',
      );
    });

    test('enterResult 才把光标交给页内弹窗；没有页内弹窗（副屏查词）时不动', () {
      final String body = methodBody(src, 'Future<void> enterResult() async {');
      expect(body, contains('_s.caretTopPopupState'));
      expect(body, contains('if (popup == null) return;'));
      expect(body, contains('_s._videoCaret.transferToTopPopup(popup)'));
      expect(
        methodBody(src, 'bool get routerOwnsInput =>'),
        contains('!_s._videoCaret.onPopup'),
      );
    });

    test('graphemesFromCursor 按查询串（查词起点到句尾）计', () {
      final String body = methodBody(src, 'int get graphemesFromCursor {');
      expect(body, contains('subtitleLookupSpan('));
      expect(body, contains('.term.characters.length'));
    });

    test('步进不查词；不留 TODO(gamepad-unify)', () {
      final String step = methodBody(
        src,
        'Future<void> stepCursor(int dir, {required bool word}) async {',
      );
      expect(step, isNot(contains('_handleSubtitleLookupTap(')));
      expect(step, isNot(contains('CaretAction.lookup')));
      expect(readVideoFushiSource(), isNot(contains('TODO(gamepad-unify)')));
    });

    test('整句扫词已删除', () {
      final String raw = readVideoFushiSource();
      expect(raw, isNot(contains('_runWordSweepAction')));
      expect(raw, isNot(contains('_WordSweepState')));
      expect(raw, isNot(contains('videoLookupNextWord')));
      expect(raw, isNot(contains('videoLookupPrevWord')));
    });
  });
}
