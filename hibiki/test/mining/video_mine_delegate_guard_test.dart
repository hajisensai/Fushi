import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_scan_helpers.dart';

/// 源码扫描守卫（TODO-1000 Phase 0）：`_mineVideoCard` 委托 ImmersionMiningEngine 后，
/// 必须保住三条现有行为，给「零行为变更」立证据（防 documentTitle/记账/失败反馈回归）。
///
/// 扫描前先剥掉行注释：否则把 `final String? documentTitle = ...` 降级成注释、生产改回
/// 裸 `_title`，守卫仍会命中注释里的字面量而变绿（假绿）。
void main() {
  final String src = stripLineComments(
    File(
      'lib/src/pages/implementations/video_hibiki/lookup_mining.part.dart',
    ).readAsStringSync(),
  );

  test('delegate passes playlist documentTitle (TODO-761 guard)', () {
    final int mineStart =
        src.indexOf('Future<MinePopupResult> _mineVideoCard({');
    final int mineEnd =
        src.indexOf('Future<void> _recordMinedSentenceForVideo(', mineStart);
    expect(mineStart, greaterThanOrEqualTo(0));
    expect(mineEnd, greaterThan(mineStart));
    final String mineBody = src.substring(mineStart, mineEnd);
    expect(
      mineBody,
      contains(
        'final String? documentTitle = _videoMiningDocumentTitle();',
      ),
      reason:
          'queued mining must snapshot the playlist-aware title at tap time',
    );
    final int requestStart = mineBody.indexOf('ImmersionMiningRequest(');
    final int requestEnd =
        mineBody.indexOf('source: AnkiMiningSource.video', requestStart);
    expect(requestStart, greaterThanOrEqualTo(0));
    expect(requestEnd, greaterThan(requestStart));
    final String request = mineBody.substring(requestStart, requestEnd);
    expect(request, contains('documentTitle: documentTitle,'));
    expect(request, isNot(contains('documentTitle: _title,')));
  });

  test('accounting stays on describeMineOutcome().record, not hand-rolled', () {
    expect(src.contains('described.record'), isTrue);
    expect(src.contains('success && updateNoteId == null'), isFalse);
  });

  test('aborted branch still surfaces an OSD (no silent failure)', () {
    expect(RegExp(r'res\.aborted[\s\S]{0,200}_showOsd').hasMatch(src), isTrue);
  });
}
