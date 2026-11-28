import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/banner/banner_picker_sheet.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// 「横幅…」面板：三个来源的分段、在线 / 书中候选网格、选中 → 写进
/// `item_images`（用户口径、上来源锁）、窄图先裁 16:9、链接与移除。M3E 与 Apple
/// （玻璃）两套设计系统都走一遍。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  // 最小 GIF：写侧判据只查 "GIF8" 头。
  final List<int> gif = <int>[
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0, 0, 0x3B, //
  ];
  // 1×1 透明 PNG（网格预览）。
  final Uint8List png = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
  ]);

  late FushiDatabase db;
  late Directory imagesDir;
  late Directory scratch;
  late ItemScrapeStore store;
  final ItemScrapeKey key = ItemScrapeKey(MediaKind.epub, 'uid-1');

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    imagesDir = Directory.systemTemp.createTempSync('banner_sheet_images_');
    scratch = Directory.systemTemp.createTempSync('banner_sheet_src_');
    store = ItemScrapeStore(db, imagesDirectory: imagesDir);
  });

  tearDown(() async {
    await db.close();
    imagesDir.deleteSync(recursive: true);
    scratch.deleteSync(recursive: true);
  });

  File scratchFile(String name) =>
      File(p.join(scratch.path, name))..writeAsBytesSync(gif);

  BannerCandidate candidate(
    String id, {
    String? label,
    int? width,
    int? height,
    String? url,
  }) => BannerCandidate(
    id: id,
    preview: MemoryImage(png),
    resolve: () async => scratchFile('$id.gif'),
    label: label,
    width: width,
    height: height,
    sourceUrl: url,
  );

  final List<File> cropped = <File>[];
  final List<String> downloads = <String>[];

  BannerPickerTarget target({
    ImageProvider? current,
    bool online = true,
    bool fromWork = true,
  }) => BannerPickerTarget(
    fromWorkLabel: t.media_banner_source_from_book,
    current: current,
    currentUserChosen: current != null,
    loadOnline: online
        ? () async => <BannerCandidate>[
            candidate(
              'anilist-1',
              label: 'AniList',
              width: 1900,
              height: 400,
              url: 'https://img.example/anilist.jpg',
            ),
            candidate(
              'mangabaka-2-0',
              label: 'MangaBaka',
              width: 2000,
              height: 800,
              url: 'https://img.example/mb.jpg',
            ),
          ]
        : null,
    loadFromWork: fromWork
        ? () async => <BannerCandidate>[
            candidate('book-12', label: 'Page 12', width: 2800, height: 2000),
          ]
        : null,
    attribution: (List<BannerCandidate> items) =>
        items.any((BannerCandidate c) => c.id.startsWith('mangabaka-'))
        ? t.book_scrape_mangabaka_attribution
        : null,
    apply: (File file, {String? sourceUrl}) async {
      await store.setUserImageFromFile(
        key,
        MediaImageKind.backdrop,
        file,
        sourceUrl: sourceUrl,
      );
    },
    clear: () => store.clearUserImage(key, MediaImageKind.backdrop),
    download: (String url) async {
      downloads.add(url);
      return scratchFile('dl.gif');
    },
    pickFile: () async => scratchFile('picked.gif'),
    crop: (BuildContext context, File file) async {
      final File out = File(p.join(scratch.path, 'cropped.gif'))
        ..writeAsBytesSync(gif);
      cropped.add(file);
      return out;
    },
    probeSize: (File file) async => (width: 1000, height: 1500),
  );

  setUp(() {
    cropped.clear();
    downloads.clear();
  });

  /// 起宿主并经 [showBannerPickerSheet] 打开面板；返回面板关掉时的结果。
  Future<List<bool>> open(
    WidgetTester tester,
    BannerPickerTarget target, {
    bool glass = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<bool> results = <bool>[];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glassDesign: glass,
          ).copyWith(platform: TargetPlatform.windows),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const ValueKey<String>('open'),
                  onPressed: () async => results.add(
                    await showBannerPickerSheet(
                      context: context,
                      target: target,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    return results;
  }

  /// 点一下，然后真实时间（落盘 / 写库的 IO）与帧交替推进，直到面板关掉
  /// （[results] 有值）；最后把关面板的转场推完。
  Future<void> tapAndSettleIo(
    WidgetTester tester,
    Finder finder,
    List<bool> results,
  ) async {
    await tester.tap(finder);
    for (int i = 0; i < 200 && results.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(results, isNotEmpty, reason: '面板应在写入后关掉');
    await tester.pumpAndSettle();
  }

  /// 分段按钮里的来源名（两套设计系统的分段各自排版，按文字找）。
  Finder segment(String label) => find.text(label);

  for (final bool glass in <bool>[false, true]) {
    final String system = glass ? 'Apple 玻璃' : 'M3E';

    testWidgets('$system：三个来源分段；在线网格带署名，选一张够宽的直接写入并上锁', (
      WidgetTester tester,
    ) async {
      final List<bool> results = await open(tester, target(), glass: glass);
      expect(segment(t.media_banner_source_online), findsOneWidget);
      expect(segment(t.media_banner_source_from_book), findsOneWidget);
      expect(segment(t.media_banner_source_file), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('banner-candidate-anilist-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('banner-candidate-mangabaka-2-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('banner-picker-attribution')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('banner-picker-remove')),
        findsNothing,
        reason: '没有当前横幅就不出移除',
      );

      await tapAndSettleIo(
        tester,
        find.byKey(const ValueKey<String>('banner-candidate-mangabaka-2-0')),
        results,
      );
      expect(cropped, isEmpty, reason: '比 16:9 宽的在线横幅原样用');
      expect(results, <bool>[true]);
      final List<ItemImageRow> rows = (await tester.runAsync(
        () => db.getItemImages(MediaKind.epub, 'uid-1'),
      ))!;
      expect(rows, hasLength(1));
      expect(rows.single.userChosen, isTrue);
      expect(rows.single.sourceUrl, 'https://img.example/mb.jpg');
      expect(File(rows.single.path).existsSync(), isTrue);
    });
  }

  testWidgets('书中：跨页比 16:9 窄，先进裁剪再写入', (WidgetTester tester) async {
    final List<bool> results = await open(tester, target());
    await tester.tap(segment(t.media_banner_source_from_book));
    await tester.pumpAndSettle();
    expect(find.text('Page 12'), findsOneWidget);
    await tapAndSettleIo(
      tester,
      find.byKey(const ValueKey<String>('banner-candidate-book-12')),
      results,
    );
    expect(cropped, hasLength(1));
    expect(p.basename(cropped.single.path), 'book-12.gif');
    expect(results, <bool>[true]);
    final List<ItemImageRow> rows = (await tester.runAsync(
      () => db.getItemImages(MediaKind.epub, 'uid-1'),
    ))!;
    expect(rows.single.userChosen, isTrue);
    expect(rows.single.sourceUrl, isNull);
  });

  testWidgets('在线模块关：不出「在线」分段，默认停在书中', (WidgetTester tester) async {
    await open(tester, target(online: false));
    expect(segment(t.media_banner_source_online), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('banner-candidate-book-12')),
      findsOneWidget,
    );
  });

  testWidgets('文件或链接：非 http(s) 链接报错不下载；合法链接下载、量尺寸、裁剪后写入', (
    WidgetTester tester,
  ) async {
    final List<bool> results = await open(tester, target());
    await tester.tap(segment(t.media_banner_source_file));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('banner-picker-file')),
      findsOneWidget,
    );
    final Finder field = find.descendant(
      of: find.byKey(const ValueKey<String>('banner-picker-link')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, 'ftp://nope/x.jpg');
    await tester.tap(
      find.byKey(const ValueKey<String>('banner-picker-link-use')),
    );
    await tester.pump();
    expect(find.text(t.media_banner_link_invalid), findsOneWidget);
    expect(downloads, isEmpty);

    await tester.enterText(field, 'https://img.example/x.jpg');
    await tapAndSettleIo(
      tester,
      find.byKey(const ValueKey<String>('banner-picker-link-use')),
      results,
    );
    expect(downloads, <String>['https://img.example/x.jpg']);
    expect(cropped, hasLength(1), reason: '链接图量出来是竖图，要裁');
    expect(results, <bool>[true]);
    final List<ItemImageRow> rows = (await tester.runAsync(
      () => db.getItemImages(MediaKind.epub, 'uid-1'),
    ))!;
    expect(rows.single.sourceUrl, 'https://img.example/x.jpg');
    expect(rows.single.userChosen, isTrue);
  });

  testWidgets('有当前横幅：显示预览与「你选的」，移除 = 清掉并解锁', (WidgetTester tester) async {
    await tester.runAsync(
      () => store.setUserImageFromFile(
        key,
        MediaImageKind.backdrop,
        scratchFile('mine.gif'),
      ),
    );
    final List<bool> results = await open(
      tester,
      target(current: MemoryImage(png)),
    );
    expect(
      find.byKey(const ValueKey<String>('banner-picker-current-locked')),
      findsOneWidget,
    );
    await tapAndSettleIo(
      tester,
      find.byKey(const ValueKey<String>('banner-picker-remove')),
      results,
    );
    expect(results, <bool>[true]);
    final List<ItemImageRow> rows = (await tester.runAsync(
      () => db.getItemImages(MediaKind.epub, 'uid-1'),
    ))!;
    expect(rows, isEmpty);
    expect(
      (await tester.runAsync(
        () => store.isUserChosen(key, MediaImageKind.backdrop),
      ))!,
      isFalse,
    );
  });
}
