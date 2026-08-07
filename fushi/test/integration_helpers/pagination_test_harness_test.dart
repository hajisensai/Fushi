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
          'physicalMaxScroll': 17462.25,
          'minScroll': 12.125,
          'totalChars': 9000,
          'vertical': true,
        },
      );

      expect(state.scroll, 1234.75);
      expect(state.columnPitch, 582.482759);
      expect(state.pageSize, 582.482759);
      expect(state.maxScroll, 17474.482759);
      expect(state.physicalMaxScroll, 17462.25);
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

    test('accepts a nonzero minScroll only when it is on the absolute grid',
        () {
      const double minScroll = 2 * pitch;
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

    test('I1 rejects an arbitrary minScroll-relative grid', () {
      const double minScroll = 37.375;
      final List<PageData> pages = List<PageData>.generate(
        4,
        (int page) => _page(
          page: page,
          scroll: minScroll + page * pitch,
          pitch: pitch,
          minScroll: minScroll,
          maxScroll: minScroll + 3 * pitch,
          physicalMaxScroll: minScroll + 3 * pitch,
        ),
      );

      final List<InvariantViolation> violations = validateChapterScan(
        pages,
        expectedMarkerCount: 0,
      );

      expect(_violationsFor(violations, 'I1'), isNotEmpty,
          reason: 'minScroll 本身偏离 N*pitch 时，不得把它当任意新原点掩盖漂移');
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

    test('I1 accepts exactly 1px error from a nonzero minScroll grid', () {
      const double minScroll = 4 * pitch;
      const double expectedScroll = 4 * pitch;
      const double scroll = expectedScroll + 1;
      expect((scroll - expectedScroll).abs(), 1);

      final List<InvariantViolation> violations = validateChapterScan(
        <PageData>[
          _page(
            page: 2,
            scroll: scroll,
            pitch: pitch,
            minScroll: minScroll,
            maxScroll: expectedScroll + pitch,
          ),
          _page(
            page: 3,
            scroll: scroll + pitch,
            pitch: pitch,
            minScroll: minScroll,
            maxScroll: expectedScroll + pitch,
          ),
        ],
        expectedMarkerCount: 0,
      );

      expect(_violationsFor(violations, 'I1'), isEmpty);
    });

    test('I1 rejects error greater than 1px from a nonzero minScroll grid', () {
      const double minScroll = 2 * pitch;
      const double expectedScroll = 4 * pitch;
      const double scroll = expectedScroll + 1.001;

      final List<InvariantViolation> violations = validateChapterScan(
        <PageData>[
          _page(
            page: 2,
            scroll: scroll,
            pitch: pitch,
            minScroll: minScroll,
            maxScroll: scroll + pitch,
          ),
          _page(
            page: 3,
            scroll: scroll + pitch,
            pitch: pitch,
            minScroll: minScroll,
            maxScroll: scroll + pitch,
          ),
        ],
        expectedMarkerCount: 0,
      );

      expect(_violationsFor(violations, 'I1'), isNotEmpty);
    });

    test('I1 accepts an off-grid final page clamped to maxScroll', () {
      const double maxScroll = 2 * pitch - 123;
      final List<PageData> pages = <PageData>[
        _page(
          page: 0,
          scroll: 0,
          pitch: pitch,
          maxScroll: maxScroll,
        ),
        _page(
          page: 1,
          scroll: pitch,
          pitch: pitch,
          maxScroll: maxScroll,
        ),
        _page(
          page: 2,
          scroll: maxScroll,
          pitch: pitch,
          maxScroll: maxScroll,
        ),
      ];

      final List<InvariantViolation> violations = validateChapterScan(
        pages,
        expectedMarkerCount: 0,
      );

      expect(_violationsFor(violations, 'I1'), isEmpty);
    });

    test('I1 rejects an off-grid final page that is not the physical endpoint',
        () {
      const double maxScroll = 2 * pitch - 123;
      final List<PageData> pages = <PageData>[
        _page(
          page: 0,
          scroll: 0,
          pitch: pitch,
          maxScroll: maxScroll,
          physicalMaxScroll: maxScroll + 80,
        ),
        _page(
          page: 1,
          scroll: pitch,
          pitch: pitch,
          maxScroll: maxScroll,
          physicalMaxScroll: maxScroll + 80,
        ),
        _page(
          page: 2,
          scroll: maxScroll,
          pitch: pitch,
          maxScroll: maxScroll,
          physicalMaxScroll: maxScroll + 80,
        ),
      ];

      final List<InvariantViolation> violations = validateChapterScan(
        pages,
        expectedMarkerCount: 0,
      );

      expect(_violationsFor(violations, 'I1'), isNotEmpty,
          reason: '任意 metrics max 不得冒充浏览器真实 terminal clamp');
    });

    test('I1 requires the scan to start at minScroll and end at maxScroll', () {
      final List<PageData> pages = <PageData>[
        _page(
          page: 0,
          scroll: pitch,
          pitch: pitch,
          minScroll: 0,
          maxScroll: 3 * pitch,
        ),
        _page(
          page: 1,
          scroll: 2 * pitch,
          pitch: pitch,
          minScroll: 0,
          maxScroll: 3 * pitch,
        ),
      ];

      final List<InvariantViolation> violations = validateChapterScan(
        pages,
        expectedMarkerCount: 0,
      );

      expect(_violationsFor(violations, 'I1'), hasLength(2),
          reason: '只检查逐页对齐会漏掉未扫到章首/章尾');
    });

    test('I6 catches a greater-than-1px step error before the final page', () {
      const double badSecondPage = pitch + 1.25;
      const double finalPage = badSecondPage + pitch;
      final List<PageData> pages = <PageData>[
        _page(
          page: 0,
          scroll: 0,
          pitch: pitch,
          maxScroll: finalPage,
        ),
        _page(
          page: 1,
          scroll: badSecondPage,
          pitch: pitch,
          maxScroll: finalPage,
        ),
        _page(
          page: 2,
          scroll: finalPage,
          pitch: pitch,
          maxScroll: finalPage,
        ),
      ];

      final List<InvariantViolation> violations = validateChapterScan(
        pages,
        expectedMarkerCount: 0,
      );
      final List<InvariantViolation> i6 = _violationsFor(violations, 'I6');

      expect(i6, hasLength(1));
      expect(i6.single.pageNumber, 1, reason: '偏差发生在非末页 page 1');
    });
  });

  group('JavaScript probe keeps raw fractional mappings', () {
    const Map<String, List<String>> mappings = <String, List<String>>{
      'scroll': <String>[
        'scroll: scroll,',
        'scroll: Math.round(scroll),',
      ],
      'columnPitch': <String>[
        'columnPitch: ctx.pageSize,',
        'columnPitch: Math.round(ctx.pageSize),',
      ],
      'pageSize': <String>[
        'pageSize: ctx.pageSize,',
        'pageSize: Math.round(ctx.pageSize),',
      ],
      'maxScroll': <String>[
        'maxScroll: metrics.maxScroll,',
        'maxScroll: Math.round(metrics.maxScroll),',
      ],
      'physicalMaxScroll': <String>[
        'physicalMaxScroll: ctx.physicalMaxScroll,',
        'physicalMaxScroll: Math.round(ctx.physicalMaxScroll),',
      ],
      'minScroll': <String>[
        'minScroll: metrics.minScroll,',
        'minScroll: Math.round(metrics.minScroll),',
      ],
    };

    for (final MapEntry<String, List<String>> mapping in mappings.entries) {
      test('${mapping.key} remains raw', () {
        expect(paginationHarnessJs, contains(mapping.value.first));
        expect(paginationHarnessJs, isNot(contains(mapping.value.last)));
      });
    }
  });

  test('I3 rejects a tail marker that is only a clipped sliver', () {
    final List<PageData> pages = <PageData>[
      _page(
        page: 0,
        scroll: 0,
        pitch: 800,
        maxScroll: 0,
        markers: const <String>['m001', 'm002'],
        markerFractions: const <String, double>{
          'm001': 1,
          'm002': 0.12,
        },
      ),
    ];

    final List<InvariantViolation> violations = validateChapterScan(
      pages,
      expectedMarkerCount: 2,
    );

    final List<InvariantViolation> i3 = _violationsFor(violations, 'I3');
    expect(i3, hasLength(1));
    expect(i3.single.message, contains('m002'));
    expect(i3.single.message, contains('substantially visible'));
  });
}

PageData _page({
  required int page,
  required num scroll,
  required double pitch,
  required double maxScroll,
  double minScroll = 0,
  double? physicalMaxScroll,
  List<String> markers = const <String>[],
  Map<String, double> markerFractions = const <String, double>{},
}) {
  return PageData.fromJson(<String, dynamic>{
    'page': page,
    'markers': markers,
    'markerFractions': markerFractions,
    'state': <String, dynamic>{
      'scroll': scroll,
      'columnPitch': pitch,
      'pageSize': pitch,
      'maxScroll': maxScroll,
      'physicalMaxScroll': physicalMaxScroll ?? maxScroll,
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
