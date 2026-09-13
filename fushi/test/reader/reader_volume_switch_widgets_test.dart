import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/reader/reader_gallery_page.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart' show EpubImageRef;

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
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
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

  group('ReaderGalleryPage volume chips', () {
    List<EpubImageRef> images(String prefix, int n) => <EpubImageRef>[
      for (int i = 0; i < n; i++)
        EpubImageRef(chapterIndex: i, orderInBook: i, src: '$prefix$i.png'),
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
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

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
