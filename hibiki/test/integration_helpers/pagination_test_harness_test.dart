import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/helpers/pagination_test_harness.dart';

void main() {
  group('PaginationState', () {
    test('preserves raw fractional pagination geometry', () {
      final PaginationState state = PaginationState.fromJson(
        <String, dynamic>{
          'scroll': 1234.75,
          'columnPitch': 582.482759,
          'pageSize': 582.482759,
          'maxScroll': 17474.482759,
          'minScroll': 12.125,
          'totalChars': 9000,
          'vertical': true,
        },
      );

      expect(state.scroll, 1234.75);
      expect(state.columnPitch, 582.482759);
      expect(state.pageSize, 582.482759);
      expect(state.maxScroll, 17474.482759);
      expect(state.minScroll, 12.125);
    });
  });

  group('validateChapterScan fractional grid', () {
    const double pitch = 582.482759;

    test('accepts 30 browser-floor page positions without I1 or I6 failures',
        () {
      final List<PageData> pages = List<PageData>.generate(
        30,
        (int page) => _page(
          page: page,
          scroll: (page * pitch).floor(),
          pitch: pitch,
          maxScroll: (29 * pitch).floorToDouble(),
        ),
      );

      final List<InvariantViolation> violations = validateChapterScan(
        pages,
        expectedMarkerCount: 0,
      );

      expect(_violationsFor(violations, 'I1'), isEmpty);
      expect(_violationsFor(violations, 'I6'), isEmpty);
    });

    test('anchors the nearest fractional grid to minScroll', () {
      const double minScroll = 37.375;
      final List<PageData> pages = List<PageData>.generate(
        4,
        (int page) => _page(
          page: page,
          scroll: minScroll + (page * pitch).floor(),
          pitch: pitch,
          minScroll: minScroll,
          maxScroll: minScroll + (3 * pitch).floor(),
        ),
      );

      final List<InvariantViolation> violations = validateChapterScan(
        pages,
        expectedMarkerCount: 0,
      );

      expect(_violationsFor(violations, 'I1'), isEmpty);
    });

    test('I1 catches a cumulative integer-pitch grid', () {
      final List<PageData> pages = List<PageData>.generate(
        30,
        (int page) => _page(
          page: page,
          scroll: page * pitch.floor(),
          pitch: pitch,
          maxScroll: 29 * pitch.floorToDouble(),
        ),
      );

      final List<InvariantViolation> violations = validateChapterScan(
        pages,
        expectedMarkerCount: 0,
      );

      expect(_violationsFor(violations, 'I1'), isNotEmpty);
    });
  });

  test('JavaScript probe keeps scroll and page size fractional', () {
    expect(paginationHarnessJs, isNot(contains('Math.round(scroll)')));
    expect(paginationHarnessJs, isNot(contains('Math.round(ctx.pageSize)')));
  });
}

PageData _page({
  required int page,
  required num scroll,
  required double pitch,
  required double maxScroll,
  double minScroll = 0,
}) {
  return PageData.fromJson(<String, dynamic>{
    'page': page,
    'markers': <String>[],
    'state': <String, dynamic>{
      'scroll': scroll,
      'columnPitch': pitch,
      'pageSize': pitch,
      'maxScroll': maxScroll,
      'minScroll': minScroll,
      'totalChars': 0,
      'vertical': true,
    },
  });
}

List<InvariantViolation> _violationsFor(
  List<InvariantViolation> violations,
  String invariant,
) {
  return violations
      .where((InvariantViolation violation) => violation.invariant == invariant)
      .toList();
}
