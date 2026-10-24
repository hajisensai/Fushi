import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_coverage.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_coverage_index.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiTermToken;
import 'package:fushi_music/fushi_music.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 曲库难度排序的覆盖率索引（设计 §12，schema v134）：批量分词次数、两段失效、中断、
/// 分词失败不落库、孤儿清理、排序分档。词典 / 复习库 / 歌词解析都用确定性替身，表是真的
/// （内存 Drift）。
MusicTracksCompanion _track(String uid, {int mtime = 1}) =>
    MusicTracksCompanion.insert(
      trackUid: uid,
      path: '/m/$uid.flac',
      title: 'Song $uid',
      fileMtimeAt: mtime,
      fileSize: 1,
      addedAt: 1,
    );

LyricTimeline _lyrics(List<String> lines) => LyricTimeline(
  format: 'lrc',
  lines: <LyricLine>[
    for (int i = 0; i < lines.length; i++)
      LyricLine(
        startMs: i * 1000,
        endMs: i * 1000 + 900,
        syllables: <LyricSyllable>[
          LyricSyllable(
            text: lines[i],
            startMs: i * 1000,
            endMs: i * 1000 + 900,
          ),
        ],
      ),
  ],
);

/// 替身分词：按空格切；大写开头的「词」视为词典未命中，其余命中、词头 = 原词。
List<FushiTermToken> _tokenizeLine(String s) {
  final List<FushiTermToken> out = <FushiTermToken>[];
  final RegExp part = RegExp(r'\s+|[^\s]+');
  for (final RegExpMatch m in part.allMatches(s)) {
    final String w = m.group(0)!;
    final bool hit = w.trim().isNotEmpty && w[0].toLowerCase() == w[0];
    out.add((
      length: w.length,
      reading: hit ? 'r$w' : '',
      expression: hit ? w : '',
    ));
  }
  return out;
}

SrsKnownTermSnapshot _known(Set<String> reviewTerms) =>
    SrsKnownTermSnapshot.fromRows(
      <({String termKey, String readingKey, SrsQueue queue, bool suspended})>[
        for (final String term in reviewTerms)
          (
            termKey: srsTermKey(term),
            readingKey: '',
            queue: SrsQueue.review,
            suspended: false,
          ),
      ],
    );

void main() {
  late FushiDatabase db;
  late Map<String, LyricTimeline?> lyrics;
  late List<int> tokenizeCalls;
  late String? dictStamp;
  late SrsKnownTermSnapshot? known;
  late bool tokenizerFails;
  late Completer<void>? holdTokenize;

  MusicLyricsCoverageIndex index({int batch = 2}) => MusicLyricsCoverageIndex(
    database: () => db,
    resolveLocal: (MusicLyricsTrackRef t) async => lyrics[t.trackUid],
    tokenize: (List<String> texts) async {
      tokenizeCalls.add(texts.length);
      final Completer<void>? hold = holdTokenize;
      if (hold != null) await hold.future;
      if (tokenizerFails) return null;
      return <List<FushiTermToken>>[
        for (final String s in texts) _tokenizeLine(s),
      ];
    },
    dictionaryStamp: () => dictStamp,
    knownSnapshot: () async => known,
    now: () => 42,
    batchTracks: batch,
  );

  Future<void> seed(List<String> uids) => db.writeMusicScanBatch(
    MusicScanBatchWrite(
      tracks: <MusicTracksCompanion>[for (final String u in uids) _track(u)],
      albums: const <MusicAlbumsCompanion>[],
      artists: const <MusicArtistsCompanion>[],
      credits: const <MusicTrackCreditsCompanion>[],
    ),
  );

  Future<Map<String, MusicLyricCoverageRow>> rows() async =>
      <String, MusicLyricCoverageRow>{
        for (final MusicLyricCoverageRow r
            in await db.select(db.musicLyricCoverage).get())
          r.trackUid: r,
      };

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    lyrics = <String, LyricTimeline?>{
      'a': _lyrics(<String>['yoru ni kakeru', 'yoru']),
      'b': _lyrics(<String>['Hello World']),
      'c': null,
    };
    tokenizeCalls = <int>[];
    dictStamp = 'dict-1';
    known = _known(<String>{'yoru'});
    tokenizerFails = false;
    holdTokenize = null;
  });
  tearDown(() => db.close());

  test('一批一次分词；ok / 无词典词 / 无歌词；已知按出现次数', () async {
    await seed(<String>['a', 'b', 'c']);
    final MusicCoverageRunResult r = await index().run();
    expect(r.outcome, MusicCoverageRunOutcome.completed);
    expect(r.knownAvailable, isTrue);
    // 3 首、每批 2 首：第一批 a + b 的 3 行一次 FFI；第二批只有无歌词的 c → 没有文本，
    // 不调分词。
    expect(tokenizeCalls, <int>[3]);
    final Map<String, MusicLyricCoverageRow> got = await rows();
    expect(got['a']!.status, 'ok');
    expect(got['a']!.totalTokens, 4); // yoru ×2、ni、kakeru
    expect(got['a']!.uniqueTerms, 3);
    expect(got['a']!.knownTokens, 2);
    expect(decodeMusicCoverageTerms(got['a']!.termsJson), <MusicCoverageTerm>[
      (expression: 'yoru', reading: 'ryoru', count: 2),
      (expression: 'ni', reading: 'rni', count: 1),
      (expression: 'kakeru', reading: 'rkakeru', count: 1),
    ]);
    expect(got['b']!.status, 'no_terms');
    expect(got['c']!.status, 'no_lyrics');
    expect(MusicTrackDifficulty.fromRow(got['a']).percent, 50);
  });

  test('输入没变不重分词；换词典整库重分词；曲目 mtime / 歌词行变只重分那一首', () async {
    await seed(<String>['a', 'b', 'c']);
    final MusicLyricsCoverageIndex idx = index(batch: 8);
    await idx.run();
    expect(tokenizeCalls, <int>[3]);

    await idx.run();
    expect(tokenizeCalls, <int>[3], reason: '指纹都没变');

    // 歌词页解析时 sidecar 行的 updatedAt 被刷新而内容不变：不算变化。
    await db
        .into(db.musicLyrics)
        .insert(
          MusicLyricsCompanion.insert(
            trackUid: 'a',
            source: 'sidecar',
            format: 'lrc',
            raw: Uint8List.fromList(utf8.encode('[00:00.00]yoru')),
            updatedAt: 1,
          ),
        );
    await idx.run();
    expect(tokenizeCalls, <int>[3, 2], reason: '新增歌词行 = a 的输入变了');
    await (db.update(db.musicLyrics)
          ..where(($MusicLyricsTable l) => l.trackUid.equals('a')))
        .write(const MusicLyricsCompanion(updatedAt: Value<int>(999)));
    await idx.run();
    expect(tokenizeCalls, <int>[3, 2], reason: '只刷新 updatedAt 不重算');

    await (db.update(db.musicTracks)
          ..where(($MusicTracksTable t) => t.trackUid.equals('b')))
        .write(const MusicTracksCompanion(fileMtimeAt: Value<int>(7)));
    await idx.run();
    expect(tokenizeCalls, <int>[3, 2, 1], reason: 'b 文件变了（内嵌歌词可能变）');

    dictStamp = 'dict-2';
    await idx.run();
    expect(tokenizeCalls, <int>[3, 2, 1, 3], reason: '换词典 = 全部重分词');

    await idx.run(force: true);
    expect(tokenizeCalls.length, 5, reason: 'force 重读全部');
  });

  test('复习库变了只重判已知段，不重新分词', () async {
    await seed(<String>['a']);
    final MusicLyricsCoverageIndex idx = index();
    await idx.run();
    expect((await rows())['a']!.knownTokens, 2);
    final String? stamp1 = (await rows())['a']!.knownStamp;

    known = _known(<String>{'yoru', 'kakeru'});
    await idx.run();
    expect(tokenizeCalls, <int>[2]);
    expect((await rows())['a']!.knownTokens, 3);
    expect((await rows())['a']!.knownStamp, isNot(stamp1));

    // 复习模块关掉：已知段不动，结论报不可用。
    known = null;
    final MusicCoverageRunResult r = await idx.run();
    expect(r.knownAvailable, isFalse);
  });

  test('没装词典：不分词、报 noDictionary', () async {
    await seed(<String>['a']);
    dictStamp = null;
    final MusicCoverageRunResult r = await index().run();
    expect(r.outcome, MusicCoverageRunOutcome.noDictionary);
    expect(tokenizeCalls, isEmpty);
    expect(await rows(), isEmpty);
  });

  test('分词失败（词典重载中）：这批不落库、不记成无词', () async {
    await seed(<String>['a', 'b']);
    tokenizerFails = true;
    final MusicCoverageRunResult r = await index().run();
    expect(r.outcome, MusicCoverageRunOutcome.cancelled);
    expect(await rows(), isEmpty);
  });

  test('中断：已落库的批次保留，其余下次接着算；进度可见', () async {
    await seed(<String>['a', 'b', 'c', 'd']);
    lyrics['d'] = _lyrics(<String>['kakeru']);
    lyrics['c'] = _lyrics(<String>['ni']);
    final MusicLyricsCoverageIndex idx = index();
    holdTokenize = Completer<void>();
    final Future<MusicCoverageRunResult> running = idx.run();
    // 同一时刻只跑一次。
    expect(identical(idx.run(), running), isTrue);
    await pumpEventQueue();
    expect(idx.progress.value.running, isTrue);
    expect(idx.progress.value.total, 4);
    idx.cancel();
    holdTokenize!.complete();
    holdTokenize = null;
    final MusicCoverageRunResult r = await running;
    expect(r.outcome, MusicCoverageRunOutcome.cancelled);
    expect((await rows()).keys.toSet(), <String>{'a', 'b'});
    expect(idx.progress.value.running, isFalse);

    await idx.run();
    expect((await rows()).keys.toSet(), <String>{'a', 'b', 'c', 'd'});
  });

  test('曲目离开曲库：孤儿行清掉', () async {
    await seed(<String>['a', 'b']);
    final MusicLyricsCoverageIndex idx = index();
    await idx.run();
    await (db.delete(
      db.musicTracks,
    )..where(($MusicTracksTable t) => t.trackUid.equals('b'))).go();
    await idx.run();
    expect((await rows()).keys.toSet(), <String>{'a'});
  });

  group('排序', () {
    MusicTrackRow row(String uid) => MusicTrackRow(
      trackUid: uid,
      path: '/m/$uid',
      title: uid,
      isLossless: false,
      fileMtimeAt: 1,
      fileSize: 1,
      hasEmbeddedCover: false,
      addedAt: 1,
    );

    MusicTrackDifficulty d(String status, {int? known, int total = 0}) =>
        MusicTrackDifficulty.fromRow(
          MusicLyricCoverageRow(
            trackUid: 'x',
            status: status,
            inputStamp: '',
            termsJson: '[]',
            totalTokens: total,
            uniqueTerms: 0,
            knownTokens: known,
            computedAt: 0,
          ),
        );

    final List<MusicTrackRow> tracks = <MusicTrackRow>[
      for (final String u in <String>[
        'nolyr',
        'easy',
        'pending',
        'hard',
        'noterm',
        'mid',
      ])
        row(u),
    ];
    final Map<String, MusicTrackDifficulty> diff =
        <String, MusicTrackDifficulty>{
          'nolyr': d('no_lyrics'),
          'easy': d('ok', known: 9, total: 10),
          'hard': d('ok', known: 1, total: 10),
          'noterm': d('no_terms'),
          'mid': d('ok', known: 5, total: 10),
        };

    List<String> order(MusicTrackSort s) => <String>[
      for (final MusicTrackRow t in sortMusicTracksByDifficulty(
        tracks,
        diff,
        s,
      ))
        t.trackUid,
    ];

    test('由易到难 / 由难到易；没算的、无词典词、无歌词依次排在最后', () {
      expect(order(MusicTrackSort.easiestFirst), <String>[
        'easy',
        'mid',
        'hard',
        'pending',
        'noterm',
        'nolyr',
      ]);
      expect(order(MusicTrackSort.hardestFirst), <String>[
        'hard',
        'mid',
        'easy',
        'pending',
        'noterm',
        'nolyr',
      ]);
      expect(order(MusicTrackSort.library), <String>[
        'nolyr',
        'easy',
        'pending',
        'hard',
        'noterm',
        'mid',
      ]);
    });

    test('偏好值往返；未知值回落曲库顺序', () {
      for (final MusicTrackSort s in MusicTrackSort.values) {
        expect(MusicTrackSort.parse(s.prefValue), s);
      }
      expect(MusicTrackSort.parse('bogus'), MusicTrackSort.library);
    });
  });
}
