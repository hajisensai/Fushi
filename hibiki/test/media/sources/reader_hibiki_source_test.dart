import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../pages/reader_history_source_corpus.dart';
import 'package:fushi/media.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/sync/ttu_filename.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderHibikiSource shelf actions', () {
    test('bookshelf home actions do not expose the tweaks button', () {
      final String source = File(
        'lib/src/media/sources/reader_hibiki_source.dart',
      ).readAsStringSync();
      final String historySource = readReaderHistorySource();

      final int actionsStart = source.indexOf('List<Widget> getActions');
      final int importButtonStart =
          source.indexOf('Widget buildBookImportButton');
      final String actionsBody = source.substring(
        actionsStart,
        importButtonStart,
      );

      expect(actionsStart, isNonNegative);
      expect(importButtonStart, isNonNegative);
      expect(actionsBody, contains('buildBookImportButton'));
      expect(actionsBody, isNot(contains('buildTweaksButton')));
      expect(source, isNot(contains('Widget buildTweaksButton')));
      expect(historySource, isNot(contains('buildTweaksButton')));
    });
  });

  group('ReaderHibikiSource.isExternalUrl (BUG-097 内链不外开)', () {
    test('内部 fushi.local 书内 URL 永不当外部链接(未解析时不弹系统浏览器)', () {
      expect(
        ReaderHibikiSource.isExternalUrl(
            'https://fushi.local/epub/OEBPS/ch2.xhtml'),
        isFalse,
      );
      expect(
        ReaderHibikiSource.isExternalUrl(
            'https://fushi.local/epub/text/note.xhtml#n1'),
        isFalse,
      );
      expect(
        ReaderHibikiSource.isExternalUrl(
            '${ReaderHibikiSource.kResourceScheme}://fushi.local/epub/OEBPS/ch2.xhtml'),
        isFalse,
      );
    });

    test('Apple 平台 EPUB 资源 URL 走 WebKit custom scheme', () {
      final String url = ReaderHibikiSource.epubUrl('OEBPS/ch 2.xhtml');

      if (Platform.isMacOS || Platform.isIOS) {
        expect(
          url,
          '${ReaderHibikiSource.kResourceScheme}://fushi.local/epub/OEBPS/ch%202.xhtml',
        );
      } else {
        expect(url, 'https://fushi.local/epub/OEBPS/ch%202.xhtml');
      }
    });

    test('真正的外部 http/https/mailto 链接 → 外部打开', () {
      expect(
        ReaderHibikiSource.isExternalUrl('https://example.com/page'),
        isTrue,
      );
      expect(
        ReaderHibikiSource.isExternalUrl('http://example.com/'),
        isTrue,
      );
      expect(
        ReaderHibikiSource.isExternalUrl('mailto:a@b.com'),
        isTrue,
      );
    });

    test('非外部 scheme / 无法解析 → 不外开', () {
      expect(ReaderHibikiSource.isExternalUrl('hoshi://book/foo'), isFalse);
      expect(ReaderHibikiSource.isExternalUrl('about:blank'), isFalse);
      expect(ReaderHibikiSource.isExternalUrl('://broken'), isFalse);
    });
  });

  group('ReaderHibikiSource custom font helpers', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('hibiki_font_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('canonicalizes allowed custom font paths before building CSS',
        () async {
      final fontsDir = Directory(p.join(tempDir.path, 'fonts'));
      await fontsDir.create();
      final fontFile = File(p.join(fontsDir.path, 'font.ttf'));
      await fontFile.writeAsBytes(<int>[0, 1, 0, 0]);
      final rawPath = p.join(fontsDir.path, '..', 'fonts', 'font.ttf');

      final result = ReaderHibikiSource.customFontCssForEntries(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Test Font',
            'path': rawPath,
            'enabled': true,
          },
        ],
        allowedDirectories: <String>[fontsDir.path],
      );

      expect(
        result.fontFaces,
        contains(Uri.encodeComponent(p.canonicalize(fontFile.path))),
      );
      expect(
        result.fontFaces,
        contains(
          Platform.isMacOS || Platform.isIOS
              ? '${ReaderHibikiSource.kResourceScheme}://fushi.local/fonts/'
              : 'https://fushi.local/fonts/',
        ),
      );
      expect(result.fontFaces, isNot(contains('..')));
    });

    test('reader settings font CSS uses custom scheme on macOS target',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });
      final fontsDir = Directory(p.join(tempDir.path, 'fonts'));
      await fontsDir.create();
      final fontFile = File(p.join(fontsDir.path, 'font.ttf'));
      await fontFile.writeAsBytes(<int>[0, 1, 0, 0]);

      final result = ReaderSettings.customFontCssForEntries(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Body Font',
            'path': fontFile.path,
            'enabled': true,
          },
        ],
        allowedDirectories: <String>[fontsDir.path],
      );

      expect(
        result.fontFaces,
        contains('${ReaderHibikiSource.kResourceScheme}://fushi.local/fonts/'),
      );
    });

    test('rejects custom font paths outside the allowed directories', () async {
      final fontsDir = Directory(p.join(tempDir.path, 'fonts'));
      final outsideDir = Directory(p.join(tempDir.path, 'outside'));
      await fontsDir.create();
      await outsideDir.create();
      final outsideFont = File(p.join(outsideDir.path, 'font.ttf'));
      await outsideFont.writeAsBytes(<int>[0, 1, 0, 0]);

      final result = ReaderHibikiSource.customFontCssForEntries(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Outside Font',
            'path': outsideFont.path,
            'enabled': true,
          },
        ],
        allowedDirectories: <String>[fontsDir.path],
      );

      expect(result.fontFamily, isEmpty);
      expect(result.fontFaces, isEmpty);
    });
  });

  group('MediaSource preference cache invalidation', () {
    test(
        'refreshPreferencesFromDb drops keys deleted from the DB '
        '(profile switch with no custom value restores default)', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      // Profile A: a custom shortcut binding is persisted.
      await source.setPreference<String>(
        key: 'shortcut_bindings_json',
        value: '{"reader_page_forward":{"keyboard":["KeyN"],"gamepad":[]}}',
      );
      expect(
        source.getPreference<String?>(
            key: 'shortcut_bindings_json', defaultValue: null),
        isNotNull,
      );

      // Switching to Profile B (no custom shortcuts): applyProfile deletes the
      // pref row that is absent from the new profile.
      await db.deletePref('src:reader_fushi:shortcut_bindings_json');
      await source.refreshPreferencesFromDb();

      // The stale Profile A value must not survive in the in-memory cache.
      expect(
        source.getPreference<String?>(
            key: 'shortcut_bindings_json', defaultValue: null),
        isNull,
      );
    });
  });
  group('autoReadOnLookup is profile-aware (TODO-080B 视频字幕查词)', () {
    setUp(() {
      // The static reader-settings snapshot is a reader-page-owned cache that
      // the video page never refreshes. Tests below pin it explicitly so the
      // "stale reader snapshot" never silently leaks the real fix.
      ReaderHibikiSource.readerSettings = null;
    });
    tearDown(() {
      ReaderHibikiSource.readerSettings = null;
    });

    test(
        '视频上下文：DB(=当前 profile)关闭自动阅读时 autoReadOnLookup 为 false，'
        '即使阅读器遗留的静态 readerSettings 快照仍是 true', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;

      // 当前(视频)上下文：用户关闭"查词时自动阅读" → 写穿 DB + source 缓存。
      await source.setPreference<bool>(
        key: 'auto_read_on_lookup',
        value: false,
      );

      // 阅读器页面遗留的全局静态快照仍停在另一个 profile 的 true（视频页从不刷新它）。
      final ReaderSettings staleReaderSnapshot = ReaderSettings(db);
      await staleReaderSnapshot.refreshFromDb();
      // 把快照强制改回 true，模拟"最后一次打开阅读器的 profile"自动阅读=开。
      if (!staleReaderSnapshot.autoReadOnLookup) {
        await staleReaderSnapshot.toggleAutoReadOnLookup();
      }
      ReaderHibikiSource.readerSettings = staleReaderSnapshot;

      // 视频字幕查词读 source.autoReadOnLookup：必须反映当前 profile 的真实设置(false)，
      // 而不是陈旧的阅读器快照(true)。修复前会读到 true → 自动阅读，红。
      expect(source.autoReadOnLookup, isFalse);

      // 反向：DB(=当前 profile)开启时为 true。
      await source.setPreference<bool>(
        key: 'auto_read_on_lookup',
        value: true,
      );
      expect(source.autoReadOnLookup, isTrue);
    });

    test('profile 切换(refreshPreferencesFromDb)后 autoReadOnLookup 立即跟随',
        () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      // Profile A: 关闭自动阅读并落 DB。
      await source.setPreference<bool>(
        key: 'auto_read_on_lookup',
        value: false,
      );
      expect(source.autoReadOnLookup, isFalse);

      // 模拟切到 Profile B(自动阅读=开)：applyProfile 写穿 DB，refreshPrefCache
      // 重载每个 source 的 _preferences。
      await db.setPref('src:reader_fushi:auto_read_on_lookup', 'true');
      await source.refreshPreferencesFromDb();
      expect(source.autoReadOnLookup, isTrue);
    });

    test('toggleAutoReadOnLookup 写穿 DB 且读写对称(不再依赖静态 readerSettings)', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      // 默认 true。
      expect(source.autoReadOnLookup, isTrue);

      // 关闭：toggle 后立即一致，且写穿 DB(profile 快照从 DB 读取)。
      source.toggleAutoReadOnLookup();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(source.autoReadOnLookup, isFalse);
      expect(
        await db.getPref('src:reader_fushi:auto_read_on_lookup'),
        'b:false',
      );

      // 再开启：对称回到 true。
      source.toggleAutoReadOnLookup();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(source.autoReadOnLookup, isTrue);
      expect(
        await db.getPref('src:reader_fushi:auto_read_on_lookup'),
        'b:true',
      );
    });
  });

  group('popup swipe-to-close is profile-aware (TODO-496)', () {
    setUp(() {
      ReaderHibikiSource.readerSettings = null;
    });
    tearDown(() {
      ReaderHibikiSource.readerSettings = null;
    });

    test(
        'source enableSwipeToClose follows current DB/cache even when '
        'readerSettings snapshot is stale', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();
      await source.setPreference<bool>(
        key: 'enable_swipe_to_close',
        value: true,
      );

      final ReaderSettings staleReaderSnapshot = ReaderSettings(db);
      await staleReaderSnapshot.refreshFromDb();
      if (staleReaderSnapshot.enableSwipeToClose) {
        await staleReaderSnapshot.setEnableSwipeToClose(false);
      }
      ReaderHibikiSource.readerSettings = staleReaderSnapshot;

      expect(
        source.enableSwipeToClose,
        isTrue,
        reason:
            'popup surfaces must read the live source cache/current profile, '
            'not a stale reader-page snapshot.',
      );
    });
  });

  group('hoverAutoLookup preference (TODO-756b)', () {
    setUp(() {
      ReaderHibikiSource.readerSettings = null;
    });
    tearDown(() {
      ReaderHibikiSource.readerSettings = null;
    });

    test('defaults to false and round-trips through DB', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      // Default: 756a behavior (Shift required), hover-auto OFF.
      expect(source.hoverAutoLookup, isFalse);

      // Enable: writes through to DB and reads back symmetrically.
      await source.setHoverAutoLookup(value: true);
      expect(source.hoverAutoLookup, isTrue);
      expect(
        await db.getPref('src:reader_fushi:hover_auto_lookup'),
        'b:true',
      );

      // Disable: round-trips back to false.
      await source.setHoverAutoLookup(value: false);
      expect(source.hoverAutoLookup, isFalse);
      expect(
        await db.getPref('src:reader_fushi:hover_auto_lookup'),
        'b:false',
      );
    });

    test('profile switch (refreshPreferencesFromDb) is reflected', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();
      expect(source.hoverAutoLookup, isFalse);

      // Simulate switching to a profile that enabled hover-auto.
      await db.setPref('src:reader_fushi:hover_auto_lookup', 'b:true');
      await source.refreshPreferencesFromDb();
      expect(source.hoverAutoLookup, isTrue);
    });
  });

  group('invertAudiobookSkipDirection is per-reader (TODO-830)', () {
    setUp(() {
      ReaderHibikiSource.readerSettings = null;
    });
    tearDown(() {
      ReaderHibikiSource.readerSettings = null;
    });

    test(
        'defaults to false and round-trips through the global source pref '
        'when no reader page is open', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      // Default = false (现有行为：左=上一句、右=下一句)。
      expect(source.invertAudiobookSkipDirection, isFalse);

      source.toggleInvertAudiobookSkipDirection();
      // toggle 内部 await setPreference，给微任务/IO 一拍落定。
      await Future<void>.delayed(Duration.zero);
      expect(source.invertAudiobookSkipDirection, isTrue);
      expect(
        await db.getPref('src:reader_fushi:invert_audiobook_skip_direction'),
        'b:true',
      );
    });

    test(
        'reads/writes through ReaderSettings (per-reader) when a reader page '
        'is open, mirroring invert_swipe / reverse_arrow', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      final ReaderSettings perBook = ReaderSettings(db);
      await perBook.refreshFromDb();
      ReaderHibikiSource.readerSettings = perBook;

      // Per-reader default false.
      expect(source.invertAudiobookSkipDirection, isFalse);

      // Toggle 走 ReaderSettings 分层（perBook.toggle），不是 source.setPreference。
      source.toggleInvertAudiobookSkipDirection();
      await Future<void>.delayed(Duration.zero);
      expect(perBook.invertAudiobookSkipDirection, isTrue);
      expect(source.invertAudiobookSkipDirection, isTrue);
      // 证明写经 ReaderSettings 路径：ReaderSettings._set 用 value.toString()
      // 编码（'true'），而 source.setPreference 会用 PrefCodec.encode（'b:true'）。
      // 两路径共用同一 DB key，但编码不同——'true' 坐实走了 per-reader 分层。
      expect(
        await db.getPref('src:reader_fushi:invert_audiobook_skip_direction'),
        'true',
      );
    });
  });

  group('ReaderHibikiSource author editing (BUG-220 子3)', () {
    EpubBooksCompanion bookWithAuthor(String key, {String? author}) {
      return EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        author: author == null ? const Value.absent() : Value(author),
        epubPath: '/tmp/$key.epub',
        extractDir: '/tmp/$key',
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }

    test('supportsAuthorEdit is true for the EPUB shelf source', () {
      expect(ReaderHibikiSource.instance.supportsAuthorEdit, isTrue);
    });

    test('setAuthorFromMediaItem writes the author into epubBooks.author',
        () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);
      await db.insertEpubBook(bookWithAuthor('Kokoro'));

      final source = ReaderHibikiSource.instance;
      final item = MediaItem(
        mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor('Kokoro'),
        title: 'Kokoro',
        mediaTypeIdentifier: source.mediaType.uniqueKey,
        mediaSourceIdentifier: source.uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      );

      await source.setAuthorFromMediaItem(item: item, author: '夏目漱石');

      final row = await db.getEpubBook('Kokoro');
      expect(row, isNotNull);
      expect(row!.author, '夏目漱石');
    });

    test('MangaHibikiSource 也支持作者编辑并委托写入 epubBooks.author（BUG-1083）', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);
      // 漫画是 format=='manga' 的 EpubBooks 行；作者列与 EPUB 共用。
      await db.insertEpubBook(bookWithAuthor('MangaVol1'));

      // 补齐的缺口：此前 MangaHibikiSource 沿用基类默认 false，漫画编辑无作者字段。
      expect(MangaHibikiSource.instance.supportsAuthorEdit, isTrue);

      final item = MediaItem(
        mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor('MangaVol1'),
        title: 'MangaVol1',
        mediaTypeIdentifier: MangaHibikiSource.instance.mediaType.uniqueKey,
        mediaSourceIdentifier: MangaHibikiSource.instance.uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      );
      await MangaHibikiSource.instance
          .setAuthorFromMediaItem(item: item, author: '藤本タツキ');

      final row = await db.getEpubBook('MangaVol1');
      expect(row!.author, '藤本タツキ',
          reason: '漫画作者编辑委托 ReaderHibikiSource 写同一 epubBooks.author 列');
    });

    test('setAuthorFromMediaItem trims and clears a blank author to NULL',
        () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);
      await db.insertEpubBook(bookWithAuthor('Botchan', author: '夏目漱石'));

      final source = ReaderHibikiSource.instance;
      final item = MediaItem(
        mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor('Botchan'),
        title: 'Botchan',
        mediaTypeIdentifier: source.mediaType.uniqueKey,
        mediaSourceIdentifier: source.uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      );

      // Whitespace-only edit clears the column rather than storing spaces.
      await source.setAuthorFromMediaItem(item: item, author: '   ');
      expect((await db.getEpubBook('Botchan'))!.author, isNull);

      // A real value with surrounding whitespace is trimmed.
      await source.setAuthorFromMediaItem(item: item, author: '  芥川  ');
      expect((await db.getEpubBook('Botchan'))!.author, '芥川');
    });

    test(
        'updateEpubBookAuthor is a plain UPDATE that keeps the bookKey (not a '
        're-key like the title)', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.insertEpubBook(bookWithAuthor('SameKey', author: 'old'));

      await db.updateEpubBookAuthor('SameKey', 'new');

      final row = await db.getEpubBook('SameKey');
      expect(row, isNotNull, reason: 'bookKey (primary key) must be unchanged');
      expect(row!.author, 'new');
    });
  });

  group('ReaderHibikiSource.deleteBook honesty (BUG-439)', () {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();
    late Directory ppDir;

    setUp(() {
      // deleteBook resolves on-disk persist/extract dirs via path_provider.
      ppDir = Directory.systemTemp.createTempSync('hibiki_delete_book_pp');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => ppDir.path,
      );
    });
    tearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (ppDir.existsSync()) ppDir.deleteSync(recursive: true);
    });

    EpubBooksCompanion epubBook(String key) {
      return EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '/tmp/$key.epub',
        extractDir: '/tmp/$key',
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }

    test('returns true and removes the row when the EPUB book exists',
        () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);
      await db.insertEpubBook(epubBook('Kokoro'));

      final DeleteBookResult result =
          await ReaderHibikiSource.instance.deleteBook(
        db: db,
        bookKey: 'Kokoro',
      );

      expect(result.deleted, isTrue);
      expect(result.failureReason, isNull);
      expect(await db.getEpubBook('Kokoro'), isNull);
    });

    test(
        'returns false when the bookKey matches no EPUB/SRT row '
        '(orphan shell / missing key must not fake success)', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      // Empty key (the orphan-shell case) and an arbitrary missing key both
      // have nothing to delete: deleteBook must report failure, not lie.
      // TODO-1359：失败结果必须携带原因（供 toast 展示 + 已写入 ErrorLogService），
      // 不能只回一个信息全无的 bool。
      final DeleteBookResult emptyKeyResult =
          await ReaderHibikiSource.instance.deleteBook(db: db, bookKey: '');
      expect(emptyKeyResult.deleted, isFalse);
      expect(emptyKeyResult.failureReason, isNotNull);
      final DeleteBookResult missingKeyResult = await ReaderHibikiSource
          .instance
          .deleteBook(db: db, bookKey: 'no-such-book');
      expect(missingKeyResult.deleted, isFalse);
      expect(missingKeyResult.failureReason, contains('no-such-book'));
    });
  });

  group('ReaderHibikiSource.deleteBook TODO-1359 (删不掉 + 无原因)', () {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();
    late Directory ppDir;
    setUp(() {
      ppDir = Directory.systemTemp.createTempSync('hibiki_del1359_pp');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => ppDir.path,
      );
    });
    tearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (ppDir.existsSync()) ppDir.deleteSync(recursive: true);
    });

    // 根因：DB 行（唯一真相源）删除成功后，磁盘解压目录清理若因 Windows 文件占用抛
    // 异常，绝不能把已提交的删除翻转成「删除失败」。旧实现把 deleteBookDir 放在外层
    // try 里裸跑，一抛就落到最外层 catch 返回失败——书还挂在架上、目录泄漏。
    test(
        'on-disk extract-dir cleanup failure does NOT flip a committed DB '
        'delete to failure (Windows file-lock; deleted==true, row gone)',
        () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      // A real extract dir with a file we hold open so recursive delete throws
      // on Windows (POSIX allows unlink-while-open, so there the delete just
      // succeeds — either way the committed DB delete must report success).
      final Directory extractDir =
          Directory.systemTemp.createTempSync('hibiki_del1359_extract');
      final File inner = File(p.join(extractDir.path, 'content.xhtml'))
        ..writeAsStringSync('<html></html>');
      final RandomAccessFile handle = inner.openSync(mode: FileMode.write);
      addTearDown(() {
        handle.closeSync();
        if (extractDir.existsSync()) {
          extractDir.deleteSync(recursive: true);
        }
      });

      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'LockedBook',
        title: 'LockedBook',
        epubPath: '/tmp/LockedBook.epub',
        extractDir: extractDir.path,
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));

      final DeleteBookResult result = await ReaderHibikiSource.instance
          .deleteBook(db: db, bookKey: 'LockedBook');

      // The DB row (source of truth) is gone → this book is deleted for the
      // user; a leaked on-disk dir must not be reported as a delete failure.
      expect(result.deleted, isTrue,
          reason: 'committed DB delete must report success even if the '
              'on-disk extract dir could not be removed');
      expect(await db.getEpubBook('LockedBook'), isNull);
    });

    // 源码守卫（跨平台确定性）：磁盘/偏好清理必须被一个只记日志、不翻转结果的
    // try/catch 包住，且位于 deleteEpubBook 之后、成功返回之前。撤掉这层 wrapper 会
    // 让 deleteBookDir 抛出的异常重新冒泡到最外层 catch → 又回到「删不掉」。
    test('post-DB on-disk cleanups are wrapped in a tolerant try/catch', () {
      final String src = File(
        'lib/src/media/sources/reader_hibiki_source.dart',
      ).readAsStringSync();
      final int start = src.indexOf('Future<DeleteBookResult> deleteBook(');
      final int end =
          src.indexOf('static ReaderSettings? readerSettings', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);

      final int rowDelete = body.indexOf('deleteEpubBook(bookKey');
      final int cleanupCatch =
          body.indexOf("'ReaderHibikiSource.deleteBook.cleanup'");
      final int diskCleanup = body.indexOf('EpubStorage.deleteBookDir(');
      final int vacuum = body.indexOf("customStatement('VACUUM')");
      expect(rowDelete, greaterThanOrEqualTo(0));
      expect(cleanupCatch, greaterThan(rowDelete),
          reason: 'the tolerant cleanup catch must exist after the DB delete');
      expect(diskCleanup, greaterThan(rowDelete),
          reason: 'on-disk cleanup runs after the DB delete');
      expect(diskCleanup, lessThan(cleanupCatch),
          reason: 'the on-disk cleanup must sit inside the tolerant try, '
              'before its catch');
      expect(vacuum, greaterThan(cleanupCatch),
          reason: 'VACUUM stays after the cleanup block');
    });

    // 失败结果必须携带面向用户/诊断的原因（fix (a)：不再只弹笼统 toast，用户「报错
    // 日志呢」有据可查）。
    test('failure result carries a non-empty reason mentioning the bookKey',
        () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final DeleteBookResult result = await ReaderHibikiSource.instance
          .deleteBook(db: db, bookKey: 'ghost-shelf-entry');
      expect(result.deleted, isFalse);
      expect(result.failureReason, isNotNull);
      expect(result.failureReason!, isNotEmpty);
      expect(result.failureReason!, contains('ghost-shelf-entry'));
    });
  });

  group(
      'ReaderHibikiSource book-key identifier round-trip '
      '(BUG-658 / TODO-1344 特殊字符标题导入后打不开/删不掉)', () {
    // deleteBook resolves on-disk persist/extract dirs via path_provider.
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();
    late Directory ppDir;
    setUp(() {
      ppDir = Directory.systemTemp.createTempSync('hibiki_bookkey_rt_pp');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => ppDir.path,
      );
    });
    tearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (ppDir.existsSync()) ppDir.deleteSync(recursive: true);
    });

    // Titles whose sanitized bookKey contains literal %XX escapes. These are
    // the exact two files the user reported: 業物語 (dc:title carries `&lt;…&gt;`
    // so the parsed title contains `<`/`>`) and Do Androids (dc:title ends in
    // `?`). sanitizeTtuFilename percent-encodes each forbidden char, so the
    // stored primary key contains `%3C`/`%3E`/`%3F`.
    const String gouTitle = '業物語 <物語> (講談社ＢＯＸ)';
    const String androidsTitle = 'Do Androids Dream of Electric Sheep?';

    test(
        'mediaIdentifierFor -> parseBookKey is a lossless round-trip for every '
        'sanitize escape (the %-in-key regression)', () {
      // One representative key per forbidden char sanitizeTtuFilename encodes,
      // plus the two real book keys and the common no-% keys that must be
      // unaffected.
      final List<String> keys = <String>[
        sanitizeTtuFilename(gouTitle), // 業物語 %3C物語%3E (講談社ＢＯＸ)
        sanitizeTtuFilename(androidsTitle), // ...Sheep%3F
        sanitizeTtuFilename('a/b'), // %2F
        sanitizeTtuFilename('a?b'), // %3F
        sanitizeTtuFilename('a<b>c'), // %3C %3E
        sanitizeTtuFilename('a:b'), // %3A
        sanitizeTtuFilename('a|b'), // %7C
        sanitizeTtuFilename('a%b'), // %25 (literal percent in the title!)
        sanitizeTtuFilename('a"b'), // %22
        sanitizeTtuFilename(r'a\b'), // %5C
        'Book A', // common case, no escape
        'Solo~ttu-star~Book', // star sentinel, no %
      ];
      for (final String key in keys) {
        final String id = ReaderHibikiSource.mediaIdentifierFor(key);
        expect(
          ReaderHibikiSource.parseBookKey(id),
          key,
          reason: 'identifier "$id" must decode back to the exact stored key',
        );
      }
    });

    test('the two real book keys survive the round-trip verbatim', () {
      const String gouKey = '業物語 %3C物語%3E (講談社ＢＯＸ)';
      const String androidsKey = 'Do Androids Dream of Electric Sheep%3F';
      expect(sanitizeTtuFilename(gouTitle), gouKey);
      expect(sanitizeTtuFilename(androidsTitle), androidsKey);
      expect(
        ReaderHibikiSource.parseBookKey(
            ReaderHibikiSource.mediaIdentifierFor(gouKey)),
        gouKey,
      );
      expect(
        ReaderHibikiSource.parseBookKey(
            ReaderHibikiSource.mediaIdentifierFor(androidsKey)),
        androidsKey,
      );
    });

    test('parseBookKey returns null for non-book identifiers', () {
      expect(ReaderHibikiSource.parseBookKey('srt_abc'), isNull);
      expect(ReaderHibikiSource.parseBookKey('about:blank'), isNull);
      expect(ReaderHibikiSource.parseBookKey(''), isNull);
      expect(ReaderHibikiSource.parseBookKey('hoshi://book/'), isNull,
          reason: 'empty remainder is not a valid key');
      expect(ReaderHibikiSource.parseBookKey('hoshi://video/x'), isNull);
    });

    test(
        'end-to-end: a %-key book resolves and deletes through the shelf '
        'identifier (import -> open lookup -> delete闭环)', () async {
      final db = FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      // Persist the row exactly as EpubImporter does: primary key = sanitized
      // title (import verified on-disk that this folder name is creatable).
      final String key = sanitizeTtuFilename(androidsTitle);
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: key,
        title: androidsTitle,
        epubPath: '/tmp/x.epub',
        extractDir: '/tmp/$key',
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));

      // The shelf builds the MediaItem fresh from the row; opening/deleting
      // parses the key back out of that identifier. Before the fix this decoded
      // `%3F`->`?`, so the lookup returned null → book_file_not_found + delete
      // returned false (the exact reported symptom).
      final String identifier = ReaderHibikiSource.mediaIdentifierFor(key);
      final String? parsed = ReaderHibikiSource.parseBookKey(identifier);
      expect(parsed, key);

      // Open path: getEpubBook(parsedKey) must find the row.
      expect(await db.getEpubBook(parsed!), isNotNull,
          reason: 'open lookup must resolve the %-key row');

      // Delete path: deleteBook(parsedKey) must actually remove it and report
      // success (not the false / "删不掉" dead-end).
      final DeleteBookResult delResult =
          await ReaderHibikiSource.instance.deleteBook(db: db, bookKey: parsed);
      expect(delResult.deleted, isTrue);
      expect(await db.getEpubBook(key), isNull);
    });
  });

  group('ReaderHibikiSource author wiring guards (BUG-220 子3 源码守卫)', () {
    test('_bookToMediaItem fills MediaItem.author from the EpubBookRow', () {
      final String source = File(
        'lib/src/media/sources/reader_hibiki_source.dart',
      ).readAsStringSync();
      // The shelf MediaItem must carry the DB author so the detail dialog shows
      // it; missing this line regresses BUG-220 子3-a (author never displayed).
      expect(source, contains('author: book.author'));
    });

    test('author override writes back to epubBooks.author column', () {
      final String source = File(
        'lib/src/media/sources/reader_hibiki_source.dart',
      ).readAsStringSync();
      expect(source, contains('bool get supportsAuthorEdit => true'));
      expect(source, contains('updateEpubBookAuthor'));
    });

    test('detail dialog renders the author when present', () {
      final String source = File(
        'lib/src/pages/implementations/media_item_dialog_page.dart',
      ).readAsStringSync();
      // The frame receives the author so MediaItemDialogFrame can show it.
      expect(source, contains('author: hasAuthor ? author : null'));
    });

    test(
        'edit dialog exposes an author field gated on supportsAuthorEdit and '
        'saves via setAuthorFromMediaItem', () {
      final String source = File(
        'lib/src/pages/implementations/media_item_edit_dialog_page.dart',
      ).readAsStringSync();
      expect(source, contains('_supportsAuthorEdit'));
      expect(source, contains('_authorController'));
      expect(source, contains('setAuthorFromMediaItem'));
    });
  });

  // TODO-1346：书架进度条 position/duration 计算。以前只累加 sectionIndex 之前各章
  // 字数、忽略章内 charOffset，读到某章开头显示极低% → 用户以为「进度没了」。
  group('computeBookProgress (TODO-1346 书架进度纳入 char_offset)', () {
    // 安達としまむら2 现场值：39 章，前 12 章字数含前言共 184，当前章(12)字数 15521。
    const List<int> adachi2 = <int>[
      0, 0, 0, 0, 0, 0, 0, 0, 106, 78, 0, 0, //
      15521, 2696, 0, 11427, 2101, 0, 12397, 2825, 0, 12296, 2108, 0, //
      8952, 1452, 0, 14081, 2240, 0, 3556, 0, 1972, 525, 280, 0, 214, 163, 0,
    ];

    test('章内 charOffset 计入 position（同单位，直接相加）', () {
      final int total = adachi2.reduce((int a, int b) => a + b);
      final int before12 =
          adachi2.take(12).reduce((int a, int b) => a + b); // = 184
      // charOffset=0：只到本章开头。
      final ({int position, int duration}) atStart = computeBookProgress(
        sectionChars: adachi2,
        sectionIndex: 12,
        charOffset: 0,
      );
      expect(atStart.duration, total);
      expect(atStart.position, before12);
      // charOffset=12981（≤ 本章 15521）：章内进度必须被算进 position。
      final ({int position, int duration}) mid = computeBookProgress(
        sectionChars: adachi2,
        sectionIndex: 12,
        charOffset: 12981,
      );
      expect(mid.position, before12 + 12981);
      expect(mid.position, greaterThan(atStart.position),
          reason: '章内 charOffset 必须让进度前进，而非停在章首');
    });

    test('charOffset 超过本章字数 → clamp 进本章（绝不 >100%）', () {
      final int total = adachi2.reduce((int a, int b) => a + b);
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: adachi2,
        sectionIndex: 12,
        charOffset: 999999, // 越界
      );
      expect(prog.position, lessThanOrEqualTo(total));
      // 只 clamp 到「前 12 章 + 本章满字数」。
      final int before12 = adachi2.take(12).reduce((int a, int b) => a + b);
      expect(prog.position, before12 + adachi2[12]);
    });

    test('charOffset == -1（仅章节、章内未知）当 0，不减进度', () {
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: adachi2,
        sectionIndex: 12,
        charOffset: -1,
      );
      final int before12 = adachi2.take(12).reduce((int a, int b) => a + b);
      expect(prog.position, before12);
    });

    test('老书无每章字数（全书字数=0）→ 回退章级 section/章数，不显 0%', () {
      const List<int> noChars = <int>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]; // 10 章全 0
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: noChars,
        sectionIndex: 5,
        charOffset: 0,
      );
      expect(prog.duration, 10);
      expect(prog.position, 5); // 5/10 = 50% 粗粒度，而非 0%
    });

    test('无阅读位置（sectionIndex==null）→ 0 / 全书字数（0%，不崩）', () {
      final int total = adachi2.reduce((int a, int b) => a + b);
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: adachi2,
        sectionIndex: null,
        charOffset: -1,
      );
      expect(prog.position, 0);
      expect(prog.duration, total);
    });

    test('完全无章结构 → (0, 1)（0%，不除零）', () {
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: const <int>[],
        sectionIndex: 3,
        charOffset: 100,
      );
      expect(prog.position, 0);
      expect(prog.duration, 1);
    });
  });

  // BUG-680（TODO-1346 复诉「书籍的进度还是没有啊」）：验证 BUG-659 的 computeBookProgress
  // 修复确实接进渲染路径、并对用户真实书架数据算出与旧包(debug.6783 忽略 charOffset)判然
  // 有别的进度——复诉根因是旧包，不是「算了没接上」。把用户本机 DB 的真实章字数数组固化成
  // 回归守卫，锁死 PM 假设 B(修不足/没接上)永不回归。
  group('computeBookProgress wired + real-shelf data (BUG-680 复诉守卫)', () {
    test(
        '_bookToMediaItem 把 computeBookProgress 结果喂进 MediaItem.position/duration '
        '(锁死「算了没接上」)', () {
      final String source = File(
        'lib/src/media/sources/reader_hibiki_source.dart',
      ).readAsStringSync();
      // 修复必须真接上渲染：_bookToMediaItem 调 computeBookProgress 并用它的
      // position/duration 建 MediaItem。断了这根线(PM 怀疑的「char_offset 纳入了但渲染
      // 分支没走到」)就退回复诉症状。
      expect(source, contains('computeBookProgress('));
      expect(source, contains('position = prog.position'));
      expect(source, contains('duration = prog.duration'));
    });

    test(
        '用户真实 リビルド (sec=8, charOffset=11120)：章内 charOffset 让「旧包看着像 0%」'
        '的在读书前进', () {
      // 用户本机 reader_positions x epub_books 真值：前 8 章多为前言(0 字)，当前第 8 章
      // 23707 字。旧包(debug.6783)忽略 charOffset -> 只算前 8 章 = 286 字(<0.2%，看着像空
      // 条)；修复把章内 11120 计入。
      const List<int> rebuild = <int>[
        0, 0, 0, 0, 0, 110, 0, 176, //
        23707, 10923, 9904, 24592, 9883, 14559, 16308, 8977, 14023, 13684, //
        10311, 12330, 11187, 9891, 0, 0, 0, 0, 301, 351, 0,
      ];
      final int before8 = rebuild.take(8).reduce((int a, int b) => a + b);
      expect(before8, 286); // 旧包忽略 charOffset 时的 position
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: rebuild,
        sectionIndex: 8,
        charOffset: 11120,
      );
      expect(prog.position, before8 + 11120); // 章内进度计入
      expect(prog.position, greaterThan(before8),
          reason: '修复必须让被旧包算成近 0 的在读书前进');
      expect(prog.position / prog.duration, greaterThan(0.05),
          reason: 'リビルド 现场进度应 ~5.96%(可见)，而非旧包的 0.15%');
    });

    test(
        '用户真实 安達9 (sec=6, charOffset=0，前节全前言)：诚实 0%——'
        '不是 BUG-659 回归也不灌水', () {
      // 前 6 节全是前言(0 字)、第 6 节是首个内容页起点。读者停在正文开头前 -> 已读字符=0。
      // 按字符计数的诚实结果(不为好看谎报进度)；用户升级后仍会见 0%，属预期。
      const List<int> adachi9 = <int>[
        0, 0, 0, 0, 0, 0, 106, 51, 0, 8760, 2017, 0, 19647, 0, //
        429, 8510, 1717, 0, 10541, 2148, 0, 5738, 18, 0, 0, 206, 181, 0,
      ];
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: adachi9,
        sectionIndex: 6,
        charOffset: 0,
      );
      expect(prog.position, 0, reason: '前节全前言 -> 已读正文字符=0，诚实 0%');
      expect(prog.duration, greaterThan(0), reason: '全书有字数，分母非 0(不是老书回退分支)');
    });
  });

  // BUG-728：书架有声书进度条听书时不更新。听书 cue 派生位置无精确字符偏移，
  // reader_positions.charOffset 存 -1（哨兵），章内进度只落在 normCharOffset（0-10000
  // 章内归一化分数）里。旧 computeBookProgress 只认 charOffset、把 -1 当 0，令听书进度
  // 停在章边界甚至显 0%（用户「有声书好像少了进度条」）。修复：charOffset<0 时回退
  // normCharOffset 分数（与阅读器 restore 的回退口径一致）。
  group('computeBookProgress normCharOffset 回退 (BUG-728 听书进度)', () {
    // 三章：前=100+200=300，当前章(idx 2)字数 400，全书 700。
    const List<int> chars = <int>[100, 200, 400];
    const int before = 300; // Σchars[0..1]
    const int total = 700;

    test('charOffset=-1 + normCharOffset=5000（章内一半）→ 计入半章进度，不停在章首', () {
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: chars,
        sectionIndex: 2,
        charOffset: -1,
        normCharOffset: 5000,
      );
      expect(prog.duration, total);
      // intra = round(5000/10000 * 400) = 200。
      expect(prog.position, before + 200);
      // 关键回归：必须比「norm 缺省 0（旧行为）」的章首更前进。
      final ({int position, int duration}) atStart = computeBookProgress(
        sectionChars: chars,
        sectionIndex: 2,
        charOffset: -1,
      );
      expect(prog.position, greaterThan(atStart.position),
          reason: '听书章内进度必须让书架进度前进，而非停在 charOffset=-1 的章首');
    });

    test('charOffset=-1 + normCharOffset=10000（章尾）→ 满章计入', () {
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: chars,
        sectionIndex: 2,
        charOffset: -1,
        normCharOffset: 10000,
      );
      expect(prog.position, before + 400); // = total = 100%
      expect(prog.position, total);
    });

    test('charOffset=-1 + normCharOffset=0（章首/未推进）→ 诚实停在章首', () {
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: chars,
        sectionIndex: 2,
        charOffset: -1,
        normCharOffset: 0,
      );
      expect(prog.position, before);
    });

    test('精确 charOffset>=0 优先于 normCharOffset（正常阅读书不受影响）', () {
      // 读书写精确 charOffset=250；即便 normCharOffset 陈旧为 9999 也不得被采纳。
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: chars,
        sectionIndex: 2,
        charOffset: 250,
        normCharOffset: 9999,
      );
      expect(prog.position, before + 250,
          reason: 'charOffset>=0 是精确值，必须压过归一化分数');
    });

    test('normCharOffset 越界（>10000）→ clamp，绝不 >100%', () {
      final ({int position, int duration}) prog = computeBookProgress(
        sectionChars: chars,
        sectionIndex: 2,
        charOffset: -1,
        normCharOffset: 99999, // 脏数据
      );
      expect(prog.position, total); // clamp 到满章，不溢出
      expect(prog.position, lessThanOrEqualTo(total));
    });

    test('源码守卫：_bookToMediaItem 把 normCharOffset 传进 computeBookProgress', () {
      final String source = File(
        'lib/src/media/sources/reader_hibiki_source.dart',
      ).readAsStringSync();
      // 断了这根线（只传 charOffset）就退回 BUG-728 症状：听书进度停在章边界。
      expect(source, contains('normCharOffset: pos?.normCharOffset'));
    });
  });
}
