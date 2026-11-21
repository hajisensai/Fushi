import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v160：`audio_cues.token_timing_json`——转录产物的逐 token 时间随 cue 落库。
///
/// 此前 `AudioCue.tokenTiming` 是导入时的瞬态字段：重切用完即丢，库里读回的 cue 恒为
/// null，运行时要按 token 裁半句的功能（漫画台词匹配有声书 cue）因此一句都裁不了。
/// 磁盘上的 sidecar 按原始转录行号排，与重切后的库内 cue 对不上，补挂不回来。
void main() {
  AudioCue cue(int i, {CueTokenTiming? timing}) => AudioCue()
    ..bookKey = 'book'
    ..chapterHref = 'ch1.xhtml'
    ..sentenceIndex = i
    ..textFragmentId = '#s$i'
    ..text = 'text$i'
    ..startMs = i * 1000
    ..endMs = i * 1000 + 900
    ..audioFileIndex = 0
    ..tokenTiming = timing;

  test('v159 → v160 加 token_timing_json；存量 cue 为 NULL，重跑幂等', () async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'cue_timing_v160',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = p.join(dir.path, 'test.db');
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.replaceCuesForBook('book', <AudioCuesCompanion>[
      AudioCue.toCompanion(cue(0)),
    ]);
    await original.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE audio_cues DROP COLUMN token_timing_json');
    raw.execute('PRAGMA user_version = 159');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 168);
    final List<AudioCueRow> rows = await migrated.getCuesForBook('book');
    expect(rows.single.tokenTimingJson, isNull);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 168);
    probe.execute(
      'UPDATE audio_cues SET token_timing_json = \'{"t":["a"],"o":[5]}\'',
    );
    // 重跑 v160 步：列已在，不得报错、不得清数据。
    probe.execute('PRAGMA user_version = 159');
    probe.dispose();
    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(
      (await reopened.getCuesForBook('book')).single.tokenTimingJson,
      '{"t":["a"],"o":[5]}',
    );
    await reopened.close();
  });

  group('AudioCue 落库往返', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('saveCues 写入、cuesForBook 读回逐 token 时间；没有的仍为 null', () async {
      final AudiobookRepository repo = AudiobookRepository(db);
      await repo.saveCues(
        bookKey: 'book',
        cues: <AudioCue>[
          cue(
            0,
            timing: CueTokenTiming(
              tokens: <String>['僕', 'は', '、'],
              offsetsMs: <int>[-40, 120, 300],
            ),
          ),
          cue(1),
          cue(
            2,
            timing: CueTokenTiming(tokens: <String>[], offsetsMs: <int>[]),
          ),
        ],
      );
      final List<AudioCue> back = await repo.cuesForBook('book');
      expect(back, hasLength(3));
      expect(back[0].tokenTiming!.tokens, <String>['僕', 'は', '、']);
      expect(back[0].tokenTiming!.offsetsMs, <int>[-40, 120, 300]);
      expect(back[1].tokenTiming, isNull);
      expect(back[2].tokenTiming, isNull, reason: '空 token 列表不落库');
    });

    test('手改过的 cue 存字幕源原 cue 的时间（与 cueText 存原文同口径）', () async {
      final AudioCue source = cue(
        0,
        timing: CueTokenTiming(tokens: <String>['あ'], offsetsMs: <int>[10]),
      );
      final AudioCue edited = cue(0)
        ..text = '改'
        ..uneditedCue = source;
      final AudioCuesCompanion row = AudioCue.toCompanion(edited);
      expect(row.cueText.value, 'text0');
      expect(row.tokenTimingJson.value, '{"t":["あ"],"o":[10]}');
    });

    test('坏数据读回为 null，不挡住整本书', () {
      for (final String bad in <String>[
        '',
        'not json',
        '[1,2]',
        '{"t":["a","b"],"o":[1]}',
        '{"t":[1],"o":[1]}',
        '{"t":["a"],"o":["1"]}',
      ]) {
        expect(CueTokenTiming.tryParseJson(bad), isNull, reason: bad);
      }
      final CueTokenTiming ok = CueTokenTiming.tryParseJson(
        '{"t":["a","b"],"o":[0,50]}',
      )!;
      expect(ok.tokens, <String>['a', 'b']);
      expect(ok.offsetsMs, <int>[0, 50]);
    });
  });

  test('有声书同步包带上逐 token 时间，对端落库后能读回', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'fushi-cue-timing-pkg-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final FushiDatabase sourceDb = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    final FushiDatabase targetDb = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(sourceDb.close);
    addTearDown(targetDb.close);

    final Directory audio = Directory(p.join(temp.path, 'source-audio'));
    await audio.create(recursive: true);
    final File track = File(p.join(audio.path, 'track01.m4b'))
      ..writeAsStringSync('audio bytes');
    final File alignment = File(p.join(audio.path, 'align.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n');
    await sourceDb.upsertAudiobook(
      AudiobooksCompanion.insert(
        bookKey: 'book',
        audioRoot: Value(audio.path),
        audioPathsJson: Value(jsonEncode(<String>[track.path])),
        alignmentFormat: 'srt',
        alignmentPath: alignment.path,
      ),
    );
    await sourceDb.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: 'srt-book',
        title: 'Book',
        audioRoot: Value(audio.path),
        audioPathsJson: Value(jsonEncode(<String>[track.path])),
        srtPath: alignment.path,
        importedAt: 1,
        bookKey: const Value('book'),
      ),
    );
    await sourceDb.replaceCuesForBook('book', <AudioCuesCompanion>[
      AudioCue.toCompanion(
        cue(
          0,
          timing: CueTokenTiming(
            tokens: <String>['は', 'い'],
            offsetsMs: <int>[0, 80],
          ),
        ),
      ),
      AudioCue.toCompanion(cue(1)),
    ]);

    final File package = await SyncAssetPackageService(db: sourceDb)
        .exportAudioDatabasePackage(
          bookKey: 'book',
          srtBookUid: 'srt-book',
          outputFile: File(p.join(temp.path, 'audio.zip')),
        );
    await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
      packageFile: package,
      audioDatabaseRoot: Directory(p.join(temp.path, 'target-audio')),
    );

    final List<AudioCue> back = (await targetDb.getCuesForBook(
      'book',
    )).map(AudioCue.fromRow).toList();
    expect(back, hasLength(2));
    expect(back[0].tokenTiming!.tokens, <String>['は', 'い']);
    expect(back[0].tokenTiming!.offsetsMs, <int>[0, 80]);
    expect(back[1].tokenTiming, isNull);
  });
}
