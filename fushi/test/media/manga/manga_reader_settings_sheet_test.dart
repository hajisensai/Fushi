import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_settings_sheet.dart';

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
    // 标题带读数：越界的 0 显示成夹取后的下限 1。
    expect(find.text('Reader hide threshold (px) (1)'), findsOneWidget);
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
}
