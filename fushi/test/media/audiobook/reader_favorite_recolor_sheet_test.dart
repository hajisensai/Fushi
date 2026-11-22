import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/reader/reader_panel_kit.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// BUG-5081：书内导航「收藏」行的「改颜色」入口——展开五个色点，点一个就把
/// (收藏, 颜色) 交给页面落库，本行色条立即换成新颜色。
AppModel _testAppModel() {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final Directory tmpDir = Directory.systemTemp.createTempSync(
    'fushi_favorite_recolor_',
  );
  final AppModel appModel = AppModel(testPlatformServices())
    ..themeNotifier = themeNotifier
    ..wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(db),
      databaseDirectory: tmpDir,
    );
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
    tmpDir.deleteSync(recursive: true);
  });
  return appModel;
}

void main() {
  testWidgets('收藏行改颜色：展开色点、点粉色回调页面、色条换色、色点收起', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FavoriteSentence fav = FavoriteSentence(
      id: 'hl_recolor',
      text: 'A highlighted sentence from the current book.',
      bookTitle: 'Current Book',
      chapterLabel: 'Chapter 1',
      sectionIndex: 1,
      normCharOffset: 120,
      color: 'yellow',
      createdAt: DateTime(2026, 5, 25, 12),
    );
    final List<(String, String)> recolored = <(String, String)>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  ReaderQuickSettingsSheet(
                    controller: null,
                    toc: const [],
                    readerProgress: const (1, 2),
                    onJumpSection: (_, __) async {},
                    onExitReader: () {},
                    appModel: _testAppModel(),
                    ref: ref,
                    favoriteSentences: <FavoriteSentence>[fav],
                    onJumpToFavorite: (_) async {},
                    onDeleteFavorite: (_) async {},
                    onRecolorFavorite: (FavoriteSentence f, String c) async =>
                        recolored.add((f.id, c)),
                    isFushiReader: true,
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.text(t.section_navigation));
    await tester.tap(find.text(t.section_navigation));
    await tester.pumpAndSettle();

    Color accent() => tester
        .widget<ReaderQuoteCard>(
          find.byKey(const ValueKey<String>('in_book_favorite_hl_recolor')),
        )
        .accent!;
    expect(accent(), isNot(const Color(0xFFFF4081)));

    final Finder pink = find.byKey(
      const ValueKey<String>('in_book_favorite_color_hl_recolor_pink'),
    );
    expect(pink, findsNothing, reason: '改色前不展开色点');
    await tester.ensureVisible(find.byTooltip(t.reader_favorite_recolor));
    await tester.tap(find.byTooltip(t.reader_favorite_recolor));
    await tester.pumpAndSettle();
    expect(pink, findsOneWidget);

    await tester.tap(pink);
    await tester.pumpAndSettle();

    expect(recolored, <(String, String)>[('hl_recolor', 'pink')]);
    expect(accent(), const Color(0xFFFF4081));
    expect(pink, findsNothing, reason: '选完颜色收起色点');
    expect(tester.takeException(), isNull);
  });

  testWidgets('页面没接改色回调时收藏行不出「改颜色」', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  ReaderQuickSettingsSheet(
                    controller: null,
                    toc: const [],
                    readerProgress: const (1, 2),
                    onJumpSection: (_, __) async {},
                    onExitReader: () {},
                    appModel: _testAppModel(),
                    ref: ref,
                    favoriteSentences: <FavoriteSentence>[
                      FavoriteSentence(
                        text: 'No recolor here.',
                        bookTitle: 'Current Book',
                        sectionIndex: 1,
                        createdAt: DateTime(2026, 5, 25, 12),
                      ),
                    ],
                    onDeleteFavorite: (_) async {},
                    isFushiReader: true,
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.text(t.section_navigation));
    await tester.tap(find.text(t.section_navigation));
    await tester.pumpAndSettle();
    expect(find.textContaining('No recolor here.'), findsOneWidget);
    expect(find.byTooltip(t.reader_favorite_recolor), findsNothing);
  });
}
