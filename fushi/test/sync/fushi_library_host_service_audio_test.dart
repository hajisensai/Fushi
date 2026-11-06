import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_storage_platform.dart';
import 'package:fushi/src/models/local_audio_manager.dart'
    show LocalAudioDbEntry;
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/media/audiobook/standalone_subtitle_book.dart';
import 'package:fushi_engine/media/import/epub_backed_srt_book.dart';
import 'package:fushi_engine/models/local_audio_source_pref.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show AudiobookStorage, SrtBook, SrtBookRepository;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../helpers/engine_storage_sandbox.dart';

// ── 辅助 ──────────────────────────────────────────────────────────────────────

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

/// 在 [db] 中插入一个有声书（Audiobooks + SrtBooks + AudioCues）。
/// 同时在 [audioDir] 写入假音频/对齐文件以满足 exportAudioDatabasePackage。
Future<String> _insertAudiobook({
  required FushiDatabase db,
  required String bookKey,
  required Directory audioDir,
}) async {
  audioDir.createSync(recursive: true);
  final File track = File(p.join(audioDir.path, 'track.m4b'))
    ..writeAsBytesSync(<int>[1, 2, 3, 4]);
  final File align = File(p.join(audioDir.path, 'align.srt'))
    ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello\n');

  const String srtUid = 'srt-test-uid';

  await db.upsertAudiobook(
    AudiobooksCompanion.insert(
      bookKey: bookKey,
      audioRoot: Value(audioDir.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      alignmentFormat: 'srt',
      alignmentPath: align.path,
    ),
  );
  await db.upsertSrtBook(
    SrtBooksCompanion.insert(
      uid: srtUid,
      title: 'Test Audiobook',
      audioRoot: Value(audioDir.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      srtPath: align.path,
      importedAt: 0,
      bookKey: Value(bookKey),
    ),
  );
  await db.replaceCuesForBook(bookKey, <AudioCuesCompanion>[
    AudioCuesCompanion.insert(
      bookKey: bookKey,
      chapterHref: 'ch1.xhtml',
      sentenceIndex: 0,
      textFragmentId: 'f0',
      cueText: 'hello',
      startMs: 0,
      endMs: 1000,
      audioFileIndex: 0,
    ),
  ]);
  return srtUid;
}

/// 构造一个用于音频测试的 [LocalLibraryHostService]。
LocalLibraryHostService _buildSvc({
  required FushiDatabase db,
  List<LocalAudioDbEntry> localAudioEntries = const <LocalAudioDbEntry>[],
  Directory? localAudioStagingDir,
  List<LocalAudioPackageContents>? importedAudioContents,
  Directory? audioDatabaseRoot,
}) {
  return LocalLibraryHostService(
    db: db,
    dictionaryResourceRoot: Directory.systemTemp,
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
    localAudioEntries: localAudioEntries,
    localAudioStagingDir: localAudioStagingDir,
    onLocalAudioImported: importedAudioContents == null
        ? null
        : (LocalAudioPackageContents c) async => importedAudioContents.add(c),
    audioDatabaseRoot: audioDatabaseRoot,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ══════════════════════════════════════════════════════════════════════════
  // computeKeyUnionDiff 纯函数（本地音频 displayName）
  // ══════════════════════════════════════════════════════════════════════════

  group('computeKeyUnionDiff（本地音频 displayName）', () {
    test(
      'union by displayName: pull remote-only, push local-only, skip shared',
      () {
        final SyncKeyDiff diff = computeKeyUnionDiff(
          localKeys: <String>{'NHK', 'Forvo'},
          remoteKeys: <String>{'Forvo', 'JapanesePod101'},
        );
        expect(diff.toPull, <String>{'JapanesePod101'});
        expect(diff.toPush, <String>{'NHK'});
      },
    );

    test('两端均空 → 空 diff', () {
      final SyncKeyDiff diff = computeKeyUnionDiff(
        localKeys: <String>{},
        remoteKeys: <String>{},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, isEmpty);
    });

    test('本端全在远端 → toPush 为空', () {
      final SyncKeyDiff diff = computeKeyUnionDiff(
        localKeys: <String>{'A', 'B'},
        remoteKeys: <String>{'A', 'B', 'C'},
      );
      expect(diff.toPush, isEmpty);
      expect(diff.toPull, <String>{'C'});
    });

    test('远端全在本端 → toPull 为空', () {
      final SyncKeyDiff diff = computeKeyUnionDiff(
        localKeys: <String>{'A', 'B'},
        remoteKeys: <String>{'A'},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, <String>{'B'});
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // computeKeyUnionDiff 纯函数（有声书 bookKey）
  // ══════════════════════════════════════════════════════════════════════════

  group('computeKeyUnionDiff（有声书 bookKey）', () {
    test(
      'union by bookKey: pull remote-only, push local-only, skip shared',
      () {
        final SyncKeyDiff diff = computeKeyUnionDiff(
          localKeys: <String>{'book-a', 'book-b'},
          remoteKeys: <String>{'book-b', 'book-c'},
        );
        expect(diff.toPull, <String>{'book-c'});
        expect(diff.toPush, <String>{'book-a'});
      },
    );

    test('两端均空 → 空 diff', () {
      final SyncKeyDiff diff = computeKeyUnionDiff(
        localKeys: <String>{},
        remoteKeys: <String>{},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, isEmpty);
    });

    test('两端共有所有 → 两侧均为空', () {
      final SyncKeyDiff diff = computeKeyUnionDiff(
        localKeys: <String>{'x', 'y'},
        remoteKeys: <String>{'x', 'y'},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, isEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // RemoteLocalAudioInfo JSON round-trip
  // ══════════════════════════════════════════════════════════════════════════

  group('RemoteLocalAudioInfo', () {
    test('toJson / fromJson round-trip', () {
      const RemoteLocalAudioInfo info = RemoteLocalAudioInfo(
        displayName: 'NHK日本語',
      );
      final RemoteLocalAudioInfo decoded = RemoteLocalAudioInfo.fromJson(
        info.toJson(),
      );
      expect(decoded.displayName, info.displayName);
    });

    test('fromJson 缺字段降级为安全默认值', () {
      final RemoteLocalAudioInfo info = RemoteLocalAudioInfo.fromJson(
        <String, Object?>{},
      );
      expect(info.displayName, '');
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // RemoteAudiobookInfo JSON round-trip
  // ══════════════════════════════════════════════════════════════════════════

  group('RemoteAudiobookInfo', () {
    test('toJson / fromJson round-trip（含 title）', () {
      const RemoteAudiobookInfo info = RemoteAudiobookInfo(
        bookKey: 'ttu-42',
        title: '夏目漱石',
      );
      final RemoteAudiobookInfo decoded = RemoteAudiobookInfo.fromJson(
        info.toJson(),
      );
      expect(decoded.bookKey, info.bookKey);
      expect(decoded.title, info.title);
    });

    test('toJson / fromJson round-trip（title 为 null）', () {
      const RemoteAudiobookInfo info = RemoteAudiobookInfo(bookKey: 'ttu-99');
      final RemoteAudiobookInfo decoded = RemoteAudiobookInfo.fromJson(
        info.toJson(),
      );
      expect(decoded.bookKey, 'ttu-99');
      expect(decoded.title, isNull);
    });

    test('fromJson 缺字段降级为安全默认值', () {
      final RemoteAudiobookInfo info = RemoteAudiobookInfo.fromJson(
        <String, Object?>{},
      );
      expect(info.bookKey, '');
      expect(info.title, isNull);
    });

    test('srt-backed：identity=bookKey、非 standalone', () {
      const RemoteAudiobookInfo info = RemoteAudiobookInfo(
        bookKey: 'ttu-1',
        uid: 'u1',
        title: 'T',
      );
      expect(info.identity, 'ttu-1');
      expect(info.isStandaloneSrt, isFalse);
      final RemoteAudiobookInfo decoded = RemoteAudiobookInfo.fromJson(
        info.toJson(),
      );
      expect(decoded.uid, 'u1');
      expect(decoded.identity, 'ttu-1');
    });

    test('纯 SRT standalone：bookKey 空 → identity=uid、isStandaloneSrt', () {
      const RemoteAudiobookInfo info = RemoteAudiobookInfo(
        bookKey: '',
        uid: 'srt-uid-9',
        title: 'S',
      );
      expect(info.identity, 'srt-uid-9');
      expect(info.isStandaloneSrt, isTrue);
      final RemoteAudiobookInfo decoded = RemoteAudiobookInfo.fromJson(
        info.toJson(),
      );
      expect(decoded.bookKey, '');
      expect(decoded.uid, 'srt-uid-9');
      expect(decoded.identity, 'srt-uid-9');
      expect(decoded.isStandaloneSrt, isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 纯 SRT（standalone）有声书：枚举 + 身份解析导出
  // ══════════════════════════════════════════════════════════════════════════

  group('纯 SRT standalone 有声书', () {
    late FushiDatabase db;
    late Directory temp;

    // 收端按 cue 再生成正文要真跑 EPUB 导入（BUG-4158）。
    useEngineStorageSandbox();

    setUp(() async {
      db = _memDb();
      temp = await Directory.systemTemp.createTemp('fushi-standalone-svc-');
      // 本机导入字幕书时的有声书持久目录。
      AudiobookStorage.documentsRootResolver = () async => temp;
    });

    tearDown(() async {
      await db.close();
      AudiobookStorage.documentsRootResolver = null;
      await temp.delete(recursive: true);
    });

    /// 走真实本机导入（[importStandaloneSubtitleBook]）造一本独立字幕书：字幕 +
    /// 音频、没有 EPUB，正文由 cue 生成。返回落库的 SrtBooks 行。
    Future<SrtBookRow> importSubtitleBook(
      FushiDatabase into,
      String title,
      List<String> lines,
    ) async {
      final Directory src = Directory(p.join(temp.path, 'src_$title'))
        ..createSync(recursive: true);
      final File audio = File(p.join(src.path, '01.mp3'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final StringBuffer srt = StringBuffer();
      for (int i = 0; i < lines.length; i++) {
        srt
          ..writeln(i + 1)
          ..writeln('00:00:0$i,000 --> 00:00:0$i,900')
          ..writeln(lines[i])
          ..writeln();
      }
      final File subs = File(p.join(src.path, '$title.srt'))
        ..writeAsStringSync(srt.toString());
      final SrtBook book = await importStandaloneSubtitleBook(
        db: into,
        repo: SrtBookRepository(into),
        title: title,
        subtitlePath: subs.path,
        audioPaths: <String>[audio.path],
        copyAudio: false,
        policy: const DuplicatePolicy.suffix(),
      );
      return (await into.getSrtBookByUid(book.uid))!;
    }

    /// 正文解压树里所有 xhtml 的文本拼在一起（断言正文就是由这组 cue 生成的）。
    Future<String> bodyText(FushiDatabase from, String bookKey) async {
      final EpubBookRow row = (await from.getEpubBook(bookKey))!;
      final StringBuffer out = StringBuffer();
      await for (final FileSystemEntity e in Directory(
        row.extractDir,
      ).list(recursive: true)) {
        if (e is File && e.path.endsWith('.xhtml')) {
          out.write(await e.readAsString());
        }
      }
      return out.toString();
    }

    Future<void> insertStandalone(String uid, String title) async {
      final Directory audioDir = Directory(p.join(temp.path, uid));
      audioDir.createSync(recursive: true);
      final File track = File(p.join(audioDir.path, 'voice.mp3'))
        ..writeAsStringSync('a');
      final File subs = File(p.join(audioDir.path, 'subs.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nx\n');
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: uid,
          title: title,
          audioRoot: Value(audioDir.path),
          audioPathsJson: Value(jsonEncode(<String>[track.path])),
          srtPath: subs.path,
          importedAt: 1,
          bookKey: const Value(''),
        ),
      );
    }

    test('listAudiobooks 同时枚举 srt-backed 与 standalone', () async {
      await _insertAudiobook(
        db: db,
        bookKey: 'ttu-42',
        audioDir: Directory(p.join(temp.path, 'ab')),
      );
      await insertStandalone('srt-standalone-1', '纯字幕书');

      final LocalLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteAudiobookInfo> list = await svc.listAudiobooks();
      final Map<String, RemoteAudiobookInfo> byIdentity =
          <String, RemoteAudiobookInfo>{
            for (final RemoteAudiobookInfo a in list) a.identity: a,
          };

      expect(
        byIdentity.keys,
        containsAll(<String>['ttu-42', 'srt-standalone-1']),
      );
      expect(byIdentity['ttu-42']!.isStandaloneSrt, isFalse);
      final RemoteAudiobookInfo standalone = byIdentity['srt-standalone-1']!;
      expect(standalone.isStandaloneSrt, isTrue);
      expect(standalone.bookKey, '');
      expect(standalone.uid, 'srt-standalone-1');
      expect(standalone.title, '纯字幕书');
    });

    test('audiobookExists(uid) 对 standalone 为 true', () async {
      await insertStandalone('srt-x', 'X');
      final LocalLibraryHostService svc = _buildSvc(db: db);
      expect(await svc.audiobookExists('srt-x'), isTrue);
      expect(await svc.audiobookExists('nonexistent'), isFalse);
    });

    test('exportAudiobook(uid) 打纯 SRT 包（无 audiobook 段）并可导入落 SrtBook', () async {
      await insertStandalone('srt-standalone-2', 'Standalone2');
      final LocalLibraryHostService svc = _buildSvc(db: db);

      final File pkg = await svc.exportAudiobook('srt-standalone-2');
      addTearDown(() {
        try {
          pkg.parent.deleteSync(recursive: true);
        } catch (_) {}
      });

      final FushiDatabase targetDb = _memDb();
      addTearDown(targetDb.close);
      final Directory targetAudio = Directory(p.join(temp.path, 'target'));
      await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
        packageFile: pkg,
        audioDatabaseRoot: targetAudio,
        bookKeyOverride: 'srt-standalone-2', // server 会传 identity，须被忽略
      );

      expect(await targetDb.getAllAudiobooks(), isEmpty);
      final SrtBookRow srt = (await targetDb.getSrtBookByUid(
        'srt-standalone-2',
      ))!;
      // BUG-4158：bookKey 为空的字幕书阅读器打不开（「正文未就绪」）。收端给它
      // 生成正文（这本没有 cue → 只有标题的正文，与本机导入无字幕书同一行为）。
      expect(srt.bookKey, isNotEmpty);
      expect(await targetDb.getEpubBook(srt.bookKey), isNotNull);
      expect(srt.title, 'Standalone2');
    });

    // ── BUG-4158：带生成正文的独立字幕书 ─────────────────────────────────────

    test('BUG-4158 host 把带生成正文的独立字幕书按 uid 列进有声书清单，正文标成字幕书正文', () async {
      final SrtBookRow book = await importSubtitleBook(db, 'SubBook', <String>[
        'こんにちは。',
        'さようなら。',
      ]);
      expect(book.bookKey, isNotEmpty, reason: '本机导入会生成正文');

      final LocalLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteAudiobookInfo> audiobooks = await svc.listAudiobooks();
      final RemoteAudiobookInfo listed = audiobooks.singleWhere(
        (RemoteAudiobookInfo a) => a.uid == book.uid,
      );
      expect(listed.isStandaloneSrt, isTrue);
      expect(listed.identity, book.uid);

      final RemoteBookInfo body = (await svc.listBooks()).singleWhere(
        (RemoteBookInfo b) => b.bookKey == book.bookKey,
      );
      expect(body.isSubtitleBookBody, isTrue);
      expect(body.hasAudiobook, isFalse);
      // 线上形态：只在为真时下发，旧 client 忽略。
      expect(body.toJson()['subtitleBookBody'], isTrue);
      expect(RemoteBookInfo.fromJson(body.toJson()).isSubtitleBookBody, isTrue);
    });

    test('BUG-4158 EPUB 有声书的配对行缺了 Audiobooks 行也不当独立字幕书', () async {
      const String bookKey = 'UserNovel';
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: epubBackedSrtBookUid(bookKey),
          title: 'UserNovel',
          srtPath: p.join(temp.path, 'x.srt'),
          importedAt: 1,
          bookKey: const Value(bookKey),
        ),
      );
      final LocalLibraryHostService svc = _buildSvc(db: db);
      expect(
        (await svc.listAudiobooks()).map((RemoteAudiobookInfo a) => a.uid),
        isNot(contains(epubBackedSrtBookUid(bookKey))),
      );
      expect(
        isStandaloneSubtitleBook(
          uid: epubBackedSrtBookUid(bookKey),
          bookKey: bookKey,
          audiobookKeys: const <String>{},
        ),
        isFalse,
      );
      expect(
        srtBookHasGeneratedBody(
          uid: epubBackedSrtBookUid(bookKey),
          bookKey: bookKey,
        ),
        isFalse,
      );
    });

    test('BUG-4158 收端按包里的 cue 再生成正文；重新下载沿用同一本正文不另生', () async {
      final SrtBookRow hostBook = await importSubtitleBook(
        db,
        'RoundTrip',
        <String>['一行目です。', '二行目です。'],
      );
      final LocalLibraryHostService host = _buildSvc(db: db);

      final FushiDatabase client = _memDb();
      addTearDown(client.close);
      final Directory clientAudio = Directory(p.join(temp.path, 'client_ab'));
      final SyncAssetPackageService clientPackages = SyncAssetPackageService(
        db: client,
      );

      Future<void> download() async {
        final File pkg = await host.exportAudiobook(hostBook.uid);
        try {
          await clientPackages.importAudioDatabasePackage(
            packageFile: pkg,
            audioDatabaseRoot: clientAudio,
            bookKeyOverride: hostBook.uid,
          );
        } finally {
          await pkg.parent.delete(recursive: true);
        }
      }

      await download();
      final SrtBookRow got = (await client.getSrtBookByUid(hostBook.uid))!;
      expect(got.bookKey, isNotEmpty, reason: '打得开 = 有正文');
      expect(await client.getAllAudiobooks(), isEmpty, reason: '身份仍是 uid');
      final String text = await bodyText(client, got.bookKey);
      expect(text, contains('一行目です。'));
      expect(text, contains('二行目です。'));
      expect(await client.getAllEpubBooks(), hasLength(1));

      await download();
      final SrtBookRow again = (await client.getSrtBookByUid(hostBook.uid))!;
      expect(again.bookKey, got.bookKey);
      expect(await client.getAllEpubBooks(), hasLength(1), reason: '不另生一本');
    });

    test('BUG-4158 只更新字幕：换了 cue 收端按新 cue 重建正文', () async {
      final SrtBookRow hostBook = await importSubtitleBook(
        db,
        'Refresh',
        <String>['古い一行目。'],
      );
      final LocalLibraryHostService host = _buildSvc(db: db);
      final FushiDatabase client = _memDb();
      addTearDown(client.close);
      final Directory clientAudio = Directory(p.join(temp.path, 'client_ab'));
      final SyncAssetPackageService clientPackages = SyncAssetPackageService(
        db: client,
      );
      final File pkg = await host.exportAudiobook(hostBook.uid);
      await clientPackages.importAudioDatabasePackage(
        packageFile: pkg,
        audioDatabaseRoot: clientAudio,
      );
      await pkg.parent.delete(recursive: true);
      final String clientKey = (await client.getSrtBookByUid(
        hostBook.uid,
      ))!.bookKey;

      // host 换字幕（cue 文本变了）后，client 只拉字幕侧。
      await db.replaceCuesForBook(hostBook.uid, <AudioCuesCompanion>[
        AudioCuesCompanion.insert(
          bookKey: hostBook.uid,
          chapterHref: '',
          sentenceIndex: 0,
          textFragmentId: '',
          cueText: '新しい一行目。',
          startMs: 0,
          endMs: 900,
          audioFileIndex: 0,
        ),
      ]);
      final File subs = await host.exportAudiobookSubtitles(hostBook.uid);
      await clientPackages.importAudioSubtitlePackage(
        packageFile: subs,
        audioDatabaseRoot: clientAudio,
      );
      await subs.parent.delete(recursive: true);

      final String text = await bodyText(client, clientKey);
      expect(text, contains('新しい一行目。'));
      expect(text, isNot(contains('古い一行目。')));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // _assertSafeName（路径穿越防护）
  // ══════════════════════════════════════════════════════════════════════════

  group('_assertSafeName 对 displayName/bookKey 的路径穿越防护', () {
    late FushiDatabase db;

    setUp(() {
      db = _memDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('exportLocalAudio 拒绝 "../evil" 并抛 ArgumentError', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportLocalAudio('../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('exportLocalAudio 拒绝含斜线的名称', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportLocalAudio('foo/bar'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('exportLocalAudio 拒绝空名称', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportLocalAudio(''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('exportAudiobook 拒绝 "../evil" 并抛 ArgumentError', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportAudiobook('../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('exportAudiobook 拒绝含反斜线的名称', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportAudiobook('foo\\bar'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('deleteAudiobook 拒绝 "../evil" 并抛 ArgumentError', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.deleteAudiobook('../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('deleteLocalAudio 拒绝 "../evil" 并抛 ArgumentError', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.deleteLocalAudio('../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 本地音频 list / export / delete round-trip
  // ══════════════════════════════════════════════════════════════════════════

  group('LocalLibraryHostService 本地音频', () {
    late Directory tmp;
    late FushiDatabase db;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_local_audio_svc');
      db = _memDb();
    });

    tearDown(() async {
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('listLocalAudio 反映注入的 localAudioEntries', () async {
      final File dbFile = File(p.join(tmp.path, 'nhk.db'))
        ..writeAsBytesSync(<int>[0, 1]);
      final LocalLibraryHostService svc = _buildSvc(
        db: db,
        localAudioEntries: <LocalAudioDbEntry>[
          LocalAudioDbEntry(path: dbFile.path, displayName: 'NHK'),
          LocalAudioDbEntry(path: dbFile.path, displayName: 'Forvo'),
        ],
      );

      final List<RemoteLocalAudioInfo> list = await svc.listLocalAudio();
      expect(
        list.map((RemoteLocalAudioInfo i) => i.displayName),
        unorderedEquals(<String>['NHK', 'Forvo']),
      );
    });

    test('listLocalAudio 无条目时返回空列表', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      expect(await svc.listLocalAudio(), isEmpty);
    });

    test('exportLocalAudio 产出非空 .fushiaudiolib 文件', () async {
      // 造一个真实的 .db stub（sqlite 文件头 16 字节足够让 sqlite 识别，但
      // exportLocalAudioPackage 只关心文件存在与否，不解析内容）。
      final File dbFile = File(p.join(tmp.path, 'nhk.db'))
        ..writeAsBytesSync(List<int>.generate(16, (int i) => i));

      final LocalLibraryHostService svc = _buildSvc(
        db: db,
        localAudioEntries: <LocalAudioDbEntry>[
          LocalAudioDbEntry(
            path: dbFile.path,
            displayName: 'NHK',
            sources: <LocalAudioSourcePref>[
              LocalAudioSourcePref(name: 'nhk_daily', enabled: true),
            ],
          ),
        ],
      );

      final File pkg = await svc.exportLocalAudio('NHK');
      addTearDown(() {
        if (pkg.parent.existsSync()) pkg.parent.deleteSync(recursive: true);
      });

      expect(pkg.existsSync(), isTrue);
      expect(pkg.lengthSync(), greaterThan(0));
      expect(pkg.path, endsWith('.fushiaudiolib'));
    });

    test('exportLocalAudio 对不存在的 displayName 抛 StateError', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportLocalAudio('NonExistent'),
        throwsA(isA<StateError>()),
      );
    });

    test('exportLocalAudio 对 DB 文件不存在的来源抛 StateError', () async {
      final LocalLibraryHostService svc = _buildSvc(
        db: db,
        localAudioEntries: <LocalAudioDbEntry>[
          LocalAudioDbEntry(
            path: p.join(tmp.path, 'gone.db'), // 文件不存在
            displayName: 'GoneLib',
          ),
        ],
      );
      await expectLater(
        svc.exportLocalAudio('GoneLib'),
        throwsA(isA<StateError>()),
      );
    });

    // ── importLocalAudio 回调注入 ────────────────────────────────────────────

    test('importLocalAudio 调用注入的 onLocalAudioImported 回调', () async {
      // 先 export 一个真实包，再 import 它并验证回调被调且 displayName 正确。
      final File dbFile = File(p.join(tmp.path, 'nhk2.db'))
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);

      final LocalLibraryHostService exportSvc = _buildSvc(
        db: db,
        localAudioEntries: <LocalAudioDbEntry>[
          LocalAudioDbEntry(path: dbFile.path, displayName: 'NHK2'),
        ],
      );
      final File pkg = await exportSvc.exportLocalAudio('NHK2');
      addTearDown(() {
        if (pkg.parent.existsSync()) pkg.parent.deleteSync(recursive: true);
      });

      final List<LocalAudioPackageContents> received =
          <LocalAudioPackageContents>[];
      final Directory stagingDir = Directory(p.join(tmp.path, 'staging'))
        ..createSync();
      final LocalLibraryHostService importSvc = _buildSvc(
        db: db,
        localAudioStagingDir: stagingDir,
        importedAudioContents: received,
      );

      await importSvc.importLocalAudio(pkg);

      expect(received, hasLength(1));
      expect(received.first.displayName, 'NHK2');
    });

    test('importLocalAudio 无回调时抛 UnsupportedError', () async {
      final File dbFile = File(p.join(tmp.path, 'nhk3.db'))
        ..writeAsBytesSync(<int>[0]);

      final LocalLibraryHostService exportSvc = _buildSvc(
        db: db,
        localAudioEntries: <LocalAudioDbEntry>[
          LocalAudioDbEntry(path: dbFile.path, displayName: 'NHK3'),
        ],
      );
      final File pkg = await exportSvc.exportLocalAudio('NHK3');
      addTearDown(() {
        if (pkg.parent.existsSync()) pkg.parent.deleteSync(recursive: true);
      });

      // 无 onLocalAudioImported 回调
      final LocalLibraryHostService noCallbackSvc = _buildSvc(db: db);
      await expectLater(
        noCallbackSvc.importLocalAudio(pkg),
        throwsA(isA<UnsupportedError>()),
      );
    });

    // ── deleteLocalAudio（基础实现：仅名称校验）────────────────────────────

    test('deleteLocalAudio 对合法名称不抛（基础 no-op 实现）', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      // 基础实现是 no-op，仅校验名称安全性
      await svc.deleteLocalAudio('ValidName'); // 不应抛异常
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 有声书 list / export / delete round-trip
  // ══════════════════════════════════════════════════════════════════════════

  group('LocalLibraryHostService 有声书', () {
    late Directory tmp;
    late FushiDatabase db;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_audiobook_svc');
      db = _memDb();
      // deleteAudiobook 经 AudiobookStorage.audiobooksRootDir() →
      // getApplicationDocumentsDirectory()；mock path_provider 让持久根落在受控
      // <tmp>/docs 下，使「内部复制」与「引用导入」路径可被正确判定。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (MethodCall call) async {
              if (call.method == 'getApplicationDocumentsDirectory') {
                final Directory docs = Directory(p.join(tmp.path, 'docs'))
                  ..createSync(recursive: true);
                return docs.path;
              }
              return null;
            },
          );
      // 平台兜底（getApplicationDocumentsDirectory → 上面的 mock）现在由重文件装配。
      installAudiobookStoragePlatform();
    });

    tearDown(() async {
      await db.close();
      AudiobookStorage.documentsRootResolver = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('listAudiobooks 反映 Audiobooks 表', () async {
      final Directory audioDir = Directory(p.join(tmp.path, 'ab1'));
      await _insertAudiobook(db: db, bookKey: 'ttu-test', audioDir: audioDir);

      final LocalLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteAudiobookInfo> list = await svc.listAudiobooks();

      expect(list, hasLength(1));
      expect(list.first.bookKey, 'ttu-test');
    });

    test('listAudiobooks 不暴露缺少 SrtBooks 行的孤儿有声书', () async {
      await db.upsertAudiobook(
        AudiobooksCompanion.insert(
          bookKey: 'orphan-audiobook',
          audioRoot: Value(p.join(tmp.path, 'orphan')),
          alignmentFormat: 'srt',
          alignmentPath: p.join(tmp.path, 'orphan.srt'),
        ),
      );

      final LocalLibraryHostService svc = _buildSvc(db: db);

      expect(await svc.listAudiobooks(), isEmpty);
    });

    test('listAudiobooks 无有声书时返回空列表', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      expect(await svc.listAudiobooks(), isEmpty);
    });

    test('exportAudiobook 产出非空 .fushiaudio 文件', () async {
      final Directory audioDir = Directory(p.join(tmp.path, 'ab2'));
      await _insertAudiobook(db: db, bookKey: 'ttu-export', audioDir: audioDir);

      final LocalLibraryHostService svc = _buildSvc(db: db);
      final File pkg = await svc.exportAudiobook('ttu-export');
      addTearDown(() {
        if (pkg.parent.existsSync()) pkg.parent.deleteSync(recursive: true);
      });

      expect(pkg.existsSync(), isTrue);
      expect(pkg.lengthSync(), greaterThan(0));
      expect(pkg.path, endsWith('.fushiaudio'));
    });

    test('exportAudiobook 对不存在的 bookKey 抛 StateError', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportAudiobook('nonexistent-key'),
        throwsA(isA<StateError>()),
      );
    });

    // ── importAudiobook 回调注入 ─────────────────────────────────────────────

    test('importAudiobook 无 audioDatabaseRoot 时抛 UnsupportedError', () async {
      // 造一个假的 .fushiaudio 文件（不需要真实内容，因为会在 audioDatabaseRoot 检查前抛）
      final File fakeAudio = File(p.join(tmp.path, 'fake.fushiaudio'))
        ..writeAsBytesSync(<int>[0]);

      final LocalLibraryHostService svc = _buildSvc(
        db: db,
      ); // audioDatabaseRoot 为 null
      await expectLater(
        svc.importAudiobook(fakeAudio),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('importAudiobook 调用 importAudioDatabasePackage（回调注入验证）', () async {
      // export → import round-trip：
      // 导出后重新 import 到不同 audioDatabaseRoot，验证 DB 条目被正确写入。
      final Directory audioDir = Directory(p.join(tmp.path, 'source'));
      await _insertAudiobook(db: db, bookKey: 'ttu-rt', audioDir: audioDir);

      final LocalLibraryHostService svc = _buildSvc(db: db);
      final File pkg = await svc.exportAudiobook('ttu-rt');
      addTearDown(() {
        if (pkg.parent.existsSync()) pkg.parent.deleteSync(recursive: true);
      });

      // 用不同 DB 和 audioDatabaseRoot 来 import，模拟跨设备场景
      final FushiDatabase targetDb = _memDb();
      addTearDown(targetDb.close);
      final Directory targetAudioRoot = Directory(p.join(tmp.path, 'target'))
        ..createSync();

      final LocalLibraryHostService importSvc = LocalLibraryHostService(
        db: targetDb,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: targetDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        audioDatabaseRoot: targetAudioRoot,
      );

      await importSvc.importAudiobook(pkg, bookKeyOverride: 'ttu-rt');

      // 验证 DB 中已有 audiobook 行
      final AudiobookRow? imported = await targetDb.getAudiobookByBookKey(
        'ttu-rt',
      );
      expect(imported, isNotNull);
      expect(imported!.bookKey, 'ttu-rt');
    });

    // ── deleteAudiobook ──────────────────────────────────────────────────────

    test(
      'deleteAudiobook 后 listAudiobooks 不含该书，内部复制的 audioRoot 目录被删',
      () async {
        // 内部复制音频落在 <docs>/audiobooks 持久根内 → isReferencedPath=false → 删。
        final Directory audioDir = Directory(
          p.join(tmp.path, 'docs', 'audiobooks', 'del-audio'),
        );
        await _insertAudiobook(db: db, bookKey: 'ttu-del', audioDir: audioDir);

        expect(audioDir.existsSync(), isTrue);

        final LocalLibraryHostService svc = _buildSvc(db: db);
        await svc.deleteAudiobook('ttu-del');

        final List<RemoteAudiobookInfo> list = await svc.listAudiobooks();
        expect(list, isEmpty);
        expect(audioDir.existsSync(), isFalse);
      },
    );

    test('deleteAudiobook 保留「引用导入」的外部 audioRoot（TODO-935 ①A 守卫）', () async {
      // 引用导入：音频在持久根外的用户原始目录 → isReferencedPath=true → 绝不删源。
      final Directory externalDir = Directory(
        p.join(tmp.path, 'user-external', 'ref-audio'),
      );
      await _insertAudiobook(db: db, bookKey: 'ttu-ref', audioDir: externalDir);

      expect(externalDir.existsSync(), isTrue);

      final LocalLibraryHostService svc = _buildSvc(db: db);
      await svc.deleteAudiobook('ttu-ref');

      final List<RemoteAudiobookInfo> list = await svc.listAudiobooks();
      expect(list, isEmpty);
      // DB 行已删，但用户外部原始目录保留。
      expect(externalDir.existsSync(), isTrue);
    });

    test('deleteAudiobook 不存在的 bookKey 静默跳过（幂等）', () async {
      final LocalLibraryHostService svc = _buildSvc(db: db);
      // 不应抛异常
      await svc.deleteAudiobook('nonexistent');
    });
  });
}
