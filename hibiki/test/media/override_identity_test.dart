import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/media/display_title.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1018：override 身份与写穿。
///
/// - A3：standalone SRT 书（bookKey 空串哨兵）以前全部共享
///   `mediaIdentifierFor('')`，override 书名互相踩、作者保存静默 no-op。现在
///   身份是 `hoshi://srtbook/<uid>`（每书唯一），作者真实写穿 SrtBooks.author。
/// - 附带：编辑保存没选新封面时不再落 0 字节 override 封面文件。
///
/// BUG-1317：override 书名 / 封面的键与存储命名空间都把**源键**烧了进去，而
/// 源键随 `EpubBooks.format` 现算（epub / manga / pdf），于是同一本书在不同
/// 消费面读到不同的键。现在规范位置只由 `mediaIdentifier` 决定，书族三源统一
/// 归 EPUB 源存，旧位置在读取期回退并就地重写。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SrtBook standaloneSrtBook(String uid, {String title = '字幕书'}) {
    return SrtBook()
      ..uid = uid
      ..title = title
      ..srtPath = '/tmp/$uid.srt'
      ..importedAt = DateTime.now().millisecondsSinceEpoch
      ..bookKey = '';
  }

  MediaItem srtItem(String uid) {
    final ReaderHibikiSource source = ReaderHibikiSource.instance;
    return MediaItem(
      mediaIdentifier: ReaderHibikiSource.mediaIdentifierForSrtUid(uid),
      title: '字幕书',
      mediaTypeIdentifier: source.mediaType.uniqueKey,
      mediaSourceIdentifier: source.uniqueKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
    );
  }

  group('standalone SRT media identity (BUG-1018 A3)', () {
    test('srt identifiers are per-uid and round-trip losslessly', () {
      final String a = ReaderHibikiSource.mediaIdentifierForSrtUid('srtbook_1');
      final String b = ReaderHibikiSource.mediaIdentifierForSrtUid('srtbook_2');
      expect(a, isNot(b));
      expect(ReaderHibikiSource.parseSrtBookUid(a), 'srtbook_1');
      expect(ReaderHibikiSource.parseSrtBookUid(b), 'srtbook_2');
      // 与 EPUB 书身份空间不相交：互不解析。
      expect(ReaderHibikiSource.parseBookKey(a), isNull);
      expect(
        ReaderHibikiSource.parseSrtBookUid(
            ReaderHibikiSource.mediaIdentifierFor('someBookKey')),
        isNull,
      );
    });

    test('override title on one standalone SRT book does not leak to another',
        () async {
      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      final MediaItem itemA = srtItem('srtbook_a');
      final MediaItem itemB = srtItem('srtbook_b');
      addTearDown(
          () => source.setOverrideTitleFromMediaItem(item: itemA, title: null));

      await source.setOverrideTitleFromMediaItem(item: itemA, title: '新名A');

      expect(source.overrideTitleForSrtUid('srtbook_a'), '新名A');
      expect(source.overrideTitleForSrtUid('srtbook_b'), isNull);
      expect(source.getOverrideTitleFromMediaItem(itemB), isNull);
    });

    test('setAuthorFromMediaItem writes through to srt_books.author', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);
      final SrtBookRepository repo = SrtBookRepository(db);
      await repo.save(standaloneSrtBook('srtbook_author'));

      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      await source.setAuthorFromMediaItem(
        item: srtItem('srtbook_author'),
        author: '  某作者  ',
      );
      expect((await repo.findByUid('srtbook_author'))!.author, '某作者');

      // 空白清除（与 updateEpubBookAuthor 同语义）。
      await source.setAuthorFromMediaItem(
        item: srtItem('srtbook_author'),
        author: '   ',
      );
      expect((await repo.findByUid('srtbook_author'))!.author, isNull);
    });

    test('setAuthorFromMediaItem on an unknown srt uid is a safe no-op',
        () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      await ReaderHibikiSource.instance.setAuthorFromMediaItem(
        item: srtItem('srtbook_missing'),
        author: 'X',
      );
      // 不抛、不落行。
      expect(await db.getSrtBookByUid('srtbook_missing'), isNull);
    });
  });

  group('override thumbnail file hygiene (BUG-1018 附带)', () {
    late Directory storeDir;
    late HibikiDatabase db;
    late AppModel appModel;

    setUp(() async {
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      storeDir = Directory.systemTemp.createTempSync('hibiki_override_thumb');
      appModel = AppModel(testPlatformServices())
        ..wireDatabaseForTesting(db)
        ..wireLocalAudioForTesting(
          prefsRepo: prefs,
          databaseDirectory: storeDir,
        );
    });

    tearDown(() async {
      await db.close();
      if (storeDir.existsSync()) {
        storeDir.deleteSync(recursive: true);
      }
    });

    test('save without a new image leaves NO 0-byte override cover behind',
        () async {
      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      final MediaItem item = srtItem('srtbook_cover');
      final String filename = source.getOverrideThumbnailFilename(
        appModel: appModel,
        item: item,
      );

      await source.setOverrideThumbnailFromMediaItem(
        appModel: appModel,
        item: item,
        file: null,
        clearOverrideImage: false,
      );

      expect(File(filename).existsSync(), isFalse,
          reason: '未选新图也未清除时不得落空文件（否则封面渲染成损坏占位）');
    });

    test('picking a real image writes it; clearing deletes it', () async {
      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      final MediaItem item = srtItem('srtbook_cover2');
      final String filename = source.getOverrideThumbnailFilename(
        appModel: appModel,
        item: item,
      );
      final File picked = File('${storeDir.path}/picked.png')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);

      await source.setOverrideThumbnailFromMediaItem(
        appModel: appModel,
        item: item,
        file: picked,
        clearOverrideImage: false,
      );
      expect(File(filename).existsSync(), isTrue);
      expect(File(filename).lengthSync(), 4);

      await source.setOverrideThumbnailFromMediaItem(
        appModel: appModel,
        item: item,
        file: null,
        clearOverrideImage: true,
      );
      expect(File(filename).existsSync(), isFalse);
    });
  });

  /// BUG-1317：override 书名 / 封面的身份是**书**，不是「用哪个阅读器打开」。
  ///
  /// 旧实现把源键烧进了 key 字符串（出现两次）与偏好命名空间（`src:<src>:`），而
  /// 一本书的源键由 `EpubBooks.format` 现算（epub→reader_ttu / manga→reader_manga
  /// / pdf→reader_pdf）。于是漫画 / PDF 书改名后，书架、首页、统计、通知栏读到的
  /// 键各不相同；EPUB 转漫画后连书架也读不回来。
  group('override identity is per-book, not per-reader (BUG-1317)', () {
    const String kBookKey = 'bug1317_book';
    final String kMediaId = ReaderHibikiSource.mediaIdentifierFor(kBookKey);

    /// 书族三源共用同一 `hoshi://book/<bookKey>` 身份，只有源键不同——这正是
    /// `_bookToMediaItem` 按 format 现算出来的三种形态。
    MediaItem bookItem(MediaSource source, {String mediaIdentifier = ''}) {
      return MediaItem(
        mediaIdentifier: mediaIdentifier.isEmpty ? kMediaId : mediaIdentifier,
        title: '原始书名',
        mediaTypeIdentifier: source.mediaType.uniqueKey,
        mediaSourceIdentifier: source.uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      );
    }

    List<MediaSource> bookSources() => <MediaSource>[
          ReaderHibikiSource.instance,
          MangaHibikiSource.instance,
          ReaderPdfSource.instance,
        ];

    /// 把一条 override 书名写进 BUG-1317 之前的**旧位置**：源自己的偏好命名空间
    /// + 源键出现两次的旧键。这就是旧代码的写入路径。
    Future<void> writeLegacyTitle(
        MediaSource source, String mediaIdentifier, String title) async {
      await source.setPreference<String?>(
        key: MediaSource.legacyOverrideTitleKey(
          sourceId: source.uniqueKey,
          mediaIdentifier: mediaIdentifier,
        ),
        value: title,
      );
    }

    String? readLegacyTitle(MediaSource source, String mediaIdentifier) {
      return source.getPreference<String?>(
        key: MediaSource.legacyOverrideTitleKey(
          sourceId: source.uniqueKey,
          mediaIdentifier: mediaIdentifier,
        ),
        defaultValue: null,
      );
    }

    Future<void> purge(String mediaIdentifier) async {
      for (final MediaSource source in bookSources()) {
        await source.clearOverrideTitle(
            bookItem(source, mediaIdentifier: mediaIdentifier));
      }
    }

    setUp(() async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);
    });

    test('规范键只含 mediaIdentifier —— 源键一次都不出现', () async {
      addTearDown(() => purge(kMediaId));
      final String epubKey = ReaderHibikiSource.instance
          .getOverrideTitleKey(bookItem(ReaderHibikiSource.instance));
      final String mangaKey = MangaHibikiSource.instance
          .getOverrideTitleKey(bookItem(MangaHibikiSource.instance));
      final String pdfKey = ReaderPdfSource.instance
          .getOverrideTitleKey(bookItem(ReaderPdfSource.instance));

      expect(epubKey, 'override_title://$kMediaId');
      expect(mangaKey, epubKey, reason: '同一本书三种 format 必须解析出同一个键');
      expect(pdfKey, epubKey);
      for (final MediaSource source in bookSources()) {
        expect(epubKey.contains(source.uniqueKey), isFalse,
            reason: '规范键里绝不能再出现源键 ${source.uniqueKey}');
      }
    });

    test('新键写入读出：三种 format 下互相可见', () async {
      addTearDown(() => purge(kMediaId));
      // 用户在漫画身份下改名（编辑弹窗按真实 format 解析出 MangaHibikiSource）。
      await MangaHibikiSource.instance.setOverrideTitleFromMediaItem(
        item: bookItem(MangaHibikiSource.instance),
        title: '用户改的名',
      );

      for (final MediaSource source in bookSources()) {
        expect(
          source.getOverrideTitleFromMediaItem(bookItem(source)),
          '用户改的名',
          reason: '${source.uniqueKey} 也必须读到同一本书的 override',
        );
      }
    });

    test('旧键回退：三个源各一，都能读到并就地重写成新键', () async {
      for (final MediaSource legacy in bookSources()) {
        // 一源一本书，避免互相干扰。
        final String mediaId =
            ReaderHibikiSource.mediaIdentifierFor('legacy_${legacy.uniqueKey}');
        addTearDown(() => purge(mediaId));
        await writeLegacyTitle(legacy, mediaId, '旧名_${legacy.uniqueKey}');

        // 读侧恒用 EPUB 源（首页 / 统计 / 通知栏走的 _overrideTitleForIdentifier
        // 就是这条路），必须能穿透到另外两个源的旧命名空间。
        final MediaItem readItem =
            bookItem(ReaderHibikiSource.instance, mediaIdentifier: mediaId);
        expect(
          ReaderHibikiSource.instance.getOverrideTitleFromMediaItem(readItem),
          '旧名_${legacy.uniqueKey}',
          reason: '旧位置（${legacy.uniqueKey} 命名空间 + 旧键形态）必须被回退读到',
        );

        // 就地重写：旧键已被删，规范键已落值。
        expect(readLegacyTitle(legacy, mediaId), isNull,
            reason: '命中后必须删掉旧键，否则回退层永远清不掉');
        expect(
          ReaderHibikiSource.instance.overrideStore.getPreference<String?>(
            key: 'override_title://$mediaId',
            defaultValue: null,
          ),
          '旧名_${legacy.uniqueKey}',
          reason: '命中后必须把值就地重写进规范键',
        );
      }
    });

    test('转化 epub 到 manga 再转回后 override 书名不丢', () async {
      final String mediaId =
          ReaderHibikiSource.mediaIdentifierFor('bug1317_convert');
      addTearDown(() => purge(mediaId));
      // 存量：用户在 EPUB 时代改过名（旧位置）。
      await writeLegacyTitle(ReaderHibikiSource.instance, mediaId, '我的书');

      // 转成漫画：源键变 reader_manga。
      expect(
        MangaHibikiSource.instance.getOverrideTitleFromMediaItem(
          bookItem(MangaHibikiSource.instance, mediaIdentifier: mediaId),
        ),
        '我的书',
      );
      // 在漫画身份下再改一次名。
      await MangaHibikiSource.instance.setOverrideTitleFromMediaItem(
        item: bookItem(MangaHibikiSource.instance, mediaIdentifier: mediaId),
        title: '我的漫画',
      );
      // 转回 EPUB：仍是最新的名字，没有被旧值复活。
      expect(
        ReaderHibikiSource.instance.getOverrideTitleFromMediaItem(
          bookItem(ReaderHibikiSource.instance, mediaIdentifier: mediaId),
        ),
        '我的漫画',
      );
    });

    test('清除改名后旧位置不会把旧名复活', () async {
      final String mediaId =
          ReaderHibikiSource.mediaIdentifierFor('bug1317_clear');
      addTearDown(() => purge(mediaId));
      await writeLegacyTitle(ReaderPdfSource.instance, mediaId, '旧名');

      await ReaderPdfSource.instance.setOverrideTitleFromMediaItem(
        item: bookItem(ReaderPdfSource.instance, mediaIdentifier: mediaId),
        title: null,
      );

      expect(
        ReaderHibikiSource.instance.getOverrideTitleFromMediaItem(
          bookItem(ReaderHibikiSource.instance, mediaIdentifier: mediaId),
        ),
        isNull,
        reason: '清除后必须真的没有名字，不能被旧位置回退复活',
      );
    });

    test('书架 / 首页 / 统计 / 通知栏四个消费面拿到同一个值', () async {
      const String bookKey = 'bug1317_surfaces';
      final String mediaId = ReaderHibikiSource.mediaIdentifierFor(bookKey);
      addTearDown(() => purge(mediaId));
      // 存量场景：书是漫画，用户在旧版本改过名（写进 reader_manga 命名空间）。
      await writeLegacyTitle(MangaHibikiSource.instance, mediaId, '四处一致');

      // 书架：卡片持有 _bookToMediaItem 产出的真实源 item，走 item 通道。
      final String shelf = displayTitleForBook(
        item: bookItem(MangaHibikiSource.instance, mediaIdentifier: mediaId),
        rawTitle: '原始书名',
      );
      // 首页「继续阅读」/ 活动流：只有 bookKey。
      final String home =
          displayTitleForBook(bookKey: bookKey, rawTitle: '原始书名');
      // 阅读统计明细行（reading_statistics_page）与有声书通知栏元数据
      // （audiobook_session_launcher）走的是同一个入口。
      final String? stats =
          ReaderHibikiSource.instance.overrideTitleForBookKey(bookKey);
      final String? notification =
          ReaderHibikiSource.instance.overrideTitleForBookKey(bookKey);

      expect(shelf, '四处一致');
      expect(home, '四处一致');
      expect(stats, '四处一致');
      expect(notification, '四处一致');
    });
  });

  /// BUG-1317 封面侧：旧文件名把源键烧进 hashCode，转化 / 改名后读不回来。
  group('override cover identity is per-book, not per-reader (BUG-1317)', () {
    late Directory storeDir;
    late HibikiDatabase db;
    late AppModel appModel;

    MediaItem coverItem(MediaSource source, String bookKey) {
      return MediaItem(
        mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(bookKey),
        title: '原始书名',
        mediaTypeIdentifier: source.mediaType.uniqueKey,
        mediaSourceIdentifier: source.uniqueKey,
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      );
    }

    setUp(() async {
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      storeDir = Directory.systemTemp.createTempSync('hibiki_override_1317');
      appModel = AppModel(testPlatformServices())
        ..wireDatabaseForTesting(db)
        ..wireLocalAudioForTesting(
          prefsRepo: prefs,
          databaseDirectory: storeDir,
        );
    });

    tearDown(() async {
      await db.close();
      if (storeDir.existsSync()) {
        storeDir.deleteSync(recursive: true);
      }
    });

    test('规范封面文件名三种 format 下同名，且不由源键派生', () {
      const String bookKey = 'cover_same';
      final Set<String> names = <String>{
        for (final MediaSource source in <MediaSource>[
          ReaderHibikiSource.instance,
          MangaHibikiSource.instance,
          ReaderPdfSource.instance,
        ])
          source.getOverrideThumbnailFilename(
            appModel: appModel,
            item: coverItem(source, bookKey),
          ),
      };
      expect(names.length, 1, reason: '同一本书三种 format 必须落到同一个封面文件名');
      // 旧文件名（源键烧进 hash）必须与规范名不同 —— 否则回退层测的是同一个东西。
      expect(
        ReaderHibikiSource.instance.legacyOverrideThumbnailFilename(
          appModel: appModel,
          item: coverItem(ReaderHibikiSource.instance, bookKey),
          sourceId: ReaderHibikiSource.instance.uniqueKey,
        ),
        isNot(names.single),
      );
    });

    test('旧封面文件名三源各一，都能被回退读到并就地 rename 成规范名', () {
      for (final MediaSource legacy in <MediaSource>[
        ReaderHibikiSource.instance,
        MangaHibikiSource.instance,
        ReaderPdfSource.instance,
      ]) {
        final String bookKey = 'cover_legacy_${legacy.uniqueKey}';
        final MediaItem item = coverItem(legacy, bookKey);
        final String legacyPath = legacy.legacyOverrideThumbnailFilename(
          appModel: appModel,
          item: item,
          sourceId: legacy.uniqueKey,
        );
        final String canonicalPath = legacy.getOverrideThumbnailFilename(
          appModel: appModel,
          item: item,
        );
        File(legacyPath).parent.createSync(recursive: true);
        File(legacyPath).writeAsBytesSync(<int>[9, 9, 9]);

        // 读侧恒用 EPUB 源（首页 / 书架 hero 都合成 EPUB 身份）。
        final File? resolved =
            ReaderHibikiSource.instance.resolveOverrideThumbnailFile(
          appModel: appModel,
          item: coverItem(ReaderHibikiSource.instance, bookKey),
        );
        expect(resolved, isNotNull,
            reason: '${legacy.uniqueKey} 的旧封面文件名必须被回退读到');
        expect(resolved!.path, canonicalPath, reason: '命中后必须就地 rename 成规范名');
        expect(File(canonicalPath).existsSync(), isTrue);
        expect(File(canonicalPath).lengthSync(), 3, reason: '内容必须原样搬过来');
        expect(File(legacyPath).existsSync(), isFalse, reason: '旧文件不得留下孤儿');
      }
    });

    test('转化 epub 到 manga 后 override 封面不丢', () {
      const String bookKey = 'cover_convert';
      // 存量：EPUB 时代写下的旧文件名。
      final String legacyPath =
          ReaderHibikiSource.instance.legacyOverrideThumbnailFilename(
        appModel: appModel,
        item: coverItem(ReaderHibikiSource.instance, bookKey),
        sourceId: ReaderHibikiSource.instance.uniqueKey,
      );
      File(legacyPath).parent.createSync(recursive: true);
      File(legacyPath).writeAsBytesSync(<int>[7, 7]);

      // 书转成漫画后由漫画源读。
      final File? resolved =
          MangaHibikiSource.instance.resolveOverrideThumbnailFile(
        appModel: appModel,
        item: coverItem(MangaHibikiSource.instance, bookKey),
      );
      expect(resolved, isNotNull);
      expect(resolved!.lengthSync(), 2);
    });

    test('清除封面后旧文件名不会把封面复活', () async {
      const String bookKey = 'cover_clear';
      final MediaItem item = coverItem(MangaHibikiSource.instance, bookKey);
      final String legacyPath =
          MangaHibikiSource.instance.legacyOverrideThumbnailFilename(
        appModel: appModel,
        item: item,
        sourceId: MangaHibikiSource.instance.uniqueKey,
      );
      File(legacyPath).parent.createSync(recursive: true);
      File(legacyPath).writeAsBytesSync(<int>[5]);

      await MangaHibikiSource.instance.setOverrideThumbnailFromMediaItem(
        appModel: appModel,
        item: item,
        file: null,
        clearOverrideImage: true,
      );

      expect(
        ReaderHibikiSource.instance.resolveOverrideThumbnailFile(
          appModel: appModel,
          item: coverItem(ReaderHibikiSource.instance, bookKey),
        ),
        isNull,
        reason: '清除后旧文件名必须一起删掉，否则回退层会把封面复活',
      );
    });
  });
}
