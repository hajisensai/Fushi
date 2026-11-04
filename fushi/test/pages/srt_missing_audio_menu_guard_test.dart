import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 反馈 IHgBrvHizT：「音频文件丢失」书卡必须在书架卡菜单里就能处理（不用进书），
/// 且不随听书模块门控——以前唯一出路「重新定位」挂在 `ModuleId.listening` 后面，
/// 关了听书模块就彻底关不掉提示。
void main() {
  final String src = File(
    'lib/src/pages/implementations/reader_history/books.part.dart',
  ).readAsStringSync();

  String section(String start, String end) {
    final int a = src.indexOf(start);
    expect(a, isNonNegative, reason: 'anchor missing: $start');
    final int b = src.indexOf(end, a);
    expect(b, greaterThan(a), reason: 'anchor missing: $end');
    return src.substring(a, b);
  }

  test('card meta warning honours the dismissal', () {
    final String card = section(
      'Widget _buildSrtCard(',
      '  _ShelfMetaSpec _srtBookMeta(',
    );
    expect(card, contains('_srtMissingAudio.showsWarning(book)'));
  });

  test('shelf card menu carries the missing-audio actions, ungated', () {
    final String menu = section(
      'List<DialogAction> _srtExtraActions(',
      '  Future<void> _addSrtToCollection(',
    );
    final RegExp spread = RegExp(
      r'\n      \.\.\._srtMissingAudioActions\(dialogContext, book\),',
    );
    expect(
      spread.hasMatch(menu),
      isTrue,
      reason: '处置项须作为卡菜单顶层项展开，不能套在 listening 门控里',
    );
    final String actions = section(
      'List<DialogAction> _srtMissingAudioActions(',
      '  Future<void> _runSrtMissingAudioAction(',
    );
    expect(actions, isNot(contains('ModuleId.')));
    for (final String key in <String>[
      'audiobook_missing_audio_dismiss_action',
      'audiobook_missing_audio_undismiss_action',
      'audiobook_missing_audio_convert_action',
      'audiobook_missing_audio_restore_action',
    ]) {
      expect(actions, contains('t.$key'));
    }
  });
}
