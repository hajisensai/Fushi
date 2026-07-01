import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫（TODO-1000 Phase 0）：`_mineVideoCard` 委托 ImmersionMiningEngine 后，
/// 必须保住三条现有行为，给「零行为变更」立证据（防 documentTitle/记账/失败反馈回归）。
void main() {
  final String src = File(
    'lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart',
  ).readAsStringSync();

  test('delegate passes playlist documentTitle (TODO-761 guard)', () {
    expect(src.contains('documentTitle: _videoMiningDocumentTitle()'), isTrue);
  });

  test('accounting stays on describeMineOutcome().record, not hand-rolled', () {
    expect(src.contains('described.record'), isTrue);
    expect(src.contains('success && updateNoteId == null'), isFalse);
  });

  test('aborted branch still surfaces an OSD (no silent failure)', () {
    expect(RegExp(r'res\.aborted[\s\S]{0,200}_showOsd').hasMatch(src), isTrue);
  });
}
