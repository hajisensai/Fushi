import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1018：override 身份与写穿。
///
/// - A3：standalone SRT 书（bookKey 空串哨兵）以前全部共享
///   `mediaIdentifierFor('')`，override 书名互相踩、作者保存静默 no-op。现在
///   身份是 `hoshi://srtbook/<uid>`（每书唯一），作者真实写穿 SrtBooks.author。
/// - 附带：编辑保存没选新封面时不再落 0 字节 override 封面文件。
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
}
