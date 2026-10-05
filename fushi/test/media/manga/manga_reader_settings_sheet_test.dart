import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_settings_panel_kit.dart';
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

  Widget host(MangaReaderSettingsSheet sheet, {double? width = 400}) =>
      MaterialApp(
        home: Scaffold(
          body: width == null ? sheet : SizedBox(width: width, child: sheet),
        ),
      );

  Finder tabLabel(int tab) =>
      find.byKey(ValueKey<String>('manga_settings_tab_label_$tab'));

  Finder tabScrollable(int tab) => find
      .descendant(
        of: find.byKey(PageStorageKey<String>('manga_settings_tab_$tab')),
        matching: find.byType(Scrollable),
      )
      .first;

  testWidgets('download-ahead switch persists a sparse override', (
    WidgetTester tester,
  ) async {
    Map<String, Object?> saved = <String, Object?>{};
    await tester.pumpWidget(
      host(
        MangaReaderSettingsSheet(
          globalDefaults: const MangaReaderPreferences(),
          overrides: saved,
          onChanged: (Map<String, Object?> next) async => saved = next,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder row = find.text('Download next chapter while reading');
    await tester.scrollUntilVisible(row, 200, scrollable: tabScrollable(0));
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
      host(
        MangaReaderSettingsSheet(
          globalDefaults: const MangaReaderPreferences(),
          overrides: saved,
          onChanged: (Map<String, Object?> next) async => saved = next,
        ),
        width: null,
      ),
    );
    await tester.pumpAndSettle();
    final Finder restore = find.byKey(
      const ValueKey<String>('manga_reader_restore'),
    );
    expect(restore, findsOneWidget);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(find.text('Use global default'), findsOneWidget);
  });

  testWidgets('tabs expose filters and persist values without closing', (
    WidgetTester tester,
  ) async {
    Map<String, Object?> saved = <String, Object?>{};
    await tester.pumpWidget(
      host(
        MangaReaderSettingsSheet(
          globalDefaults: const MangaReaderPreferences(),
          overrides: saved,
          onChanged: (Map<String, Object?> next) async => saved = next,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    await tester.tap(tabLabel(2));
    await tester.pumpAndSettle();
    // 滤镜页顶是实时预览卡。
    expect(find.byType(MangaPanelFilterPreview), findsOneWidget);
    await tester.tap(find.text('Invert colors'));
    await tester.pumpAndSettle();
    expect(saved['invertColors'], true);
    expect(find.byType(MangaReaderSettingsSheet), findsOneWidget);
    final MangaPanelFilterPreview preview = tester
        .widget<MangaPanelFilterPreview>(find.byType(MangaPanelFilterPreview));
    expect(preview.invert, isTrue);
  });

  testWidgets(
    'changes made while a save is in flight are queued, not dropped',
    (WidgetTester tester) async {
      // 保存一次要整窗重载：早先保存中直接 return，键盘 / 滑条在这段时间里的改动
      // 被静默丢掉。第一笔卡住时再改一项，放行后两项都必须落库。
      final List<Map<String, Object?>> calls = <Map<String, Object?>>[];
      final Completer<void> firstSave = Completer<void>();
      await tester.pumpWidget(
        host(
          MangaReaderSettingsSheet(
            globalDefaults: const MangaReaderPreferences(),
            overrides: const <String, Object?>{},
            onChanged: (Map<String, Object?> next) async {
              calls.add(next);
              if (calls.length == 1) await firstSave.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(tabLabel(2));
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
    },
  );

  testWidgets('out-of-range synced slider values are clamped, not asserted', (
    WidgetTester tester,
  ) async {
    // 偏好解析允许 readerHideThreshold 取 0（同步 / 旧版本写入），滑条下限是 1。
    await tester.pumpWidget(
      host(
        MangaReaderSettingsSheet(
          globalDefaults: const MangaReaderPreferences(),
          overrides: const <String, Object?>{'readerHideThreshold': 0},
          onChanged: (Map<String, Object?> next) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(tabLabel(1));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Reader hide threshold (px)'),
      200,
      scrollable: tabScrollable(1),
    );
    expect(tester.takeException(), isNull);
    final Finder row = find.byWidgetPredicate(
      (Widget w) =>
          w is AdaptiveSettingsSliderRow &&
          w.title == 'Reader hide threshold (px)',
    );
    expect(row, findsOneWidget);
    final AdaptiveSettingsSliderRow slider = tester
        .widget<AdaptiveSettingsSliderRow>(row);
    expect(slider.value, 1);
    expect(slider.readout, '1');
  });

  testWidgets('failed reset restores overrides and reports failure', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        MangaReaderSettingsSheet(
          globalDefaults: const MangaReaderPreferences(),
          overrides: const <String, Object?>{'showPageNumber': false},
          onChanged: (Map<String, Object?> next) async =>
              throw StateError('write failed'),
        ),
        width: null,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('manga_reader_restore')),
    );
    await tester.pumpAndSettle();
    // 回滚后仍是「当前作品」覆盖态：副标题不是「使用全局默认」。
    expect(find.text('Use global default'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every descriptor is reachable on some tab of a narrow sheet', (
    WidgetTester tester,
  ) async {
    // 视口拉高，让每页 ListView 一次建出全部行（懒加载不会漏掉屏外的行）。
    tester.view.physicalSize = const Size(320, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        MangaReaderSettingsSheet(
          globalDefaults: const MangaReaderPreferences(),
          overrides: const <String, Object?>{},
          onChanged: (Map<String, Object?> next) async {},
        ),
        width: null,
      ),
    );
    await tester.pumpAndSettle();
    final Set<String> seen = <String>{};
    final List<MangaReaderPreferenceDescriptor> all =
        mangaReaderPreferenceDescriptors(const <String>{});
    for (int tab = 0; tab < 4; tab++) {
      await tester.tap(tabLabel(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'tab $tab overflowed');
      for (final MangaReaderPreferenceDescriptor d in all) {
        final Finder title = find.descendant(
          of: find.byKey(PageStorageKey<String>('manga_settings_tab_$tab')),
          matching: find.textContaining(d.title),
        );
        if (title.evaluate().isNotEmpty) seen.add(d.key);
      }
    }
    expect(seen, <String>{
      for (final MangaReaderPreferenceDescriptor d in all) d.key,
    });
  });

  testWidgets('list leaves room for the floating scope bar', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        MangaReaderSettingsSheet(
          globalDefaults: const MangaReaderPreferences(),
          overrides: const <String, Object?>{},
          onChanged: (Map<String, Object?> next) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ListView list = tester.widget<ListView>(
      find.byKey(const PageStorageKey<String>('manga_settings_tab_0')),
    );
    final EdgeInsets padding = list.padding! as EdgeInsets;
    final Rect bar = tester.getRect(
      find.byKey(const ValueKey<String>('manga_reader_scope')),
    );
    final Rect sheet = tester.getRect(find.byType(MangaReaderSettingsSheet));
    expect(padding.bottom, greaterThanOrEqualTo(sheet.bottom - bar.top));
  });

  testWidgets('global scope writes a sparse patch and leaves overrides alone', (
    WidgetTester tester,
  ) async {
    final List<Map<String, Object?>> overrides = <Map<String, Object?>>[];
    final List<Map<String, Object?>> patches = <Map<String, Object?>>[];
    await tester.pumpWidget(
      host(
        MangaReaderSettingsSheet(
          globalDefaults: const MangaReaderPreferences(),
          overrides: const <String, Object?>{},
          onChanged: (Map<String, Object?> next) async => overrides.add(next),
          onGlobalChanged: (Map<String, Object?> patch) async =>
              patches.add(patch),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Global'));
    await tester.pumpAndSettle();
    await tester.tap(tabLabel(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invert colors'));
    await tester.pumpAndSettle();
    expect(patches, <Map<String, Object?>>[
      <String, Object?>{'invertColors': true},
    ]);
    expect(overrides, isEmpty);
  });
}
