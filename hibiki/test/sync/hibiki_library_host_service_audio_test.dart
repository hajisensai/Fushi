import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_manager.dart'
    show LocalAudioDbEntry;
import 'package:hibiki/src/models/local_audio_source_pref.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

// ── 辅助 ──────────────────────────────────────────────────────────────────────

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// 在 [db] 中插入一个有声书（Audiobooks + SrtBooks + AudioCues）。
/// 同时在 [audioDir] 写入假音频/对齐文件以满足 exportAudioDatabasePackage。
Future<String> _insertAudiobook({
  required HibikiDatabase db,
  required String bookKey,
  required Directory audioDir,
}) async {
  audioDir.createSync(recursive: true);
  final File track = File(p.join(audioDir.path, 'track.m4b'))
    ..writeAsBytesSync(<int>[1, 2, 3, 4]);
  final File align = File(p.join(audioDir.path, 'align.srt'))
    ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello\n');

  const String srtUid = 'srt-test-uid';

  await db.upsertAudiobook(AudiobooksCompanion.insert(
    bookKey: bookKey,
    audioRoot: Value(audioDir.path),
    audioPathsJson: Value(jsonEncode(<String>[track.path])),
    alignmentFormat: 'srt',
    alignmentPath: align.path,
  ));
  await db.upsertSrtBook(SrtBooksCompanion.insert(
    uid: srtUid,
    title: 'Test Audiobook',
    audioRoot: Value(audioDir.path),
    audioPathsJson: Value(jsonEncode(<String>[track.path])),
    srtPath: align.path,
    importedAt: 0,
    bookKey: Value(bookKey),
  ));
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

/// 构造一个用于音频测试的 [AppModelLibraryHostService]。
AppModelLibraryHostService _buildSvc({
  required HibikiDatabase db,
  List<LocalAudioDbEntry> localAudioEntries = const <LocalAudioDbEntry>[],
  Directory? localAudioStagingDir,
  List<LocalAudioPackageContents>? importedAudioContents,
  Directory? audioDatabaseRoot,
}) {
  return AppModelLibraryHostService(
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
  // computeLocalAudioSyncDiff 纯函数
  // ══════════════════════════════════════════════════════════════════════════

  group('computeLocalAudioSyncDiff', () {
    test('union by displayName: pull remote-only, push local-only, skip shared',
        () {
      final LocalAudioSyncDiff diff = computeLocalAudioSyncDiff(
        localNames: <String>{'NHK', 'Forvo'},
        remoteNames: <String>{'Forvo', 'JapanesePod101'},
      );
      expect(diff.toPull, <String>{'JapanesePod101'});
      expect(diff.toPush, <String>{'NHK'});
    });

    test('两端均空 → 空 diff', () {
      final LocalAudioSyncDiff diff = computeLocalAudioSyncDiff(
        localNames: <String>{},
        remoteNames: <String>{},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, isEmpty);
    });

    test('本端全在远端 → toPush 为空', () {
      final LocalAudioSyncDiff diff = computeLocalAudioSyncDiff(
        localNames: <String>{'A', 'B'},
        remoteNames: <String>{'A', 'B', 'C'},
      );
      expect(diff.toPush, isEmpty);
      expect(diff.toPull, <String>{'C'});
    });

    test('远端全在本端 → toPull 为空', () {
      final LocalAudioSyncDiff diff = computeLocalAudioSyncDiff(
        localNames: <String>{'A', 'B'},
        remoteNames: <String>{'A'},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, <String>{'B'});
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // computeAudiobookSyncDiff 纯函数
  // ══════════════════════════════════════════════════════════════════════════

  group('computeAudiobookSyncDiff', () {
    test('union by bookKey: pull remote-only, push local-only, skip shared',
        () {
      final AudiobookSyncDiff diff = computeAudiobookSyncDiff(
        localKeys: <String>{'book-a', 'book-b'},
        remoteKeys: <String>{'book-b', 'book-c'},
      );
      expect(diff.toPull, <String>{'book-c'});
      expect(diff.toPush, <String>{'book-a'});
    });

    test('两端均空 → 空 diff', () {
      final AudiobookSyncDiff diff = computeAudiobookSyncDiff(
        localKeys: <String>{},
        remoteKeys: <String>{},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, isEmpty);
    });

    test('两端共有所有 → 两侧均为空', () {
      final AudiobookSyncDiff diff = computeAudiobookSyncDiff(
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
      const RemoteLocalAudioInfo info =
          RemoteLocalAudioInfo(displayName: 'NHK日本語');
      final RemoteLocalAudioInfo decoded =
          RemoteLocalAudioInfo.fromJson(info.toJson());
      expect(decoded.displayName, info.displayName);
    });

    test('fromJson 缺字段降级为安全默认值', () {
      final RemoteLocalAudioInfo info =
          RemoteLocalAudioInfo.fromJson(<String, Object?>{});
      expect(info.displayName, '');
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // RemoteAudiobookInfo JSON round-trip
  // ══════════════════════════════════════════════════════════════════════════

  group('RemoteAudiobookInfo', () {
    test('toJson / fromJson round-trip（含 title）', () {
      const RemoteAudiobookInfo info =
          RemoteAudiobookInfo(bookKey: 'ttu-42', title: '夏目漱石');
      final RemoteAudiobookInfo decoded =
          RemoteAudiobookInfo.fromJson(info.toJson());
      expect(decoded.bookKey, info.bookKey);
      expect(decoded.title, info.title);
    });

    test('toJson / fromJson round-trip（title 为 null）', () {
      const RemoteAudiobookInfo info = RemoteAudiobookInfo(bookKey: 'ttu-99');
      final RemoteAudiobookInfo decoded =
          RemoteAudiobookInfo.fromJson(info.toJson());
      expect(decoded.bookKey, 'ttu-99');
      expect(decoded.title, isNull);
    });

    test('fromJson 缺字段降级为安全默认值', () {
      final RemoteAudiobookInfo info =
          RemoteAudiobookInfo.fromJson(<String, Object?>{});
      expect(info.bookKey, '');
      expect(info.title, isNull);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // _assertSafeName（路径穿越防护）
  // ══════════════════════════════════════════════════════════════════════════

  group('_assertSafeName 对 displayName/bookKey 的路径穿越防护', () {
    late HibikiDatabase db;

    setUp(() {
      db = _memDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('exportLocalAudio 拒绝 "../evil" 并抛 ArgumentError', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportLocalAudio('../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('exportLocalAudio 拒绝含斜线的名称', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportLocalAudio('foo/bar'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('exportLocalAudio 拒绝空名称', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportLocalAudio(''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('exportAudiobook 拒绝 "../evil" 并抛 ArgumentError', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportAudiobook('../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('exportAudiobook 拒绝含反斜线的名称', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportAudiobook('foo\\bar'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('deleteAudiobook 拒绝 "../evil" 并抛 ArgumentError', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.deleteAudiobook('../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('deleteLocalAudio 拒绝 "../evil" 并抛 ArgumentError', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.deleteLocalAudio('../evil'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 本地音频 list / export / delete round-trip
  // ══════════════════════════════════════════════════════════════════════════

  group('AppModelLibraryHostService 本地音频', () {
    late Directory tmp;
    late HibikiDatabase db;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_local_audio_svc');
      db = _memDb();
    });

    tearDown(() async {
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('listLocalAudio 反映注入的 localAudioEntries', () async {
      final File dbFile = File(p.join(tmp.path, 'nhk.db'))
        ..writeAsBytesSync(<int>[0, 1]);
      final AppModelLibraryHostService svc = _buildSvc(
        db: db,
        localAudioEntries: <LocalAudioDbEntry>[
          LocalAudioDbEntry(path: dbFile.path, displayName: 'NHK'),
          LocalAudioDbEntry(path: dbFile.path, displayName: 'Forvo'),
        ],
      );

      final List<RemoteLocalAudioInfo> list = await svc.listLocalAudio();
      expect(list.map((RemoteLocalAudioInfo i) => i.displayName),
          unorderedEquals(<String>['NHK', 'Forvo']));
    });

    test('listLocalAudio 无条目时返回空列表', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      expect(await svc.listLocalAudio(), isEmpty);
    });

    test('exportLocalAudio 产出非空 .hibikiaudiolib 文件', () async {
      // 造一个真实的 .db stub（sqlite 文件头 16 字节足够让 sqlite 识别，但
      // exportLocalAudioPackage 只关心文件存在与否，不解析内容）。
      final File dbFile = File(p.join(tmp.path, 'nhk.db'))
        ..writeAsBytesSync(List<int>.generate(16, (int i) => i));

      final AppModelLibraryHostService svc = _buildSvc(
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
      expect(pkg.path, endsWith('.hibikiaudiolib'));
    });

    test('exportLocalAudio 对不存在的 displayName 抛 StateError', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportLocalAudio('NonExistent'),
        throwsA(isA<StateError>()),
      );
    });

    test('exportLocalAudio 对 DB 文件不存在的来源抛 StateError', () async {
      final AppModelLibraryHostService svc = _buildSvc(
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

      final AppModelLibraryHostService exportSvc = _buildSvc(
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
      final AppModelLibraryHostService importSvc = _buildSvc(
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

      final AppModelLibraryHostService exportSvc = _buildSvc(
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
      final AppModelLibraryHostService noCallbackSvc = _buildSvc(db: db);
      await expectLater(
        noCallbackSvc.importLocalAudio(pkg),
        throwsA(isA<UnsupportedError>()),
      );
    });

    // ── deleteLocalAudio（基础实现：仅名称校验）────────────────────────────

    test('deleteLocalAudio 对合法名称不抛（基础 no-op 实现）', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      // 基础实现是 no-op，仅校验名称安全性
      await svc.deleteLocalAudio('ValidName'); // 不应抛异常
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // 有声书 list / export / delete round-trip
  // ══════════════════════════════════════════════════════════════════════════

  group('AppModelLibraryHostService 有声书', () {
    late Directory tmp;
    late HibikiDatabase db;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_audiobook_svc');
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
    });

    tearDown(() async {
      await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('listAudiobooks 反映 Audiobooks 表', () async {
      final Directory audioDir = Directory(p.join(tmp.path, 'ab1'));
      await _insertAudiobook(
        db: db,
        bookKey: 'ttu-test',
        audioDir: audioDir,
      );

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final List<RemoteAudiobookInfo> list = await svc.listAudiobooks();

      expect(list, hasLength(1));
      expect(list.first.bookKey, 'ttu-test');
    });

    test('listAudiobooks 不暴露缺少 SrtBooks 行的孤儿有声书', () async {
      await db.upsertAudiobook(AudiobooksCompanion.insert(
        bookKey: 'orphan-audiobook',
        audioRoot: Value(p.join(tmp.path, 'orphan')),
        alignmentFormat: 'srt',
        alignmentPath: p.join(tmp.path, 'orphan.srt'),
      ));

      final AppModelLibraryHostService svc = _buildSvc(db: db);

      expect(await svc.listAudiobooks(), isEmpty);
    });

    test('listAudiobooks 无有声书时返回空列表', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      expect(await svc.listAudiobooks(), isEmpty);
    });

    test('exportAudiobook 产出非空 .hibikiaudio 文件', () async {
      final Directory audioDir = Directory(p.join(tmp.path, 'ab2'));
      await _insertAudiobook(
        db: db,
        bookKey: 'ttu-export',
        audioDir: audioDir,
      );

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final File pkg = await svc.exportAudiobook('ttu-export');
      addTearDown(() {
        if (pkg.parent.existsSync()) pkg.parent.deleteSync(recursive: true);
      });

      expect(pkg.existsSync(), isTrue);
      expect(pkg.lengthSync(), greaterThan(0));
      expect(pkg.path, endsWith('.hibikiaudio'));
    });

    test('exportAudiobook 对不存在的 bookKey 抛 StateError', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await expectLater(
        svc.exportAudiobook('nonexistent-key'),
        throwsA(isA<StateError>()),
      );
    });

    // ── importAudiobook 回调注入 ─────────────────────────────────────────────

    test('importAudiobook 无 audioDatabaseRoot 时抛 UnsupportedError', () async {
      // 造一个假的 .hibikiaudio 文件（不需要真实内容，因为会在 audioDatabaseRoot 检查前抛）
      final File fakeAudio = File(p.join(tmp.path, 'fake.hibikiaudio'))
        ..writeAsBytesSync(<int>[0]);

      final AppModelLibraryHostService svc =
          _buildSvc(db: db); // audioDatabaseRoot 为 null
      await expectLater(
        svc.importAudiobook(fakeAudio),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('importAudiobook 调用 importAudioDatabasePackage（回调注入验证）', () async {
      // export → import round-trip：
      // 导出后重新 import 到不同 audioDatabaseRoot，验证 DB 条目被正确写入。
      final Directory audioDir = Directory(p.join(tmp.path, 'source'));
      await _insertAudiobook(
        db: db,
        bookKey: 'ttu-rt',
        audioDir: audioDir,
      );

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      final File pkg = await svc.exportAudiobook('ttu-rt');
      addTearDown(() {
        if (pkg.parent.existsSync()) pkg.parent.deleteSync(recursive: true);
      });

      // 用不同 DB 和 audioDatabaseRoot 来 import，模拟跨设备场景
      final HibikiDatabase targetDb = _memDb();
      addTearDown(targetDb.close);
      final Directory targetAudioRoot = Directory(p.join(tmp.path, 'target'))
        ..createSync();

      final AppModelLibraryHostService importSvc = AppModelLibraryHostService(
        db: targetDb,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: targetDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        audioDatabaseRoot: targetAudioRoot,
      );

      await importSvc.importAudiobook(pkg, bookKeyOverride: 'ttu-rt');

      // 验证 DB 中已有 audiobook 行
      final AudiobookRow? imported =
          await targetDb.getAudiobookByBookKey('ttu-rt');
      expect(imported, isNotNull);
      expect(imported!.bookKey, 'ttu-rt');
    });

    // ── deleteAudiobook ──────────────────────────────────────────────────────

    test('deleteAudiobook 后 listAudiobooks 不含该书，内部复制的 audioRoot 目录被删',
        () async {
      // 内部复制音频落在 <docs>/audiobooks 持久根内 → isReferencedPath=false → 删。
      final Directory audioDir =
          Directory(p.join(tmp.path, 'docs', 'audiobooks', 'del-audio'));
      await _insertAudiobook(
        db: db,
        bookKey: 'ttu-del',
        audioDir: audioDir,
      );

      expect(audioDir.existsSync(), isTrue);

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await svc.deleteAudiobook('ttu-del');

      final List<RemoteAudiobookInfo> list = await svc.listAudiobooks();
      expect(list, isEmpty);
      expect(audioDir.existsSync(), isFalse);
    });

    test('deleteAudiobook 保留「引用导入」的外部 audioRoot（TODO-935 ①A 守卫）', () async {
      // 引用导入：音频在持久根外的用户原始目录 → isReferencedPath=true → 绝不删源。
      final Directory externalDir =
          Directory(p.join(tmp.path, 'user-external', 'ref-audio'));
      await _insertAudiobook(
        db: db,
        bookKey: 'ttu-ref',
        audioDir: externalDir,
      );

      expect(externalDir.existsSync(), isTrue);

      final AppModelLibraryHostService svc = _buildSvc(db: db);
      await svc.deleteAudiobook('ttu-ref');

      final List<RemoteAudiobookInfo> list = await svc.listAudiobooks();
      expect(list, isEmpty);
      // DB 行已删，但用户外部原始目录保留。
      expect(externalDir.existsSync(), isTrue);
    });

    test('deleteAudiobook 不存在的 bookKey 静默跳过（幂等）', () async {
      final AppModelLibraryHostService svc = _buildSvc(db: db);
      // 不应抛异常
      await svc.deleteAudiobook('nonexistent');
    });
  });
}
