import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

/// 同一 hook code 下有正文 / 名字牌两条 context 线程（RealLive `0x415b00` 实测），
/// 指纹相同、出行数相近；记忆恢复必须靠典型行长把正文挑回来。
TexthookerTextThread _thread(
  String key,
  List<String> previews, {
  int observed = 10,
  String hookCode = 'HS-14*@415B00',
}) => TexthookerTextThread(
  key: key,
  label: 'RealLive · 0x415b00 · #$key',
  lineCount: 0,
  latestAt: DateTime(2026, 9, 27),
  hookCode: hookCode,
  nativeThreadId: key.hashCode,
  previewText: previews.isEmpty ? null : previews.last,
  recentPreviewTexts: previews,
  observedLineCount: observed,
);

void main() {
  final TexthookerTextThread body = _thread('body', <String>[
    '俺は子供のように、自慢してしまっていた。',
    '「いいじゃないか。記念となる日を増やしていこう」',
    '「うん、いつもあるな」',
  ], observed: 8);
  final TexthookerTextThread name = _thread('name', <String>[
    '智代',
    '朋也',
    '智代',
  ], observed: 12);
  final String fingerprint = GalHookSessionController.textThreadFingerprint(
    body,
  )!;

  test('typical length is the median preview length', () {
    expect(GalHookSessionController.textThreadTypicalLength(name), 2);
    expect(GalHookSessionController.textThreadTypicalLength(body), 20);
    expect(
      GalHookSessionController.textThreadTypicalLength(
        _thread('empty', const <String>[]),
      ),
      isNull,
    );
  });

  test('restores the body thread even when the name thread has more lines', () {
    final TexthookerTextThread? picked =
        GalHookSessionController.pickRememberedTextThread(
          <TexthookerTextThread>[name, body],
          fingerprint: fingerprint,
          typicalLength: 20,
          minObservedLines: 3,
        );
    expect(picked?.key, 'body');
  });

  test('restores the name thread when that is what the user chose', () {
    final TexthookerTextThread? picked =
        GalHookSessionController.pickRememberedTextThread(
          <TexthookerTextThread>[name, body],
          fingerprint: fingerprint,
          typicalLength: 2,
          minObservedLines: 3,
        );
    expect(picked?.key, 'name');
  });

  test('waits instead of pinning a wildly different sibling', () {
    // 正文还没出够行数时，只剩名字牌候选：宁可暂不恢复。
    final TexthookerTextThread early = _thread('body', <String>[
      '俺は子供のように、自慢してしまっていた。',
    ], observed: 1);
    final TexthookerTextThread? picked =
        GalHookSessionController.pickRememberedTextThread(
          <TexthookerTextThread>[name, early],
          fingerprint: fingerprint,
          typicalLength: 20,
          minObservedLines: 3,
        );
    expect(picked, isNull);
  });

  test('legacy memory without a length falls back to the busiest thread', () {
    final TexthookerTextThread? picked =
        GalHookSessionController.pickRememberedTextThread(
          <TexthookerTextThread>[name, body],
          fingerprint: fingerprint,
          typicalLength: null,
          minObservedLines: 3,
        );
    expect(picked?.key, 'name');
  });

  test(
    'memory round-trips the typical length and clears it with the thread',
    () {
      const GalCaptureMemory memory = GalCaptureMemory(
        textThreadFingerprint: 'code:HS-14*@415B00',
        textThreadTypicalLength: 20,
      );
      final GalCaptureMemory back = GalCaptureMemory.fromJson(memory.toJson());
      expect(back.textThreadTypicalLength, 20);
      expect(
        back.copyWith(clearTextThread: true).textThreadTypicalLength,
        isNull,
      );
    },
  );
}
