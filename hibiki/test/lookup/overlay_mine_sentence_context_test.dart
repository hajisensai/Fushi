import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/overlay_bridge_handlers.dart';

/// BUG-730 — app-external mining (clipboard panel + transient global lookup)
/// created cards whose `{sentence}` field was ALWAYS empty. The full pipeline
/// (➕ button, mine bridge, term, word audio, duplicate, overwrite) worked, but
/// the SENTENCE never reached the mine context: `_mineEntry` read
/// `fields['sentence']`, JS `buildMinePayload` never sends a `sentence` field
/// for these surfaces, and the captured clipboard text / UIA line (already used
/// for the sentence banner) was never threaded into the mine call.
///
/// Fix: [maybeHandleOverlayDeferredBridge] takes a `sentenceContext`; each
/// controller passes its `_currentSentence`; [resolveMineSentence] uses it as
/// the mine/overwrite `{sentence}` fallback. The real end-to-end behaviour needs
/// a visible Windows overlay + a running Anki backend (no unit test can drive
/// it), so this file unit-tests the pure resolver + source-scans the wiring.
void main() {
  group('resolveMineSentence (pure) — BUG-730', () {
    test('empty JS field -> falls back to the surface sentence context', () {
      expect(
        resolveMineSentence(
          <String, String>{'expression': '勝負'},
          '今日は真剣勝負だ。',
        ),
        '今日は真剣勝負だ。',
        reason: 'JS 不发 sentence 时，制卡句子必须回落到剪贴板/UIA 捕获的句子',
      );
    });

    test('missing JS field key -> falls back to the surface sentence context',
        () {
      expect(
        resolveMineSentence(const <String, String>{}, 'クリップボード全文'),
        'クリップボード全文',
        reason: 'sentence 键缺席（当前 JS 现状）也必须回落，而不是空句',
      );
    });

    test('non-empty JS field wins over the fallback (future-proof)', () {
      expect(
        resolveMineSentence(
          <String, String>{'sentence': 'JS が送った文'},
          'クリップボード全文',
        ),
        'JS が送った文',
        reason: '若 JS 将来真发 sentence，尊重它，不被 context 覆盖',
      );
    });

    test('both empty -> empty (no crash, no synthetic sentence)', () {
      expect(resolveMineSentence(const <String, String>{}, ''), '');
    });
  });

  group('wiring guard — BUG-730', () {
    String read(String p) => File(p).readAsStringSync();

    test('mine + overwrite resolve the sentence via the shared fallback', () {
      final String handlers =
          read('lib/src/lookup/overlay_bridge_handlers.dart');
      expect(handlers.contains('String sentenceContext = '), isTrue,
          reason: 'maybeHandleOverlayDeferredBridge 必须暴露 sentenceContext');
      // 制卡与覆写两条路径都必须经共享 resolver（否则句子又回到恒空）。
      expect(
        'resolveMineSentence('.allMatches(handlers).length >= 2,
        isTrue,
        reason: '_mineEntry 与 _updateEntry 都必须用 resolveMineSentence 兜底句子',
      );
      // 制卡历史行必须用解析后的句子（不再 fields[\'sentence\'] 恒空）。
      expect(handlers.contains('sentence: sentence,'), isTrue,
          reason: '制卡卡片 AnkiMiningContext 用解析后的 sentence');
    });

    test('both overlay surfaces pass their captured _currentSentence', () {
      for (final String path in <String>[
        'lib/src/lookup/clipboard_panel_controller.dart',
        'lib/src/lookup/global_lookup_controller.dart',
      ]) {
        expect(
          read(path).contains('sentenceContext: _currentSentence'),
          isTrue,
          reason: '$path 必须把捕获到的句子传给制卡桥（否则该表面制卡句子恒空）',
        );
      }
    });
  });
}
