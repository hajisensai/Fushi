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
