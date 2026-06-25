import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../pages/reader_history_source_corpus.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/reader/reader_settings.dart';

void main() {
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
    test('内部 hoshi.local 书内 URL 永不当外部链接(未解析时不弹系统浏览器)', () {
      expect(
        ReaderHibikiSource.isExternalUrl(
            'https://hoshi.local/epub/OEBPS/ch2.xhtml'),
        isFalse,
      );
      expect(
        ReaderHibikiSource.isExternalUrl(
            'https://hoshi.local/epub/text/note.xhtml#n1'),
        isFalse,
      );
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
      expect(result.fontFaces, isNot(contains('..')));
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
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
      await db.deletePref('src:reader_ttu:shortcut_bindings_json');
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
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
      await db.setPref('src:reader_ttu:auto_read_on_lookup', 'true');
      await source.refreshPreferencesFromDb();
      expect(source.autoReadOnLookup, isTrue);
    });

    test('toggleAutoReadOnLookup 写穿 DB 且读写对称(不再依赖静态 readerSettings)', () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
        await db.getPref('src:reader_ttu:auto_read_on_lookup'),
        'b:false',
      );

      // 再开启：对称回到 true。
      source.toggleAutoReadOnLookup();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(source.autoReadOnLookup, isTrue);
      expect(
        await db.getPref('src:reader_ttu:auto_read_on_lookup'),
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
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
        await db.getPref('src:reader_ttu:hover_auto_lookup'),
        'b:true',
      );

      // Disable: round-trips back to false.
      await source.setHoverAutoLookup(value: false);
      expect(source.hoverAutoLookup, isFalse);
      expect(
        await db.getPref('src:reader_ttu:hover_auto_lookup'),
        'b:false',
      );
    });

    test('profile switch (refreshPreferencesFromDb) is reflected', () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();
      expect(source.hoverAutoLookup, isFalse);

      // Simulate switching to a profile that enabled hover-auto.
      await db.setPref('src:reader_ttu:hover_auto_lookup', 'b:true');
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
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
        await db.getPref('src:reader_ttu:invert_audiobook_skip_direction'),
        'b:true',
      );
    });

    test(
        'reads/writes through ReaderSettings (per-reader) when a reader page '
        'is open, mirroring invert_swipe / reverse_arrow', () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
        await db.getPref('src:reader_ttu:invert_audiobook_skip_direction'),
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
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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

    test('setAuthorFromMediaItem trims and clears a blank author to NULL',
        () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.insertEpubBook(bookWithAuthor('SameKey', author: 'old'));

      await db.updateEpubBookAuthor('SameKey', 'new');

      final row = await db.getEpubBook('SameKey');
      expect(row, isNotNull, reason: 'bookKey (primary key) must be unchanged');
      expect(row!.author, 'new');
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
}
