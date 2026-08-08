import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeShellTabNotifier, HomeTab;
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/ttu_filename.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_book_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late AppModel appModel;
  late _FakeRemoteBookClient remoteClient;
  late List<File> importedFiles;
  late File remoteBookCover;
  // 注入的本地 EPUB bookKey（importer 返回它，音频导入据此作 bookKeyOverride）。
  late String? importedBookKey;
  // 有声书接线观测：fetcher 收到的远端 bookKey + importer 收到的 (file, override)。
  late List<String> fetchedAudiobookKeys;
  late List<({File package, String? bookKeyOverride})> importedAudiobooks;
  // BUG-990：本地 SRT 卡受控列表（默认空）+ 有声书下载闸门（非空时 fetcher 卡住，
  // 用来观测两阶段下载空窗期本地卡的加载覆盖层）。
  late List<SrtBook> shelfSrtBooks;
  Completer<void>? audiobookDownloadGate;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_book_store');
    remoteBookCover = File('${storeDir.path}/remote-book-cover.png')
      ..writeAsBytesSync(_tinyPngBytes);
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    remoteClient = _FakeRemoteBookClient(coverPath: remoteBookCover.path);
    importedFiles = <File>[];
    importedBookKey = 'local-book-key';
    fetchedAudiobookKeys = <String>[];
    importedAudiobooks = <({File package, String? bookKeyOverride})>[];
    shelfSrtBooks = <SrtBook>[];
    audiobookDownloadGate = null;
  });

  tearDown(() async {
    // BUG-992：全局 tab notifier 跨测试持久，复位避免污染其它用例。
    homeShellTabNotifier.value = HomeTab.books;
    await db.close();
  });

  Widget buildApp({bool mangaOnly = false}) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(
              const <MediaItem>[],
            ),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(shelfSrtBooks),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) =>
                child ?? const SizedBox.shrink(),
            home: Scaffold(
              body: ReaderFushiHistoryPage(
                mangaOnly: mangaOnly,
                remoteBookClientLoader: () async => remoteClient,
                remoteBookDownloadDestination: (RemoteBookInfo book) async =>
                    File(
                  '${pathProviderDir.path}/${book.title.hashCode}.epub',
                ),
                remoteBookImporter: (File file) async {
                  importedFiles.add(file);
                  return importedBookKey;
                },
                remoteAudiobookFetcher: (String remoteBookKey) async {
                  fetchedAudiobookKeys.add(remoteBookKey);
                  // BUG-990：闸门非空时卡在有声书下载阶段（模拟空窗期），供断言本地卡
                  // 加载覆盖层；测试 complete 后放行。
                  if (audiobookDownloadGate != null) {
                    await audiobookDownloadGate!.future;
                  }
                  final File pkg = File(
                    '${pathProviderDir.path}/$remoteBookKey.hibikiaudio',
                  );
                  await pkg.writeAsBytes(<int>[9, 9, 9]);
                  return pkg;
                },
                remoteAudiobookImporter:
                    (File package, String? bookKeyOverride) async {
                  importedAudiobooks.add(
                    (package: package, bookKeyOverride: bookKeyOverride),
                  );
                },
              ),
            ),
          ),
        ),
      );

  testWidgets('bookshelf mixes interconnect remote books into the main grid',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 多端库联合视图（spec §2.1，撤独立远端分区）：远端书以占位卡混排进主网格——
    // 卡片在、带云角标 ☁、右上角保留下载按钮（能力未丢失）。
    expect(find.text('Remote Book'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>(
        'remote_book_cloud_badge_Remote_Book',
      )),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>(
        'remote_book_download_Remote_Book',
      )),
      findsOneWidget,
    );

    final String source =
        File('lib/src/pages/implementations/reader_fushi_history_page.dart')
            .readAsStringSync();
    expect(source, isNot(contains('浏览电脑')));
    expect(source.toLowerCase(), isNot(contains('computer')));
  });

  testWidgets(
      'cloud backend remote books also mix into the main grid as placeholders',
      (WidgetTester tester) async {
    // 撤独立远端分区后不再有「互联 vs 云端」分区文案区分——云盘后端
    // （CloudRemoteBookClient，来源 cloud）的远端书同样以占位卡混排进主网格，
    // 与互联来源共用同一占位卡渲染（云角标 + 远端封面 + 下载按钮）。
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      sourceKind: RemoteBookSourceKind.cloud,
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('Remote Book'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>(
        'remote_book_cloud_badge_Remote_Book',
      )),
      findsOneWidget,
    );
  });

  testWidgets('remote book uses the shelf card cover layout',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('remote_book_card_Remote_Book'),
    );
    expect(card, findsOneWidget);
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(
          const ValueKey<String>('remote_book_cover_Remote_Book'),
        ),
      ),
      findsOneWidget,
    );
    expect(find.descendant(of: card, matching: find.byType(AspectRatio)),
        findsOneWidget);
  });

  testWidgets('remote book title renders below the cover',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Rect coverRect = tester.getRect(find.byKey(
      const ValueKey<String>('remote_book_cover_Remote_Book'),
    ));
    final Rect titleRect = tester.getRect(find.text('Remote Book'));

    // Remote shelf cards share the same stable cover + footer layout as local
    // books: cover art stays unobscured and the title lives below it.
    expect(
      titleRect.top,
      greaterThanOrEqualTo(coverRect.bottom - 0.5),
      reason: 'remote book title must render in the footer below the cover',
    );
    expect(
      titleRect.bottom,
      greaterThan(coverRect.bottom),
      reason: 'the title footer must not be drawn over the cover artwork',
    );
  });

  testWidgets(
      'remote book renders normal-book type badge by default '
      '(TODO-655a)', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('remote_book_card_Remote_Book'),
    );
    expect(card, findsOneWidget);
    final Finder badge = find.descendant(
      of: card,
      matching: find.byKey(
        const ValueKey<String>('remote_book_type_badge_Remote_Book'),
      ),
    );
    expect(badge, findsOneWidget,
        reason: 'remote book card must show a type badge like local books');
    // Normal book → book icon, never the headphones (audiobook) icon.
    expect(
      find.descendant(
          of: badge, matching: find.byIcon(Icons.headphones_outlined)),
      findsNothing,
    );
    expect(
      find.descendant(
          of: badge, matching: find.byIcon(Icons.menu_book_outlined)),
      findsOneWidget,
    );
  });

  testWidgets('remote audiobook renders headphones type badge (TODO-655a)',
      (WidgetTester tester) async {
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      hasAudiobook: true,
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder badge = find.byKey(
      const ValueKey<String>('remote_book_type_badge_Remote_Book'),
    );
    expect(badge, findsOneWidget);
    expect(
      find.descendant(
          of: badge, matching: find.byIcon(Icons.headphones_outlined)),
      findsOneWidget,
      reason: 'a remote book with an audiobook must show the headphones badge',
    );
  });

  testWidgets(
      'remote book renders as a placeholder card in the main scatter grid '
      '(spec §2.1 mixed grid)', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Finder card = find.byKey(
      const ValueKey<String>('remote_book_card_Remote_Book'),
    );
    expect(card, findsOneWidget);
    // 撤独立远端 GridView 分区后，远端占位卡是主散卡网格（SliverGrid）的一个 cell，
    // 与本地书卡同一网格、同一卡宽基准（不再被独立 section 的内边距压窄）。
    expect(
      find.ancestor(of: card, matching: find.byType(SliverGrid)),
      findsOneWidget,
    );
  });

  testWidgets('remote book download action pulls epub and imports locally',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>(
        'remote_book_download_Remote_Book',
      )));
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (remoteClient.downloadedTitles.isNotEmpty &&
            importedFiles.isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump();

    expect(remoteClient.downloadedTitles, <String>['Remote Book']);
    expect(importedFiles.single.existsSync(), isTrue);
  });

  testWidgets('remote book download uses stable bookKey for special titles',
      (WidgetTester tester) async {
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      title: r'Vol 1/2\3?..: Finale',
      bookKey: 'Vol_1_2_3_Finale',
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip(t.remote_book_download));
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (remoteClient.downloadedTitles.isNotEmpty &&
            importedFiles.isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump();

    expect(remoteClient.downloadedTitles, <String>['Vol_1_2_3_Finale']);
    expect(importedFiles.single.existsSync(), isTrue);
  });

  testWidgets(
      'remote audiobook download wires getRemoteAudiobook + import with '
      'stable remote key and local bookKey override (BUG-406)',
      (WidgetTester tester) async {
    // host 把书名重复时加了后缀，真实 bookKey 与 sanitizeTtuFilename(title) 不同。
    // 下载有声书必须用 host 传来的真实 bookKey（= downloadId），否则 404（BUG-414）。
    const String hostAudiobookKey = 'Vol_1_2_Audio_2';
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      title: r'Vol 1/2: Audio',
      bookKey: hostAudiobookKey,
      hasAudiobook: true,
    );
    importedBookKey = 'local-renamed-key';
    // 守护：真实 key 与 sanitize(title) 必须不同，回归用例才有意义。
    expect(hostAudiobookKey,
        isNot(equals(sanitizeTtuFilename(r'Vol 1/2: Audio'))));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip(t.remote_book_download));
      for (int i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (importedAudiobooks.isNotEmpty) break;
      }
    });
    await tester.pump();

    // EPUB still imported.
    expect(importedFiles.single.existsSync(), isTrue);
    // Audiobook fetched with the host's real bookKey (= downloadId = bookKey ?? title),
    // NOT sanitizeTtuFilename(title). Reverting the fix flips this back to sanitize(title)
    // and turns this red (BUG-414 regression guard).
    expect(fetchedAudiobookKeys, <String>[hostAudiobookKey]);
    expect(fetchedAudiobookKeys,
        isNot(equals(<String>[sanitizeTtuFilename(r'Vol 1/2: Audio')])));
    // Audiobook imported once, bound to the *local* imported EPUB bookKey.
    expect(importedAudiobooks, hasLength(1));
    expect(importedAudiobooks.single.bookKeyOverride, 'local-renamed-key');
    expect(importedAudiobooks.single.package.existsSync(), isTrue);
  });

  testWidgets('BUG-813: 下载远端书把 host 阅读进度回填进本地 reader_positions',
      (WidgetTester tester) async {
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      progress: const RemoteBookProgress(
        sectionIndex: 3,
        normCharOffset: 4200,
        charOffset: 137,
        updatedAtMs: 1700000000000,
      ),
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>(
        'remote_book_download_Remote_Book',
      )));
      // 轮询直到进度回填落库（下载 → 导入 → 拉进度 upsert 是异步链）。
      for (int i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (await db.getReaderPosition('local-book-key') != null) break;
      }
    });
    await tester.pump();

    // 下载动作把 host 端阅读进度回填进本地 reader_positions（键 = 导入后的本地
    // bookKey，非 host downloadId）——手动下载不再丢「阅读记录」。
    final ReaderPositionRow? row = await db.getReaderPosition('local-book-key');
    expect(row, isNotNull,
        reason: 'BUG-813：下载远端书必须把 host 阅读进度落进 reader_positions');
    expect(row!.sectionIndex, 3);
    expect(row.normCharOffset, 4200);
    expect(row.charOffset, 137);
    expect(row.updatedAt, 1700000000000);
  });

  testWidgets('BUG-990: 有声书两阶段下载空窗期，本地卡持续显示加载覆盖层', (WidgetTester tester) async {
    // 本地已有一张 SRT 卡（bookKey = importer 将返回的 localBookKey），模拟 EPUB 落库
    // 后 provider 自动刷新把远端占位卡顶替成本地卡的空窗态。
    shelfSrtBooks = <SrtBook>[
      SrtBook()
        ..uid = 'srtbook_epub_local-book-key'
        ..title = 'Local Audiobook'
        ..srtPath = '${pathProviderDir.path}/local.srt'
        ..importedAt = 0
        ..bookKey = 'local-book-key',
    ];
    audiobookDownloadGate = Completer<void>();
    remoteClient = _FakeRemoteBookClient(
      coverPath: remoteBookCover.path,
      hasAudiobook: true,
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    const ValueKey<String> overlayKey =
        ValueKey<String>('audiobook_downloading_local-book-key');
    // 下载前：本地 SRT 卡在，无加载覆盖层。
    expect(find.byKey(overlayKey), findsNothing);

    // 点远端占位卡下载 → EPUB 导入(importer 返回 local-book-key) → 标记有声书下载中 →
    // 有声书 fetch 卡在闸门。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>(
        'remote_book_download_Remote_Book',
      )));
      for (int i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (fetchedAudiobookKeys.isNotEmpty) break;
      }
    });
    await tester.pump();

    expect(find.byKey(overlayKey), findsOneWidget,
        reason: 'BUG-990：有声书下载中本地卡必须显示加载覆盖层');

    // 放行有声书下载 → 完成 → 覆盖层清除。
    await tester.runAsync(() async {
      audiobookDownloadGate!.complete();
      for (int i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        if (importedAudiobooks.isNotEmpty) break;
      }
    });
    await tester.pump();

    expect(find.byKey(overlayKey), findsNothing,
        reason: 'BUG-990：有声书下载完成后覆盖层必须清除');
  });

  testWidgets('书架统计带已按用户要求移除（原 BUG-991 口径随之退役）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 「统计」三格（总数/在读/已完成）与右上角「阅读统计」入口重复，2026-07-22
    // 用户拍板删除；此守卫防止统计带被无意识复活（复活需连同 BUG-991 的远端
    // 计数口径一起补回）。
    shelfSrtBooks = <SrtBook>[
      SrtBook()
        ..uid = 'local-srt-uid'
        ..title = 'Local Book'
        ..srtPath = '${pathProviderDir.path}/local.srt'
        ..importedAt = 0
        ..bookKey = '',
    ];
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('shelf_overview_total')),
      findsNothing,
      reason: '书架不应再渲染「统计」三格（与阅读统计页重复）',
    );
  });

  testWidgets('BUG-992/1175: 切回书架 tab 远端卡在场，且 TTL 内不重打网络',
      (WidgetTester tester) async {
    // BUG-992 当初断言的是「切回 tab 后 listRemoteBooks 调用次数增加」——那是实现
    // 细节，不是用户诉求。用户要的是「切回书架能看到远端占位卡」，而**不是**「每切
    // 一次页面就联网一次」（后者正是 BUG-1180 的症状）。清单现在过 RemoteLibraryCache
    // 的 TTL：切回 tab 仍然重新组装（本地库变化立即反映），但 TTL 内不再打网络。
    // 这里把断言换成用户可见的不变式 + 「不得重复联网」的新约束。
    homeShellTabNotifier.value = HomeTab.books;
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    // 首帧懒加载已拉一次。
    expect(remoteClient.listRemoteBooksCalls, greaterThanOrEqualTo(1));
    final int before = remoteClient.listRemoteBooksCalls;
    final Finder remoteCard =
        find.byKey(const ValueKey<String>('remote_book_card_Remote_Book'));
    expect(remoteCard, findsOneWidget);

    // 切到别的 tab 再切回书架。
    homeShellTabNotifier.value = HomeTab.video;
    await tester.pump();
    expect(remoteClient.listRemoteBooksCalls, before, reason: '切到非书架 tab 不应重拉');

    homeShellTabNotifier.value = HomeTab.books;
    await tester.pumpAndSettle();
    expect(remoteCard, findsOneWidget,
        reason: 'BUG-992：切回书架 tab 远端占位卡必须仍在场（不必手动下拉刷新）');
    expect(remoteClient.listRemoteBooksCalls, before,
        reason: 'BUG-1180：TTL 内切回 tab 不得再问对端要一次清单');
  });

  testWidgets('BUG-1180: 下拉刷新强制穿透缓存（用户要最新的就必须联网）', (WidgetTester tester) async {
    homeShellTabNotifier.value = HomeTab.books;
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    final int before = remoteClient.listRemoteBooksCalls;

    await tester.fling(
      find.byType(RefreshIndicator).first,
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();

    expect(remoteClient.listRemoteBooksCalls, greaterThan(before),
        reason: '显式下拉刷新是强制入口，必须穿透 TTL 重新联网');
  });

  testWidgets('BUG-1181: 漫画书架实例从不拉远端书（它根本不消费）', (WidgetTester tester) async {
    // 漫画书架就是 ReaderFushiHistoryPage(mangaOnly: true)——与书架**同一个 State
    // 类**。它此前也注册了 homeShellTabNotifier 监听，且回调判的是 `== HomeTab.books`，
    // 于是切到书架时两个实例各拉一遍远端书，漫画那份在 build 里被 `!_mangaOnly` 丢掉。
    homeShellTabNotifier.value = HomeTab.manga;
    await tester.pumpWidget(buildApp(mangaOnly: true));
    await tester.pumpAndSettle();
    expect(remoteClient.listRemoteBooksCalls, 0,
        reason: '漫画书架不渲染远端书占位卡，首帧就不该联网');

    // 切到书架 tab：漫画实例仍在树上（保活），但不得被 books 信号带着一起拉。
    homeShellTabNotifier.value = HomeTab.books;
    await tester.pumpAndSettle();
    expect(remoteClient.listRemoteBooksCalls, 0,
        reason: 'BUG-1181：漫画实例不得响应书架 tab 信号去拉远端书');
  });

  testWidgets('BUG-1182: 关闭「显示远端条目」后根本不联网（而不是拉完再丢）',
      (WidgetTester tester) async {
    await appModel.prefsRepo.setShowRemoteEntries(false);
    homeShellTabNotifier.value = HomeTab.books;
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(remoteClient.listRemoteBooksCalls, 0,
        reason: '开关关闭时门控必须在取数之前，不能拉完再在渲染期丢弃');
    expect(
      find.byKey(const ValueKey<String>('remote_book_card_Remote_Book')),
      findsNothing,
    );

    // 开关翻回来：`??=` 不会自己重跑，门控翻转必须触发重新取数，否则用户要下拉刷新。
    await appModel.prefsRepo.setShowRemoteEntries(true);
    await tester.pumpAndSettle();
    expect(remoteClient.listRemoteBooksCalls, greaterThanOrEqualTo(1),
        reason: 'BUG-1182：开关从关翻到开必须重新取数');
    expect(
      find.byKey(const ValueKey<String>('remote_book_card_Remote_Book')),
      findsOneWidget,
    );
  });

  testWidgets(
      'remote book without audiobook never touches the audiobook wiring '
      '(BUG-406)', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip(t.remote_book_download));
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (importedFiles.isNotEmpty) break;
      }
    });
    await tester.pump();

    expect(importedFiles.single.existsSync(), isTrue);
    expect(fetchedAudiobookKeys, isEmpty);
    expect(importedAudiobooks, isEmpty);
  });
}

class _FakeRemoteBookClient implements RemoteBookClient {
  _FakeRemoteBookClient({
    required this.coverPath,
    this.title = 'Remote Book',
    this.bookKey,
    this.hasAudiobook = false,
    this.sourceKind = RemoteBookSourceKind.interconnect,
    this.progress = RemoteBookProgress.empty,
  });

  final String coverPath;
  final String title;
  final String? bookKey;
  final bool hasAudiobook;
  final RemoteBookSourceKind sourceKind;
  // BUG-813：host 端该书的阅读进度，供「下载回填进度」用例配置。
  final RemoteBookProgress progress;
  final List<String> downloadedTitles = <String>[];

  @override
  RemoteBookSourceKind get remoteSourceKind => sourceKind;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  // BUG-992：listRemoteBooks 调用次数（观测「切回书架 tab 自动重拉远端」）。
  int listRemoteBooksCalls = 0;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async {
    listRemoteBooksCalls++;
    return <RemoteBookInfo>[
      RemoteBookInfo.fromJson(<String, Object?>{
        'title': title,
        if (bookKey != null) 'bookKey': bookKey,
        'hasContent': true,
        'coverPath': coverPath,
        if (hasAudiobook) 'hasAudiobook': true,
      }),
    ];
  }

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    downloadedTitles.add(title);
    await destination.writeAsBytes(<int>[1, 2, 3]);
    onProgress?.call(1);
  }

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      progress;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}
}

final List<int> _tinyPngBytes =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mP8z8BQDwAFgwJ/l5YV3wAAAABJRU5ErkJggg==');
