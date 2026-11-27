import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/reader/reader_status_bar.dart';
import 'package:fushi/src/reader/reader_status_bar_layout.dart';
import 'package:fushi/src/reader/reader_status_bar_layout_editor.dart';
import 'package:fushi/src/reader/reader_status_footer.dart';

/// 常驻页眉 / 页脚（反馈 JONk4qmF8V）：布局模型、读数文案、页脚并入读数胶囊、
/// 设置页编辑器。
void main() {
  group('ReaderStatusBarLayout', () {
    test('defaults show nothing (老用户升级后与现在一样)', () {
      final ReaderStatusBarLayout layout = ReaderStatusBarLayout.defaults;
      expect(layout.hasHeader, isFalse);
      expect(layout.hasFooter, isFalse);
      for (final ReaderStatusBarItem item in ReaderStatusBarItem.values) {
        expect(layout.shows(item), isFalse, reason: '$item 默认不显示');
      }
      expect(ReaderStatusBarLayout.decode(''), layout);
      expect(ReaderStatusBarLayout.decode('not json'), layout);
      expect(ReaderStatusBarLayout.decode('[1,2]'), layout);
    });

    test('encode / decode round-trips slot order', () {
      final ReaderStatusBarLayout layout = ReaderStatusBarLayout.fromSlots(
        const <ReaderStatusBarSlot, List<ReaderStatusBarItem>>{
          ReaderStatusBarSlot.headerLeft: <ReaderStatusBarItem>[
            ReaderStatusBarItem.chapterTitle,
          ],
          ReaderStatusBarSlot.headerRight: <ReaderStatusBarItem>[
            ReaderStatusBarItem.bookTitle,
          ],
          ReaderStatusBarSlot.footerLeft: <ReaderStatusBarItem>[
            ReaderStatusBarItem.battery,
            ReaderStatusBarItem.clock,
          ],
          ReaderStatusBarSlot.footerCenter: <ReaderStatusBarItem>[
            ReaderStatusBarItem.chapterPage,
          ],
        },
      );
      final ReaderStatusBarLayout decoded = ReaderStatusBarLayout.decode(
        layout.encode(),
      );
      expect(decoded, layout);
      expect(decoded.hasHeader, isTrue);
      expect(decoded.hasFooter, isTrue);
      expect(
        decoded.itemsIn(ReaderStatusBarSlot.footerLeft),
        <ReaderStatusBarItem>[
          ReaderStatusBarItem.battery,
          ReaderStatusBarItem.clock,
        ],
      );
      expect(decoded.shows(ReaderStatusBarItem.bookProgress), isFalse);
    });

    test('an item lives in one slot only (拖到别处 = 移动)', () {
      final ReaderStatusBarLayout layout = ReaderStatusBarLayout.fromSlots(
        const <ReaderStatusBarSlot, List<ReaderStatusBarItem>>{
          ReaderStatusBarSlot.headerLeft: <ReaderStatusBarItem>[
            ReaderStatusBarItem.clock,
          ],
          ReaderStatusBarSlot.footerRight: <ReaderStatusBarItem>[
            ReaderStatusBarItem.clock,
          ],
        },
      );
      expect(layout.itemsIn(ReaderStatusBarSlot.headerLeft), <Object>[
        ReaderStatusBarItem.clock,
      ]);
      expect(layout.itemsIn(ReaderStatusBarSlot.footerRight), isEmpty);

      final ControlLayout<ReaderStatusBarSlot, ReaderStatusBarItem> moved =
          layout.core.moveDraggedItem(
            const ControlDragData<ReaderStatusBarSlot, ReaderStatusBarItem>(
              item: ReaderStatusBarItem.clock,
              sourceSlot: ReaderStatusBarSlot.headerLeft,
              sourceIndex: 0,
            ),
            ReaderStatusBarSlot.footerCenter,
          );
      final ReaderStatusBarLayout next = ReaderStatusBarLayout.fromCore(moved);
      expect(next.hasHeader, isFalse);
      expect(next.itemsIn(ReaderStatusBarSlot.footerCenter), <Object>[
        ReaderStatusBarItem.clock,
      ]);
    });
  });

  group('readerStatusBarItemText', () {
    ReaderStatusBarData data({bool continuous = false, int? battery}) =>
        ReaderStatusBarData(
          now: DateTime(2026, 11, 26, 21, 7),
          continuous: continuous,
          batteryLevel: battery,
          chapterTitle: '第一章　吾輩は猫である',
          bookTitle: '吾輩は猫である',
          chapterPage: 12,
          chapterPageTotal: 38,
          chapterChars: 420,
          chapterCharsTotal: 1000,
          bookChars: 37000,
          bookCharsTotal: 100000,
        );

    test('formats every item', () {
      final ReaderStatusBarData d = data(battery: 78);
      String? text(ReaderStatusBarItem item) =>
          readerStatusBarItemText(item, d);
      expect(text(ReaderStatusBarItem.clock), '21:07');
      expect(text(ReaderStatusBarItem.battery), '78%');
      expect(text(ReaderStatusBarItem.chapterTitle), '第一章　吾輩は猫である');
      expect(text(ReaderStatusBarItem.bookTitle), '吾輩は猫である');
      expect(text(ReaderStatusBarItem.chapterPage), '12 / 38');
      expect(text(ReaderStatusBarItem.chapterProgress), contains('42'));
      expect(text(ReaderStatusBarItem.chapterChars), '420 / 1,000');
      expect(text(ReaderStatusBarItem.bookProgress), '37.0%');
      expect(text(ReaderStatusBarItem.bookChars), '37,000 / 100,000');
    });

    test('clock formatter is injectable (阅读器按系统 12 / 24 小时制)', () {
      expect(
        readerStatusBarItemText(
          ReaderStatusBarItem.clock,
          data(),
          formatClock: (DateTime d) => '${d.hour - 12}:07 PM',
        ),
        '9:07 PM',
      );
    });

    test('continuous mode has no pages: page item shows chapter progress', () {
      final ReaderStatusBarData d = data(continuous: true);
      expect(
        readerStatusBarItemText(ReaderStatusBarItem.chapterPage, d),
        readerStatusBarItemText(ReaderStatusBarItem.chapterProgress, d),
      );
    });

    test('missing data draws nothing instead of a placeholder', () {
      final ReaderStatusBarData empty = ReaderStatusBarData(
        now: DateTime(2026),
        continuous: false,
      );
      for (final ReaderStatusBarItem item in ReaderStatusBarItem.values) {
        if (item == ReaderStatusBarItem.clock) continue;
        expect(readerStatusBarItemText(item, empty), isNull, reason: '$item');
      }
    });

    test('slot text joins items in slot order', () {
      final ReaderStatusBarLayout layout = ReaderStatusBarLayout.fromSlots(
        const <ReaderStatusBarSlot, List<ReaderStatusBarItem>>{
          ReaderStatusBarSlot.footerLeft: <ReaderStatusBarItem>[
            ReaderStatusBarItem.clock,
            ReaderStatusBarItem.battery,
          ],
        },
      );
      expect(
        readerStatusBarSlotText(
          layout,
          ReaderStatusBarSlot.footerLeft,
          data(battery: 50),
        ),
        '21:07 50%',
      );
      expect(
        readerStatusBarSlotText(layout, ReaderStatusBarSlot.footerLeft, data()),
        '21:07',
        reason: '拿不到电量时只画时间',
      );
      expect(
        readerStatusBarSlotText(layout, ReaderStatusBarSlot.headerLeft, data()),
        isNull,
      );
    });
  });

  group('footer integration', () {
    test('footer slot items enable the footer even with readouts off', () {
      expect(
        readerStatusFooterEnabled(
          desktop: false,
          lyricsMode: false,
          showTimer: false,
          showProgress: false,
          showChars: false,
          showSpeed: false,
          hasSlotItems: true,
        ),
        isTrue,
      );
      expect(
        readerStatusFooterEnabled(
          desktop: false,
          lyricsMode: false,
          showTimer: false,
          showProgress: false,
          showChars: false,
          showSpeed: false,
        ),
        isFalse,
      );
    });

    Widget host({
      ({String? start, String? center, String? end})? slots,
      bool floating = false,
      bool showTimer = true,
      bool showProgress = true,
    }) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: ReaderStatusFooter(
            sessionTotals: () => (durationMs: 42000, chars: 0, active: true),
            currentChars: 37,
            totalChars: 100,
            showTimer: showTimer,
            showProgress: showProgress,
            showChars: false,
            showSpeed: false,
            textColor: Colors.white,
            backgroundColor: Colors.black,
            floating: floating,
            slotTexts: slots,
          ),
        ),
      ),
    );

    testWidgets('slot texts share one row with the readouts (不出现两条)', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(slots: (start: '21:07', center: '12 / 38', end: '本章 42%')),
      );
      expect(find.text('21:07'), findsOneWidget);
      expect(find.text('12 / 38'), findsOneWidget);
      expect(find.text('本章 42%'), findsOneWidget);
      expect(find.text('0:42'), findsOneWidget, reason: '读数胶囊仍在');
      expect(find.text('37.0%'), findsOneWidget);
      final double rowY = tester.getCenter(find.text('21:07')).dy;
      expect(tester.getCenter(find.text('0:42')).dy, closeTo(rowY, 1));
      expect(
        tester.getCenter(find.text('本章 42%')).dx,
        lessThan(tester.getCenter(find.text('0:42')).dx),
        reason: '右槽文字贴在读数左边',
      );
      expect(
        tester.getCenter(find.text('21:07')).dx,
        lessThan(tester.getCenter(find.text('12 / 38')).dx),
      );
    });

    testWidgets('floating style keeps the readouts in their pill', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(slots: (start: '21:07', center: null, end: null), floating: true),
      );
      expect(find.text('21:07'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('fushi_status_footer_pill')),
        findsOneWidget,
      );
    });

    testWidgets('readouts off: only the slot texts are drawn', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          slots: (start: '21:07', center: null, end: null),
          floating: true,
          showTimer: false,
          showProgress: false,
        ),
      );
      expect(find.text('21:07'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('fushi_status_footer_pill')),
        findsNothing,
      );
    });
  });

  group('editor', () {
    testWidgets('drag-and-drop editor shows header + footer slots', (
      WidgetTester tester,
    ) async {
      ReaderStatusBarLayout? written;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReaderStatusBarLayoutEditor(
                layout: ReaderStatusBarLayout.defaults,
                onLayoutChanged: (ReaderStatusBarLayout l) => written = l,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('reader-status-bar-editor-preview')),
        findsOneWidget,
      );
      for (final ReaderStatusBarSlot slot in <ReaderStatusBarSlot>[
        ...ReaderStatusBarSlot.headerSlots,
        ...ReaderStatusBarSlot.footerSlots,
      ]) {
        expect(
          find.byKey(
            ValueKey<String>(
              'reader-status-bar-edit-slot-${slot.storageValue}',
            ),
          ),
          findsOneWidget,
          reason: '$slot 放置区',
        );
      }
      expect(written, isNull);
    });
  });
}
