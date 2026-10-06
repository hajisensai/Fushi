import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_settings_sheet.dart';
import 'package:fushi/utils.dart';

void main() {
  test('descriptor list gates device settings and preserves every mode', () {
    final List<MangaReaderPreferenceDescriptor> descriptors =
        mangaReaderPreferenceDescriptors(<String>{});
    expect(
      descriptors.any(
        (MangaReaderPreferenceDescriptor d) => d.key == 'fullscreen',
      ),
      isFalse,
    );
    final MangaReaderPreferenceDescriptor mode = descriptors.firstWhere(
      (MangaReaderPreferenceDescriptor d) => d.key == 'mode',
    );
    expect(
      mode.choices,
      containsAll(<String>[
        'spread',
        'paged_vertical',
        'webtoon',
        'webtoon_gaps',
      ]),
    );
    expect(
      mangaReaderPreferenceDescriptors(<String>{
        'fullscreen',
      }).any((MangaReaderPreferenceDescriptor d) => d.key == 'fullscreen'),
      isTrue,
    );
  });

  test('only chapter-navigation switches the reader honours are exposed', () {
    // skipFiltered / alwaysShowChapterTransition 没有任何读取方：没有章节过滤
    // 可跳、没有章节过渡页。显示了却不生效的开关不得回到面板上。
    final Set<String> keys = <String>{
      for (final MangaReaderPreferenceDescriptor d
          in mangaReaderPreferenceDescriptors(<String>{}))
        d.key,
    };
    expect(keys, containsAll(<String>['skipRead', 'skipDuplicate']));
    expect(keys, contains('downloadAhead'));
    expect(keys, isNot(contains('skipFiltered')));
    expect(keys, isNot(contains('alwaysShowChapterTransition')));
  });

  testWidgets('download-ahead switch persists a sparse override', (
    WidgetTester tester,
  ) async {
    Map<String, Object?> saved = <String, Object?>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: MangaReaderSettingsSheet(
              globalDefaults: const MangaReaderPreferences(),
              overrides: saved,
              onChanged: (Map<String, Object?> next) async => saved = next,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder row = find.text('Download next chapter while reading');
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey<String>('manga_settings_tab_0')),
        matching: find.byType(Scrollable),
      ).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(saved, <String, Object?>{'downloadAhead': false});
  });

  testWidgets('sheet shows inherited state and reset clears sparse override', (
    WidgetTester tester,
  ) async {
    Map<String, Object?> saved = <String, Object?>{'showPageNumber': false};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaReaderSettingsSheet(
            globalDefaults: const MangaReaderPreferences(),
            overrides: saved,
            onChanged: (Map<String, Object?> next) async => saved = next,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This title'), findsOneWidget);
    expect(find.text('Restore all global defaults'), findsOneWidget);
    await tester.tap(find.text('Restore all global defaults'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(find.text('Use global default'), findsOneWidget);
  });
  testWidgets(
    'desktop tabs expose filters and persist values without closing',
    (WidgetTester tester) async {
      Map<String, Object?> saved = <String, Object?>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: MangaReaderSettingsSheet(
                globalDefaults: const MangaReaderPreferences(),
                overrides: saved,
                onChanged: (Map<String, Object?> next) async => saved = next,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      await tester.ensureVisible(find.text('Custom filter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom filter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Invert colors'));
      await tester.pumpAndSettle();
      expect(saved['invertColors'], true);
      expect(find.byType(MangaReaderSettingsSheet), findsOneWidget);
      expect(find.text('This title'), findsOneWidget);
    },
  );

  testWidgets('changes made while a save is in flight are queued, not dropped', (
    WidgetTester tester,
  ) async {
    // 保存一次要整窗重载：早先保存中直接 return，键盘 / 滑条在这段时间里的改动
    // 被静默丢掉。第一笔卡住时再改一项，放行后两项都必须落库。
    final List<Map<String, Object?>> calls = <Map<String, Object?>>[];
    final Completer<void> firstSave = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: MangaReaderSettingsSheet(
              globalDefaults: const MangaReaderPreferences(),
              overrides: const <String, Object?>{},
              onChanged: (Map<String, Object?> next) async {
                calls.add(next);
                if (calls.length == 1) await firstSave.future;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom filter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invert colors'));
    await tester.pump();
    await tester.tap(find.text('Grayscale'));
    await tester.pump();
    expect(calls, hasLength(1));
    firstSave.complete();
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
    expect(calls.last, <String, Object?>{
      'invertColors': true,
      'grayscale': true,
    });
  });

  testWidgets('out-of-range synced slider values are clamped, not asserted', (
    WidgetTester tester,
  ) async {
    // 偏好解析允许 readerHideThreshold 取 0（同步 / 旧版本写入），滑条下限是 1。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: MangaReaderSettingsSheet(
              globalDefaults: const MangaReaderPreferences(),
              overrides: const <String, Object?>{'readerHideThreshold': 0},
              onChanged: (Map<String, Object?> next) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('General'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Reader hide threshold (px)'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(
              const PageStorageKey<String>('manga_settings_tab_1'),
            ),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.takeException(), isNull);
    // 读数：越界的 0 显示成夹取后的下限 1（MD3 下读数常驻在滑条右侧，
    // 不再拼进标题）。
    final Finder row = find.byWidgetPredicate(
      (Widget w) =>
          w is AdaptiveSettingsSliderRow &&
          w.title == 'Reader hide threshold (px)',
    );
    expect(row, findsOneWidget);
    final AdaptiveSettingsSliderRow slider =
        tester.widget<AdaptiveSettingsSliderRow>(row);
    expect(slider.value, 1);
    expect(slider.readout, '1');
    expect(find.descendant(of: row, matching: find.text('1')), findsOneWidget);
  });

  testWidgets('failed reset restores overrides and reports failure', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaReaderSettingsSheet(
            globalDefaults: const MangaReaderPreferences(),
            overrides: const <String, Object?>{'showPageNumber': false},
            onChanged: (Map<String, Object?> next) async =>
                throw StateError('write failed'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore all global defaults'));
    await tester.pumpAndSettle();
    expect(find.text('This title'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('BUG-2912: choice dropdowns span the narrow sheet, not a sliver', (
    WidgetTester tester,
  ) async {
    // 侧栏 400px、窄屏更窄：下拉跟标题并排时只分到一百来像素，「Right to left」
    // 「Fit screen」被直接裁掉。下拉必须放到标题下方、拿到整行宽度——每个标签都
    // 要看：TabBarView 只建当前页，不逐个切过去就只测得到第一页。
    // 视口拉高，让每页 ListView 一次建出全部行（懒加载不会漏掉屏外的行）。
    tester.view.physicalSize = const Size(320, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaReaderSettingsSheet(
            globalDefaults: const MangaReaderPreferences(),
            overrides: const <String, Object?>{},
            onChanged: (Map<String, Object?> next) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Set<String> checked = <String>{};
    final List<Tab> tabs = tester.widgetList<Tab>(find.byType(Tab)).toList();
    expect(tabs, hasLength(4));
    for (int tab = 0; tab < tabs.length; tab++) {
      await tester.tap(find.byWidget(tabs[tab]));
      await tester.pumpAndSettle();
      final Finder rows = find.descendant(
        of: find.byKey(PageStorageKey<String>('manga_settings_tab_$tab')),
        matching: find.byType(AdaptiveSettingsPickerRow<String>),
      );
      for (final Element row in rows.evaluate()) {
        final AdaptiveSettingsPickerRow<String> widget =
            row.widget as AdaptiveSettingsPickerRow<String>;
        expect(widget.controlBelow, isTrue, reason: widget.title);
        final Finder field = find
            .descendant(
              of: find.byWidget(widget),
              matching: find.byType(InputDecorator),
            )
            .first;
        expect(
          tester.getSize(field).width,
          greaterThanOrEqualTo(260),
          reason: widget.title,
        );
        checked.add(widget.title);
      }
    }
    // 防空循环：每个下拉行（取色是文本框，不走下拉）都必须被某个标签页查到。
    final Set<String> expected = <String>{
      for (final MangaReaderPreferenceDescriptor d
          in mangaReaderPreferenceDescriptors(const <String>{}))
        if (d.kind == MangaReaderPreferenceKind.choice &&
            d.key != 'colorFilterColor')
          d.title,
    };
    expect(expected, isNotEmpty);
    expect(checked, expected);
  });

  testWidgets('BUG-2912: footer keeps the reset button on the right', (
    WidgetTester tester,
  ) async {
    // 一行放得下：状态贴左、按钮贴右；放不下：上下叠放，按钮仍贴右——旧的
    // Wrap(spaceBetween) 折行后按钮独占一个 run，被摆到了左边。
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> pumpAt(double width) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 600,
                child: MangaReaderSettingsSheet(
                  globalDefaults: const MangaReaderPreferences(),
                  overrides: const <String, Object?>{'showPageNumber': false},
                  onChanged: (Map<String, Object?> next) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final Finder status = find.text('This title');
    final Finder button = find.widgetWithText(
      TextButton,
      'Restore all global defaults',
    );

    await pumpAt(1000);
    expect(tester.getSize(find.byType(MangaReaderSettingsSheet)).width, 1000);
    expect(tester.getRect(status).left, 16);
    expect(tester.getRect(button).right, 1000 - 8);
    expect(
      tester.getCenter(button).dy,
      moreOrLessEquals(tester.getCenter(status).dy),
    );

    // 宽度介于「按钮自身」与「状态 + 按钮」之间：必须折行。
    final double statusWidth = tester.getSize(status).width;
    final double buttonWidth = tester.getSize(button).width;
    final double width = 16 + 8 + buttonWidth + statusWidth / 2;
    await pumpAt(width);
    expect(
      tester.getRect(button).top,
      greaterThanOrEqualTo(tester.getRect(status).bottom),
      reason: 'footer should have wrapped at width $width',
    );
    expect(tester.getRect(button).right, moreOrLessEquals(width - 8));
  });
}
