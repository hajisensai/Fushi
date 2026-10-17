import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

/// 互联「重新拉取有声书 / 字幕」端到端：真 host（[LocalLibraryHostService] +
/// [FushiSyncServer]）↔ 真 client（[InterconnectSyncBackend]），两端各一份内存库。
///
/// 覆盖用户报的场景：client 下载了书的有声书之后，host 上重新转录 / 换了字幕，
/// client 要能把新字幕拉回来，且本机的阅读进度、听书断点不丢。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _bookKey = 'ttu-neko';
const String _srtUid = 'srt-neko';
const String _token = 'refetch-token';

String _srt(List<String> lines) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < lines.length; i++) {
    out
      ..writeln('${i + 1}')
      ..writeln('00:00:0$i,000 --> 00:00:0${i + 1},000')
      ..writeln(lines[i])
      ..writeln();
  }
  return out.toString();
}

List<AudioCuesCompanion> _cues(String key, List<String> lines) =>
    <AudioCuesCompanion>[
      for (int i = 0; i < lines.length; i++)
        AudioCuesCompanion.insert(
          bookKey: key,
          chapterHref: 'ch1.xhtml',
          sentenceIndex: i,
          textFragmentId: 'f$i',
          cueText: lines[i],
          startMs: i * 1000,
          endMs: (i + 1) * 1000,
          audioFileIndex: 0,
        ),
    ];

/// host 上的一本 srt-backed 有声书：一个音频 + 对齐字幕 + token sidecar + cue。
Future<void> _seedHost(FushiDatabase db, Directory dir) async {
  dir.createSync(recursive: true);
  final File track = File(p.join(dir.path, 'track01.m4b'))
    ..writeAsBytesSync(List<int>.generate(4096, (int i) => i % 251));
  final File subs = File(p.join(dir.path, 'transcript.srt'))
    ..writeAsStringSync(_srt(<String>['吾輩は猫である', '名前はまだ無い']));
  File(
    p.join(dir.path, 'transcript.tokens.jsonl'),
  ).writeAsStringSync('{"t":["吾輩"],"o":[0]}\n{"t":["名前"],"o":[0]}\n');
  await db.upsertAudiobook(
    AudiobooksCompanion.insert(
      bookKey: _bookKey,
      audioRoot: Value(dir.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      alignmentFormat: 'srt',
      alignmentPath: subs.path,
      matchRatePct: const Value(80),
    ),
  );
  await db.upsertSrtBook(
    SrtBooksCompanion.insert(
      uid: _srtUid,
      title: '吾輩は猫である',
      audioRoot: Value(dir.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      srtPath: subs.path,
      importedAt: 1,
      bookKey: const Value(_bookKey),
    ),
  );
  await db.replaceCuesForBook(
    _bookKey,
    _cues(_bookKey, <String>['吾輩は猫である', '名前はまだ無い']),
  );
}

/// host 上「重新转录」：字幕文件、对齐结果、cue 全部换新，音频不动。
Future<void> _retranscribeOnHost(FushiDatabase db, Directory dir) async {
  File(p.join(dir.path, 'transcript.srt')).writeAsStringSync(
    _srt(<String>['吾輩は猫である。', '名前はまだ無い。', 'どこで生れたかとんと見当がつかぬ。']),
  );
  await db.patchAudiobook(
    _bookKey,
    const AudiobooksCompanion(matchRatePct: Value(97)),
  );
  await db.replaceCuesForBook(
    _bookKey,
    _cues(_bookKey, <String>['吾輩は猫である。', '名前はまだ無い。', 'どこで生れたかとんと見当がつかぬ。']),
  );
}

const String _soloUid = 'srt-solo';

/// host 上的一本纯字幕（standalone）有声书：无 EPUB、无 Audiobooks 行，身份 = uid，
/// cue 在 uid 命名空间。
Future<void> _seedHostStandalone(FushiDatabase db, Directory dir) async {
  dir.createSync(recursive: true);
  final File track = File(p.join(dir.path, 'solo01.m4b'))
    ..writeAsBytesSync(List<int>.generate(2048, (int i) => (i * 7) % 251));
  final File subs = File(p.join(dir.path, 'solo.srt'))
    ..writeAsStringSync(_srt(<String>['一行目', '二行目']));
  await db.upsertSrtBook(
    SrtBooksCompanion.insert(
      uid: _soloUid,
      title: 'ソロ',
      audioRoot: Value(dir.path),
      audioPathsJson: Value(jsonEncode(<String>[track.path])),
      srtPath: subs.path,
      importedAt: 2,
    ),
  );
  await db.replaceCuesForBook(
    _soloUid,
    _cues(_soloUid, <String>['一行目', '二行目']),
  );
}

/// host 上把纯字幕书重新转录：字幕文件与 cue 换新，音频不动。
Future<void> _retranscribeStandaloneOnHost(
  FushiDatabase db,
  Directory dir,
) async {
  File(
    p.join(dir.path, 'solo.srt'),
  ).writeAsStringSync(_srt(<String>['一行目。', '二行目。', '三行目。']));
  await db.replaceCuesForBook(
    _soloUid,
    _cues(_soloUid, <String>['一行目。', '二行目。', '三行目。']),
  );
}

Future<InterconnectSyncBackend> _buildBackend(String base) async {
  final SyncRepository repo = SyncRepository(_memDb());
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(_token);
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String url, String tok) async => true,
  );
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

void main() {
  // 不初始化 TestWidgetsFlutterBinding：它装的 HttpOverrides 让所有真 HTTP 请求回 400，
  // 而这里要真打本机 FushiSyncServer。
  late Directory temp;
  late FushiDatabase hostDb;
  late FushiDatabase clientDb;
  late Directory hostAudio;
  late Directory clientAudioRoot;
  late FushiSyncServer server;
  late InterconnectSyncBackend backend;

  /// client 端整本下载 / 重新下载（与书架补拉同一条接线：拉包 → 按本机 bookKey 导入）。
  Future<void> clientDownloadAudiobook({bool fresh = false}) async {
    final File pkg = File(p.join(temp.path, 'dl', 'neko.fushiaudio'));
    if (pkg.existsSync()) pkg.deleteSync();
    await backend.getRemoteAudiobook(_bookKey, pkg, fresh: fresh);
    await SyncAssetPackageService(db: clientDb).importAudioDatabasePackage(
      packageFile: pkg,
      audioDatabaseRoot: clientAudioRoot,
      bookKeyOverride: _bookKey,
    );
    pkg.deleteSync();
  }

  /// client 端「只更新字幕」。
  Future<void> clientRefreshSubtitles() async {
    final File pkg = File(p.join(temp.path, 'dl', 'neko.fushisubs'));
    if (pkg.existsSync()) pkg.deleteSync();
    try {
      await backend.getRemoteAudiobookSubtitles(_bookKey, pkg);
      await SyncAssetPackageService(db: clientDb).importAudioSubtitlePackage(
        packageFile: pkg,
        audioDatabaseRoot: clientAudioRoot,
        bookKeyOverride: _bookKey,
      );
    } finally {
      if (pkg.existsSync()) pkg.deleteSync();
    }
  }

  Future<List<String>> clientCueTexts() async => (await clientDb.getCuesForBook(
    _bookKey,
  )).map((AudioCueRow r) => r.cueText).toList();

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fushi_ab_refetch_');
    hostDb = _memDb();
    clientDb = _memDb();
    hostAudio = Directory(p.join(temp.path, 'host-audio'));
    clientAudioRoot = Directory(p.join(temp.path, 'client-audiobooks'));
    await _seedHost(hostDb, hostAudio);
    await _seedHostStandalone(
      hostDb,
      Directory(p.join(temp.path, 'host-solo')),
    );

    final LocalLibraryHostService svc = LocalLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      audioDatabaseRoot: Directory(p.join(temp.path, 'host-audiobooks')),
    );
    server = FushiSyncServer(
      syncDataDir: (Directory(
        p.join(temp.path, 'srv'),
      )..createSync(recursive: true)).path,
      port: 0,
      token: _token,
      allowLan: false,
      libraryService: svc,
    );
    await server.start();
    backend = await _buildBackend('http://127.0.0.1:${server.port}');

    // client 首次下载：书的有声书 + 字幕 v1 落地。
    await clientDownloadAudiobook();
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    await clientDb.close();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  test('host 字幕变了 → 只更新字幕：本机字幕 / cue / 对齐换新，音频与进度保留', () async {
    // client 端本机状态：阅读进度、听书断点、调轴。
    await clientDb.upsertReaderPosition(
      const ReaderPositionsCompanion(
        bookUid: Value('epub-neko'),
        sectionIndex: Value(3),
        normCharOffset: Value(4200),
        charOffset: Value(1234),
        updatedAt: Value(1700000000000),
      ),
    );
    await clientDb.setPrefTyped<int>(audiobookPositionPrefKey(_bookKey), 98765);
    await clientDb.setPrefTyped<int>(audiobookDelayPrefKey(_bookKey), -250);
    final AudiobookRow before = (await clientDb.getAudiobookByBookKey(
      _bookKey,
    ))!;
    final List<String> audioBefore =
        (jsonDecode(before.audioPathsJson!) as List<dynamic>).cast<String>();
    final List<int> audioBytesBefore = File(
      audioBefore.single,
    ).readAsBytesSync();
    expect(await clientCueTexts(), <String>['吾輩は猫である', '名前はまだ無い']);

    await _retranscribeOnHost(hostDb, hostAudio);
    await clientRefreshSubtitles();

    // 字幕侧换新。
    expect(await clientCueTexts(), <String>[
      '吾輩は猫である。',
      '名前はまだ無い。',
      'どこで生れたかとんと見当がつかぬ。',
    ]);
    final SrtBookRow srt = (await clientDb.getSrtBookByBookKey(_bookKey))!;
    expect(File(srt.srtPath).readAsStringSync(), contains('とんと見当がつかぬ'));
    final AudiobookRow after = (await clientDb.getAudiobookByBookKey(
      _bookKey,
    ))!;
    expect(File(after.alignmentPath).readAsStringSync(), contains('とんと見当がつかぬ'));
    expect(after.matchRatePct, 97);
    // token sidecar 跟着字幕一起落在字幕旁边（重新匹配时 attachAsrCueTokenTiming 读它）。
    expect(
      File(p.setExtension(srt.srtPath, '.tokens.jsonl')).existsSync(),
      isTrue,
    );

    // 音频没动：同一份清单、同一批字节。
    expect(after.audioPathsJson, before.audioPathsJson);
    expect(after.audioRoot, before.audioRoot);
    expect(File(audioBefore.single).readAsBytesSync(), audioBytesBefore);
    // 本机进度 / 断点 / 调轴都保留。
    final ReaderPositionRow? pos = await clientDb.getReaderPosition(
      'epub-neko',
    );
    expect(pos!.sectionIndex, 3);
    expect(pos.normCharOffset, 4200);
    expect(
      await clientDb.getPrefTyped<int>(audiobookPositionPrefKey(_bookKey), 0),
      98765,
    );
    expect(
      await clientDb.getPrefTyped<int>(audiobookDelayPrefKey(_bookKey), 0),
      -250,
    );
    // 没有多出第二本 SRT 书。
    expect(await clientDb.getAllSrtBooks(), hasLength(1));
  });

  // BUG-3248：解压是原位覆盖。host 换成了不带逐 token sidecar 的字幕，本机目录里
  // 上一版的 sidecar 不能留在新字幕旁边——行数恰等于 cue 数时会被挂到新 cue 上。
  test('host 没有 tokens sidecar 了 → 更新字幕 / 重新下载都删掉本机旧 sidecar', () async {
    final SrtBookRow first = (await clientDb.getSrtBookByBookKey(_bookKey))!;
    final File sidecar = File(p.setExtension(first.srtPath, '.tokens.jsonl'));
    expect(sidecar.existsSync(), isTrue,
        reason: '整包下载也带 sidecar（与字幕包同口径）');

    // host 换了一份行数相同、但不是转录产物的字幕：没有 sidecar。
    File(p.join(hostAudio.path, 'transcript.tokens.jsonl')).deleteSync();
    File(p.join(hostAudio.path, 'transcript.srt'))
        .writeAsStringSync(_srt(<String>['吾輩は猫である！', '名前はまだ無い！']));
    await hostDb.replaceCuesForBook(
      _bookKey,
      _cues(_bookKey, <String>['吾輩は猫である！', '名前はまだ無い！']),
    );

    await clientRefreshSubtitles();
    final SrtBookRow refreshed = (await clientDb.getSrtBookByBookKey(_bookKey))!;
    expect(File(refreshed.srtPath).readAsStringSync(), contains('！'));
    expect(
      File(p.setExtension(refreshed.srtPath, '.tokens.jsonl')).existsSync(),
      isFalse,
      reason: '旧 sidecar 残留会把旧逐 token 时间挂到新 cue 上',
    );

    // 整本重下同一条原位解压路径：先放回一份旧 sidecar，重下后同样要清掉。
    sidecar.writeAsStringSync('{"t":["吾輩"],"o":[0]}\n{"t":["名前"],"o":[0]}\n');
    await clientDownloadAudiobook(fresh: true);
    final SrtBookRow redownloaded =
        (await clientDb.getSrtBookByBookKey(_bookKey))!;
    expect(
      File(p.setExtension(redownloaded.srtPath, '.tokens.jsonl')).existsSync(),
      isFalse,
    );
  });

  // BUG-3251：「只更新字幕」换 cue 时本机听书断点按真实时间位置换编码（与书架重新
  // 导入同口径，BUG-3197）——多文件有声书的全书毫秒按 cue 推出的文件时长编码。
  test('只更新字幕：多文件断点按新 cue 换编码，真实位置不变', () async {
    AudioCuesCompanion cue(String key, int i, int file, int endMs) =>
        AudioCuesCompanion.insert(
          bookKey: key,
          chapterHref: 'ch1.xhtml',
          sentenceIndex: i,
          textFragmentId: 'f$i',
          cueText: 'line $i',
          startMs: 0,
          endMs: endMs,
          audioFileIndex: file,
        );
    // 本机旧字幕：文件 0 末句 10s；断点 = 文件 1 第 3 秒 = 10000 + 3000。
    await clientDb.replaceCuesForBook(_bookKey, <AudioCuesCompanion>[
      cue(_bookKey, 0, 0, 10000),
      cue(_bookKey, 1, 1, 20000),
    ]);
    await clientDb.setPrefTyped<int>(audiobookPositionPrefKey(_bookKey), 13000);
    // host 新字幕：文件 0 末句 12s。
    await hostDb.replaceCuesForBook(_bookKey, <AudioCuesCompanion>[
      cue(_bookKey, 0, 0, 12000),
      cue(_bookKey, 1, 1, 25000),
    ]);

    await clientRefreshSubtitles();

    expect(
      await clientDb.getPrefTyped<int>(audiobookPositionPrefKey(_bookKey), 0),
      12000 + 3000,
    );
  });

  test('BUG-3098：重新下载整本有声书（fresh）拿到 host 新字幕，不撞 UNIQUE(uid)', () async {
    await _retranscribeOnHost(hostDb, hostAudio);

    // 修复前：第二次导入同一个包，upsertSrtBook 按主键 id 判冲突、撞 UNIQUE(uid)
    // 整个事务回滚——「重新下载有声书」永远失败。fresh 同时绕过 host 15 分钟导出
    // 缓存：setUp 里刚导出过一次 v1，没有 fresh 拿回来的还是 v1。
    await clientDownloadAudiobook(fresh: true);

    expect(await clientCueTexts(), hasLength(3));
    expect((await clientCueTexts()).last, 'どこで生れたかとんと見当がつかぬ。');
    expect(await clientDb.getAllSrtBooks(), hasLength(1));
    expect((await clientDb.getAllSrtBooks()).single.uid, _srtUid);
  });

  test('host 音频条数变了 → 只更新字幕在写库前拒绝（audioMismatch），本机原样', () async {
    final File extra = File(p.join(hostAudio.path, 'track02.m4b'))
      ..writeAsBytesSync(<int>[9, 9, 9]);
    final AudiobookRow hostRow = (await hostDb.getAudiobookByBookKey(
      _bookKey,
    ))!;
    final List<String> paths =
        (jsonDecode(hostRow.audioPathsJson!) as List<dynamic>).cast<String>()
          ..add(extra.path);
    await hostDb.patchAudiobook(
      _bookKey,
      AudiobooksCompanion(audioPathsJson: Value(jsonEncode(paths))),
    );
    await _retranscribeOnHost(hostDb, hostAudio);

    await expectLater(
      clientRefreshSubtitles(),
      throwsA(
        isA<AudiobookSubtitleRefreshException>().having(
          (AudiobookSubtitleRefreshException e) => e.reason,
          'reason',
          AudiobookSubtitleRefreshFailure.audioMismatch,
        ),
      ),
    );
    expect(await clientCueTexts(), <String>['吾輩は猫である', '名前はまだ無い']);
  });

  test('本机没有这本有声书 → 只更新字幕拒绝（notLocal），不凭空建行', () async {
    await clientDb.transaction(() async {
      await clientDb.deleteSrtBookByUid(_srtUid);
      await (clientDb.delete(
        clientDb.audiobooks,
      )..where(($AudiobooksTable t) => t.bookKey.equals(_bookKey))).go();
    });

    await expectLater(
      clientRefreshSubtitles(),
      throwsA(
        isA<AudiobookSubtitleRefreshException>().having(
          (AudiobookSubtitleRefreshException e) => e.reason,
          'reason',
          AudiobookSubtitleRefreshFailure.notLocal,
        ),
      ),
    );
    expect(await clientDb.getAllAudiobooks(), isEmpty);
    expect(await clientDb.getAllSrtBooks(), isEmpty);
  });

  group('纯字幕（standalone）有声书：详情里的「从对端更新字幕 / 重新下载」', () {
    Future<void> clientDownloadStandalone({bool fresh = false}) async {
      final File pkg = File(p.join(temp.path, 'dl', 'solo.fushiaudio'));
      if (pkg.existsSync()) pkg.deleteSync();
      await backend.getRemoteAudiobook(_soloUid, pkg, fresh: fresh);
      // 与书架 _runRemoteSrtAudiobookDownload 同：纯 SRT 包不传 bookKeyOverride。
      await SyncAssetPackageService(db: clientDb).importAudioDatabasePackage(
        packageFile: pkg,
        audioDatabaseRoot: clientAudioRoot,
      );
      pkg.deleteSync();
    }

    Future<void> clientRefreshStandaloneSubtitles() async {
      final File pkg = File(p.join(temp.path, 'dl', 'solo.fushisubs'));
      if (pkg.existsSync()) pkg.deleteSync();
      try {
        // 与书架 _runRemoteSrtSubtitleRefetch 同：身份 = uid，不传 bookKeyOverride。
        await backend.getRemoteAudiobookSubtitles(_soloUid, pkg);
        await SyncAssetPackageService(db: clientDb).importAudioSubtitlePackage(
          packageFile: pkg,
          audioDatabaseRoot: clientAudioRoot,
        );
      } finally {
        if (pkg.existsSync()) pkg.deleteSync();
      }
    }

    Future<List<String>> soloCueTexts() async => (await clientDb.getCuesForBook(
      _soloUid,
    )).map((AudioCueRow r) => r.cueText).toList();

    test('只更新字幕：cue / 字幕文件换新，音频与听书断点保留', () async {
      await clientDownloadStandalone();
      expect(await soloCueTexts(), <String>['一行目', '二行目']);
      await clientDb.setPrefTyped<int>(
        audiobookPositionPrefKey(_soloUid),
        4321,
      );
      final SrtBookRow before = (await clientDb.getSrtBookByUid(_soloUid))!;
      final List<String> audioBefore =
          (jsonDecode(before.audioPathsJson!) as List<dynamic>).cast<String>();
      final List<int> audioBytes = File(audioBefore.single).readAsBytesSync();

      await _retranscribeStandaloneOnHost(
        hostDb,
        Directory(p.join(temp.path, 'host-solo')),
      );
      await clientRefreshStandaloneSubtitles();

      expect(await soloCueTexts(), <String>['一行目。', '二行目。', '三行目。']);
      final SrtBookRow after = (await clientDb.getSrtBookByUid(_soloUid))!;
      expect(after.bookKey, isEmpty, reason: '纯字幕书不能被导入成配对书');
      expect(File(after.srtPath).readAsStringSync(), contains('三行目'));
      expect(after.audioPathsJson, before.audioPathsJson);
      expect(File(audioBefore.single).readAsBytesSync(), audioBytes);
      expect(
        await clientDb.getPrefTyped<int>(audiobookPositionPrefKey(_soloUid), 0),
        4321,
      );
      expect(
        (await clientDb.getAllSrtBooks()).where(
          (SrtBookRow r) => r.uid == _soloUid,
        ),
        hasLength(1),
      );
    });

    test('重新下载（fresh）：二次导入同一 uid 原位更新，不多出一行', () async {
      await clientDownloadStandalone();
      await _retranscribeStandaloneOnHost(
        hostDb,
        Directory(p.join(temp.path, 'host-solo')),
      );
      await clientDownloadStandalone(fresh: true);
      expect(await soloCueTexts(), hasLength(3));
      expect(
        (await clientDb.getAllSrtBooks()).where(
          (SrtBookRow r) => r.uid == _soloUid,
        ),
        hasLength(1),
      );
    });

    test('详情对话框接线：纯字幕书详情给两项入口，复用同一套拉取 / 导入', () {
      final String books = File(
        'lib/src/pages/implementations/reader_history/books.part.dart',
      ).readAsStringSync();
      final String remote = File(
        'lib/src/pages/implementations/reader_history/remote.part.dart',
      ).readAsStringSync();
      expect(
        books,
        contains('_remoteSrtRefetchFor(book.uid) != null'),
        reason: '纯字幕书详情（_srtExtraActions）没按对端候选给入口',
      );
      expect(books, contains('bookKey.isEmpty &&'));
      expect(
        books,
        contains('_refetchRemoteSrtAudiobook(remote, subtitlesOnly: true)'),
      );
      expect(
        books,
        contains('_refetchRemoteSrtAudiobook(remote, subtitlesOnly: false)'),
      );
      expect(remote, contains('remoteStandaloneSrtRefetchCandidates('));
      // 只更新字幕走 /subtitles + importAudioSubtitlePackage；重新下载走整包 fresh，
      // 与首次下载共用同一个任务本体。
      expect(remote, contains('client.getRemoteAudiobookSubtitles('));
      expect(remote, contains('onProgress: onProgress, fresh: true'));
      expect(
        RegExp(r'_runRemoteSrtAudiobookDownload\(').allMatches(remote).length,
        greaterThanOrEqualTo(3),
        reason: '首次下载与重新下载必须共用 _runRemoteSrtAudiobookDownload',
      );
    });

    test('详情入口候选：只给本端已有同 uid 的 standalone；占位卡已挂出的不重复给', () {
      const RemoteAudiobookInfo solo = RemoteAudiobookInfo(
        bookKey: '',
        uid: _soloUid,
        title: 'ソロ',
      );
      const RemoteAudiobookInfo other = RemoteAudiobookInfo(
        bookKey: '',
        uid: 'srt-other',
        title: 'other',
      );
      const RemoteAudiobookInfo paired = RemoteAudiobookInfo(
        bookKey: _bookKey,
        uid: _srtUid,
        title: 'neko',
      );
      final Map<String, RemoteAudiobookInfo> got =
          remoteStandaloneSrtRefetchCandidates(
            remote: <RemoteAudiobookInfo>[solo, other, paired, solo],
            localSrtUids: <String>{_soloUid, _srtUid},
          );
      expect(got.keys, <String>[_soloUid]);
      expect(
        remoteStandaloneSrtRefetchCandidates(
          remote: <RemoteAudiobookInfo>[solo],
          localSrtUids: <String>{_soloUid},
          excludeUids: <String>{_soloUid},
        ),
        isEmpty,
        reason: '本地音频断链时对端占位卡已重新挂出（BUG-2551），整本重下走那边',
      );
    });
  });

  test('书卡菜单候选：本端书 + 有声书都在、对端也有 → 重拉候选；与补拉候选互斥', () {
    const RemoteBookInfo withAudio = RemoteBookInfo(
      title: 'neko',
      hasContent: true,
      hasAudiobook: true,
    );
    const RemoteBookInfo noAudio = RemoteBookInfo(
      title: 'inu',
      hasContent: true,
    );
    String keyOf(String title) => 'k-$title';

    final Map<String, RemoteBookInfo> refetch =
        remoteAudiobookRefetchCandidates(
          remote: <RemoteBookInfo>[withAudio, noAudio],
          localBookKeys: <String>{'k-neko', 'k-inu'},
          localAudiobookKeys: <String>{'k-neko', 'k-inu'},
          keyOf: keyOf,
        );
    expect(refetch.keys, <String>['k-neko']);

    final Map<String, RemoteBookInfo> only = remoteAudiobookOnlyCandidates(
      remote: <RemoteBookInfo>[withAudio],
      localBookKeys: <String>{'k-neko'},
      localAudiobookKeys: <String>{'k-neko'},
      keyOf: keyOf,
    );
    expect(only, isEmpty);
    // 本端没有有声书 → 只进补拉候选，不进重拉候选。
    expect(
      remoteAudiobookRefetchCandidates(
        remote: <RemoteBookInfo>[withAudio],
        localBookKeys: <String>{'k-neko'},
        localAudiobookKeys: <String>{},
        keyOf: keyOf,
      ),
      isEmpty,
    );
  });
}
