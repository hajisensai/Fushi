import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/reader/lyrics_cue_search.dart';
import 'package:fushi/src/reader/reader_gallery_page.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiCircularProgressIndicator;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart'
    show EpubBook, EpubChapter, EpubImageRef;

import '../helpers/test_platform_services.dart';

/// BUG-2521：章节列表与插图画廊的「同合集卷」切换。
///
/// - 看别的卷 = 无感：只换面板 / 舞台内容（isolate 解析由页面层提供，这里用
///   completer 模拟），不触发任何切书回调。
/// - 点别的卷的章 / 「打开本卷」/ 「跳到此插图」= 带卷号的切书回调。
/// - 当前卷的行为与从前逐字相同（回调仍走原路）。
class _FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppModel _testAppModel(FushiDatabase db) {
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = AppModel(testPlatformServices())
    ..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });
  return appModel;
}

void main() {
  group('ReaderQuickSettingsSheet volume chips', () {
    Future<void> pumpSheet(
      WidgetTester tester, {
      required ReaderTocVolumeSwitch? volumeSwitch,
      required List<int> jumpedSections,
    }) async {
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      final AppModel model = _testAppModel(db);
      final ReaderSettings? previous = ReaderFushiSource.readerSettings;
      ReaderFushiSource.readerSettings = ReaderSettings(db)
        ..applyPrefsSnapshot(const <String, String>{});
      addTearDown(() => ReaderFushiSource.readerSettings = previous);

      const List<TtuTocEntry> toc = <TtuTocEntry>[
        TtuTocEntry(index: 0, label: 'Cur-1'),
        TtuTocEntry(index: 1, label: 'Cur-2'),
      ];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: Consumer(
                builder: (BuildContext context, WidgetRef ref, _) =>
                    ReaderQuickSettingsSheet(
                      controller: null,
                      toc: toc,
                      readerProgress: const (0, 2),
                      onJumpSection: (int index, String? _) async =>
                          jumpedSections.add(index),
                      onExitReader: () {},
                      webViewController: _FakeInAppWebViewController(),
                      appModel: model,
                      ref: ref,
                      isFushiReader: true,
                      presentation:
                          ReaderQuickSettingsPresentation.sideSheetNavigation,
                      onStyleChanged: () async {},
                      onThemeChanged: () async {},
                      volumeSwitch: volumeSwitch,
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('no volume context → no chips, toc unchanged', (
      WidgetTester tester,
    ) async {
      await pumpSheet(tester, volumeSwitch: null, jumpedSections: <int>[]);
      expect(
        find.byKey(const ValueKey<String>('reader-toc-volume-chips')),
        findsNothing,
      );
      expect(find.text('Cur-1'), findsOneWidget);
    });

    testWidgets(
      'peeking a sibling swaps the list without switching; tapping its '
      'chapter / open-row reports (volume, chapter?)',
      (WidgetTester tester) async {
        final List<int> jumped = <int>[];
        final List<(int, int?)> switched = <(int, int?)>[];
        final Completer<List<TtuTocEntry>> siblingToc =
            Completer<List<TtuTocEntry>>();
        int tocCalls = 0;
        await pumpSheet(
          tester,
          jumpedSections: jumped,
          volumeSwitch: ReaderTocVolumeSwitch(
            labels: const <String>['Vol 1', 'Vol 2'],
            currentIndex: 0,
            tocOf: (int volume) {
              tocCalls++;
              expect(volume, 1);
              return siblingToc.future;
            },
            onJump: (int volume, int? chapter) async =>
                switched.add((volume, chapter)),
          ),
        );
        final Finder chip1 = find.byKey(
          const ValueKey<String>('reader-toc-volume-chip-1'),
        );
        expect(chip1, findsOneWidget);
        expect(find.text('Cur-1'), findsOneWidget);

        // 切到第 2 卷：当前卷列表让位、装载中转圈、「打开本卷」行已在；没有切书。
        await tester.tap(chip1);
        await tester.pump();
        expect(tocCalls, 1);
        expect(find.text('Cur-1'), findsNothing);
        expect(find.byType(FushiCircularProgressIndicator), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('reader-toc-volume-open-1')),
          findsOneWidget,
        );
        expect(switched, isEmpty);

        siblingToc.complete(const <TtuTocEntry>[
          TtuTocEntry(index: 0, label: 'Sib-1'),
          TtuTocEntry(index: 3, label: 'Sib-4'),
          TtuTocEntry(index: 4, label: 'Sib-deep', depth: 2, parent: 'Sib-4'),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('Sib-1'), findsOneWidget);
        expect(find.text('Sib-4'), findsOneWidget);
        expect(find.text('Sib-deep'), findsNothing, reason: '兄弟卷只列顶层章');

        // 回到当前卷不重复解析、列表恢复。
        await tester.tap(
          find.byKey(const ValueKey<String>('reader-toc-volume-chip-0')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Cur-1'), findsOneWidget);
        expect(tocCalls, 1);
        // 当前卷的章仍走原回调，不走切书。
        await tester.tap(find.text('Cur-2'));
        await tester.pumpAndSettle();
        expect(jumped, <int>[1]);
        expect(switched, isEmpty);
      },
    );

    testWidgets('tapping a sibling chapter reports (volume, chapter)', (
      WidgetTester tester,
    ) async {
      final List<(int, int?)> switched = <(int, int?)>[];
      await pumpSheet(
        tester,
        jumpedSections: <int>[],
        volumeSwitch: ReaderTocVolumeSwitch(
          labels: const <String>['Vol 1', 'Vol 2'],
          currentIndex: 0,
          tocOf: (int _) async => const <TtuTocEntry>[
            TtuTocEntry(index: 0, label: 'Sib-1'),
            TtuTocEntry(index: 3, label: 'Sib-4'),
          ],
          onJump: (int volume, int? chapter) async =>
              switched.add((volume, chapter)),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-toc-volume-chip-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sib-4'));
      await tester.pumpAndSettle();
      expect(switched, <(int, int?)>[(1, 3)]);
    });

    testWidgets('open-this-volume row reports (volume, null)', (
      WidgetTester tester,
    ) async {
      final List<(int, int?)> switched = <(int, int?)>[];
      await pumpSheet(
        tester,
        jumpedSections: <int>[],
        volumeSwitch: ReaderTocVolumeSwitch(
          labels: const <String>['Vol 1', 'Vol 2'],
          currentIndex: 0,
          tocOf: (int _) async => const <TtuTocEntry>[],
          onJump: (int volume, int? chapter) async =>
              switched.add((volume, chapter)),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-toc-volume-chip-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-toc-volume-open-1')),
      );
      await tester.pumpAndSettle();
      expect(switched, <(int, int?)>[(1, null)]);
    });
  });

  group('ReaderQuickSettingsSheet volume chips: current volume centred', () {
    // 用户实报：合集十几卷时当前卷在行尾、要自己横滚才找得到。
    final List<String> labels = <String>[
      for (int i = 1; i <= 8; i++) '安達としまむら$i',
    ];

    ScrollPosition chipScroll(WidgetTester tester) => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('reader-toc-volume-chips')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;

    Future<void> pumpAt(WidgetTester tester, int current, Size surface) async {
      // 复用上一组的 harness：重新声明一份最小版本，避免把 group 间状态耦起来。
      await tester.binding.setSurfaceSize(surface);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      final AppModel model = _testAppModel(db);
      final ReaderSettings? previous = ReaderFushiSource.readerSettings;
      ReaderFushiSource.readerSettings = ReaderSettings(db)
        ..applyPrefsSnapshot(const <String, String>{});
      addTearDown(() => ReaderFushiSource.readerSettings = previous);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: Consumer(
                builder: (BuildContext context, WidgetRef ref, _) =>
                    ReaderQuickSettingsSheet(
                      controller: null,
                      toc: const <TtuTocEntry>[
                        TtuTocEntry(index: 0, label: 'Cur-1'),
                      ],
                      readerProgress: const (0, 1),
                      onJumpSection: (int _, String? __) async {},
                      onExitReader: () {},
                      webViewController: _FakeInAppWebViewController(),
                      appModel: model,
                      ref: ref,
                      isFushiReader: true,
                      presentation:
                          ReaderQuickSettingsPresentation.sideSheetNavigation,
                      onStyleChanged: () async {},
                      onThemeChanged: () async {},
                      volumeSwitch: ReaderTocVolumeSwitch(
                        labels: labels,
                        currentIndex: current,
                        tocOf: (int _) async => const <TtuTocEntry>[],
                        onJump: (int _, int? __) async {},
                      ),
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    double viewportCenterX(WidgetTester tester) => tester
        .getCenter(
          find.byKey(const ValueKey<String>('reader-toc-volume-chips')),
        )
        .dx;

    double chipCenterX(WidgetTester tester, int i) => tester
        .getCenter(find.byKey(ValueKey<String>('reader-toc-volume-chip-$i')))
        .dx;

    for (final Size surface in const <Size>[
      Size(400, 1600),
      Size(1000, 1600),
    ]) {
      testWidgets('middle volume → its chip is centred (${surface.width})', (
        WidgetTester tester,
      ) async {
        await pumpAt(tester, 4, surface);
        final ScrollPosition pos = chipScroll(tester);
        expect(
          pos.maxScrollExtent,
          greaterThan(0),
          reason: '8 卷的 chip 行在该宽度下必须溢出，否则测不出居中',
        );
        expect(pos.pixels, greaterThan(0));
        expect(chipCenterX(tester, 4), closeTo(viewportCenterX(tester), 1.0));
      });
    }

    testWidgets('third volume (user report) → centred on a phone-width panel', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, 2, const Size(400, 1600));
      expect(chipScroll(tester).pixels, greaterThan(0));
      expect(chipCenterX(tester, 2), closeTo(viewportCenterX(tester), 1.0));
    });

    testWidgets('first volume → row stays at the start edge', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, 0, const Size(400, 1600));
      expect(chipScroll(tester).pixels, 0);
    });

    testWidgets('last volume → row pinned to the end edge', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, 7, const Size(400, 1600));
      final ScrollPosition pos = chipScroll(tester);
      expect(pos.maxScrollExtent, greaterThan(0));
      expect(pos.pixels, pos.maxScrollExtent);
    });

    testWidgets('centring happens once: picking another chip does not scroll', (
      WidgetTester tester,
    ) async {
      await pumpAt(tester, 4, const Size(400, 1600));
      final ScrollPosition pos = chipScroll(tester);
      pos.jumpTo(0);
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-toc-volume-chip-0')),
      );
      await tester.pumpAndSettle();
      expect(pos.pixels, 0);
    });
  });

  group('ReaderQuickSettingsSheet lyrics-mode subtitle search', () {
    List<AudioCue> cues() => <AudioCue>[
      for (final String text in <String>[
        '桜が咲いた',
        'しまむらはアダチを見た',
        '体育館の二階',
        '安達はしまむらを見た',
      ])
        AudioCue()
          ..bookKey = 'b'
          ..chapterHref = 'c.xhtml'
          ..sentenceIndex = 0
          ..textFragmentId = ''
          ..text = text
          ..startMs = 0
          ..endMs = 1000
          ..audioFileIndex = 0,
    ];

    Future<void> pumpLyrics(
      WidgetTester tester, {
      required ReaderLyricsCueSearch? search,
      bool lyricsMode = true,
      EpubBook? epubBook,
      Future<void> Function(BookSearchResult, String)? onSearchJump,
    }) async {
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      final AppModel model = _testAppModel(db);
      final ReaderSettings? previous = ReaderFushiSource.readerSettings;
      ReaderFushiSource.readerSettings = ReaderSettings(db)
        ..applyPrefsSnapshot(const <String, String>{});
      addTearDown(() => ReaderFushiSource.readerSettings = previous);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: Consumer(
                builder: (BuildContext context, WidgetRef ref, _) =>
                    ReaderQuickSettingsSheet(
                      controller: null,
                      toc: const <TtuTocEntry>[
                        TtuTocEntry(index: 0, label: 'Cur-1'),
                      ],
                      readerProgress: const (0, 1),
                      onJumpSection: (int _, String? __) async {},
                      onExitReader: () {},
                      webViewController: _FakeInAppWebViewController(),
                      appModel: model,
                      ref: ref,
                      isFushiReader: true,
                      presentation:
                          ReaderQuickSettingsPresentation.sideSheetNavigation,
                      onStyleChanged: () async {},
                      onThemeChanged: () async {},
                      lyricsMode: lyricsMode,
                      lyricsCueSearch: search,
                      epubBook: epubBook,
                      onSearchJump: onSearchJump,
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final Finder searchTab = find.byKey(
      const ValueKey<String>('reader-nav-tab-search'),
    );

    testWidgets('lyrics mode without cue search: no search tab (as before)', (
      WidgetTester tester,
    ) async {
      await pumpLyrics(tester, search: null);
      expect(searchTab, findsNothing);
    });

    testWidgets(
      'lyrics mode: search tab appears; query hits cues through the shared '
      'normalisation; tapping a result reports that cue',
      (WidgetTester tester) async {
        final List<AudioCue> list = cues();
        final List<String> queries = <String>[];
        final List<AudioCue> jumped = <AudioCue>[];
        await pumpLyrics(
          tester,
          search: ReaderLyricsCueSearch(
            cues: list,
            search: (String q) async {
              queries.add(q);
              return searchLyricsCueTexts(<String>[
                for (final AudioCue c in list) c.text,
              ], q);
            },
            locationLabel: (AudioCue c) => 'Chapter X · 00:01',
            onJump: (AudioCue c) async => jumped.add(c),
          ),
        );
        expect(searchTab, findsOneWidget);
        await tester.tap(searchTab);
        await tester.pumpAndSettle();
        expect(find.text("Search this audiobook's subtitles"), findsOneWidget);

        await tester.enterText(find.byType(EditableText), 'シマムラ');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(queries, <String>['シマムラ']);
        expect(
          find.byKey(const ValueKey<String>('lyrics_search_result_0')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('lyrics_search_result_1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey<String>('lyrics_search_result_2')),
          findsNothing,
        );
        expect(find.text('Chapter X · 00:01'), findsNWidgets(2));
        expect(
          find.byKey(const ValueKey<String>('lyrics_search_truncated')),
          findsNothing,
        );

        await tester.tap(
          find.byKey(const ValueKey<String>('lyrics_search_result_1')),
        );
        await tester.pumpAndSettle();
        expect(jumped, hasLength(1));
        expect(identical(jumped.single, list[3]), isTrue);
      },
    );

    testWidgets(
      'non-lyrics mode unchanged: book search tab with the book hint',
      (WidgetTester tester) async {
        await pumpLyrics(
          tester,
          search: null,
          lyricsMode: false,
          epubBook: EpubBook(
            title: 'Book',
            chapters: <EpubChapter>[
              EpubChapter(
                id: 'a',
                href: 'a.xhtml',
                mediaType: 'x',
                html: '<p>a</p>',
              ),
            ],
          ),
          onSearchJump: (BookSearchResult _, String __) async {},
        );
        expect(searchTab, findsOneWidget);
        await tester.tap(searchTab);
        await tester.pumpAndSettle();
        expect(
          find.text('Search the whole book, or jump to a character position'),
          findsOneWidget,
        );
        expect(find.text("Search this audiobook's subtitles"), findsNothing);
      },
    );

    testWidgets('more hits than the cap → truncation note', (
      WidgetTester tester,
    ) async {
      final List<AudioCue> list = <AudioCue>[
        for (int i = 0; i < 3; i++)
          AudioCue()
            ..bookKey = 'b'
            ..chapterHref = 'c.xhtml'
            ..sentenceIndex = i
            ..textFragmentId = ''
            ..text = 'しまむら$i'
            ..startMs = 0
            ..endMs = 1
            ..audioFileIndex = 0,
      ];
      await pumpLyrics(
        tester,
        search: ReaderLyricsCueSearch(
          cues: list,
          search: (String q) async => searchLyricsCueTexts(
            <String>[for (final AudioCue c in list) c.text],
            q,
            limit: 2,
          ),
          locationLabel: (AudioCue _) => '',
          onJump: (AudioCue _) async {},
        ),
      );
      await tester.tap(searchTab);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'しまむら');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Showing the first 2 of 3 matches'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('lyrics_search_result_1')),
        findsOneWidget,
      );
    });
  });

  group('ReaderGalleryPage volume chips', () {
    List<EpubImageRef> images(String prefix, int n) => <EpubImageRef>[
      for (int i = 0; i < n; i++)
        EpubImageRef(
          chapterIndex: i,
          orderInBook: i,
          src: '$prefix$i.png',
          revealKey: '$prefix$i.png',
        ),
    ];

    testWidgets(
      'peeking a sibling swaps the stage; jump / open route through the '
      'volume callbacks; current volume keeps its own callbacks',
      (WidgetTester tester) async {
        final List<EpubImageRef> jumpedCurrent = <EpubImageRef>[];
        final List<(int, String)> jumpedVolume = <(int, String)>[];
        final List<(int, String)> openedVolume = <(int, String)>[];
        final Completer<ReaderGalleryVolumeImages> sibling =
            Completer<ReaderGalleryVolumeImages>();
        final Directory dir = Directory.systemTemp.createTempSync(
          'reader_gallery_vol_',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final File fake = File('${dir.path}/s0.png')..writeAsBytesSync(<int>[]);

        await tester.pumpWidget(
          MaterialApp(
            home: ReaderGalleryPage(
              images: images('c', 2),
              currentChapter: 0,
              fileForRef: (_) => null,
              onOpenImage: (_) {},
              onJumpTo: jumpedCurrent.add,
              volumeSwitch: ReaderGalleryVolumeSwitch(
                labels: const <String>['Vol 1', 'Vol 2'],
                currentIndex: 0,
                imagesOf: (int volume) {
                  expect(volume, 1);
                  return sibling.future;
                },
                onJumpTo: (int v, EpubImageRef ref) =>
                    jumpedVolume.add((v, ref.src)),
                onOpenImage: (int v, EpubImageRef ref, File _) =>
                    openedVolume.add((v, ref.src)),
              ),
            ),
          ),
        );
        await tester.pump();
        // 网格形态：c0 已读到、c1 在当前章之后锁着 → 已解锁 1 / 2。
        expect(find.text('Unlocked 1 / 2'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('reader-gallery-volume-chips')),
          findsOneWidget,
        );

        // 当前卷：点已解锁卡进查看器，「跳到此插图」仍走原回调。
        await tester.tap(
          find.byKey(const ValueKey<String>('fushi_gallery_card_c0.png')),
        );
        await tester.pumpAndSettle();
        expect(find.text('1 / 1'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey<String>('fushi_gallery_jump')),
        );
        expect(jumpedCurrent.single.src, 'c0.png');
        expect(jumpedVolume, isEmpty);

        // 查看器盖住整页（含卷 chip 行），先 Esc 关掉再切卷。
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey<String>('reader-gallery-volume-chip-1')),
        );
        await tester.pump();
        // 装载中主体转圈。
        expect(find.byType(FushiLoadingView), findsOneWidget);

        sibling.complete(
          ReaderGalleryVolumeImages(
            images: images('s', 3),
            fileForRef: (EpubImageRef ref) => ref.src == 's0.png' ? fake : null,
          ),
        );
        await tester.pumpAndSettle();
        // 兄弟卷没有阅读进度：全部视为已解锁，也没有「当前阅读位置」与过滤 / 定位。
        expect(find.text('Unlocked 3 / 3'), findsOneWidget);
        expect(find.text('Current reading position'), findsNothing);
        expect(
          find.byKey(const ValueKey<String>('fushi_gallery_position')),
          findsNothing,
        );

        await tester.tap(
          find.byKey(const ValueKey<String>('fushi_gallery_card_s0.png')),
        );
        await tester.pumpAndSettle();
        expect(find.text('1 / 3'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey<String>('fushi_gallery_jump')),
        );
        expect(jumpedVolume, <(int, String)>[(1, 's0.png')]);
        expect(jumpedCurrent.length, 1);

        // Enter 打开兄弟卷大图 → 带卷号与该卷文件的回调。
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(openedVolume, <(int, String)>[(1, 's0.png')]);

        // 回到当前卷：网格恢复本书插图与解锁判据。
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey<String>('reader-gallery-volume-chip-0')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Unlocked 1 / 2'), findsOneWidget);
      },
    );
  });
}
