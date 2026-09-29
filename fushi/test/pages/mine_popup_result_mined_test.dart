import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi_anki/fushi_anki.dart';

/// [MinePopupResult.mined]：「收下了」的两种结局给弹窗的信号必须不同。
///
/// 进了待发制卡队列的卡此刻不在 Anki 里：若按成功返回 `ankiConnect:true`，popup.js 会
/// 回查 Anki 查重、查不到就把按钮翻回「+」，诱导用户再制一张。
void main() {
  test('进了待发队列 → queued：画 ✓、不回查 Anki、没有 note id', () {
    final MinePopupResult r = MinePopupResult.mined(const MineOutcome.queued());
    expect(r.queued, isTrue);
    expect(r.ankiConnect, isFalse);
    expect(r.noteId, isNull);
  });

  test('真的进了 Anki → ankiConnect 带回 note id', () {
    final MinePopupResult r = MinePopupResult.mined(
      const MineOutcome.success(noteId: 42),
    );
    expect(r.queued, isFalse);
    expect(r.ankiConnect, isTrue);
    expect(r.noteId, 42);
  });
}
