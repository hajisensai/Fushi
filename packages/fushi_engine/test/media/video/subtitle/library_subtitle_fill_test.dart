import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/library_subtitle_fill.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('judgeSubtitleCoverage', () {
    SubtitleCoverage judge({
      String? source,
      bool exists = false,
      String? fileLanguage,
      List<String> covering = const <String>[],
      List<SubtitleFillTrack> tracks = const <SubtitleFillTrack>[],
    }) => judgeSubtitleCoverage(
      wanted: 'ja',
      subtitleSource: source,
      registeredFileExists: exists,
      registeredFileLanguage: fileLanguage,
      coveringFiles: covering,
      tracks: tracks,
    );

    const SubtitleFillTrack engAss = SubtitleFillTrack(
      subtitleIndex: 0,
      codec: 'ass',
      language: 'eng',
    );
    const SubtitleFillTrack jpnAss = SubtitleFillTrack(
      subtitleIndex: 1,
      codec: 'ass',
      language: 'jpn',
    );
    const SubtitleFillTrack jpnPgs = SubtitleFillTrack(
      subtitleIndex: 2,
      codec: 'hdmv_pgs_subtitle',
      language: 'jpn',
    );

    test('off: 尊重用户关字幕', () {
      expect(judge(source: 'off:').kind, SubtitleCoverageKind.userDisabled);
    });

    test('登记的日语文件还在：已覆盖', () {
      expect(
        judge(source: '/x/a.srt', exists: true, fileLanguage: 'ja').kind,
        SubtitleCoverageKind.covered,
      );
    });

    test('登记的中文文件 / 已不在的文件：不算覆盖', () {
      expect(
        judge(source: '/x/a.srt', exists: true, fileLanguage: 'zh').kind,
        SubtitleCoverageKind.missing,
      );
      expect(
        judge(source: '/x/a.srt', fileLanguage: 'ja').kind,
        SubtitleCoverageKind.missing,
      );
    });

    test('选中的内封轨是英语、另有日语文本轨：选日语那条', () {
      final SubtitleCoverage c = judge(
        source: 'embedded:0',
        tracks: <SubtitleFillTrack>[engAss, jpnAss, jpnPgs],
      );
      expect(c.kind, SubtitleCoverageKind.embeddedText);
      expect(c.trackIndex, 1);
    });

    test('选中的就是日语内封轨：已覆盖', () {
      expect(
        judge(source: 'embedded:1', tracks: <SubtitleFillTrack>[jpnAss]).kind,
        SubtitleCoverageKind.covered,
      );
    });

    test('只有日语 PGS：要 OCR', () {
      final SubtitleCoverage c = judge(
        tracks: <SubtitleFillTrack>[engAss, jpnPgs],
      );
      expect(c.kind, SubtitleCoverageKind.embeddedGraphic);
      expect(c.trackIndex, 2);
    });

    test('有目标语言 sidecar：已覆盖', () {
      expect(
        judge(covering: <String>['a.ja.srt']).kind,
        SubtitleCoverageKind.covered,
      );
    });

    test('什么都没有：缺', () {
      expect(
        judge(tracks: <SubtitleFillTrack>[engAss]).kind,
        SubtitleCoverageKind.missing,
      );
    });
  });

  test('subtitleFillMayTakeSelection', () {
    expect(
      subtitleFillMayTakeSelection(
        subtitleSource: null,
        registeredFileExists: false,
      ),
      isTrue,
    );
    expect(
      subtitleFillMayTakeSelection(
        subtitleSource: 'embedded:0',
        registeredFileExists: false,
      ),
      isTrue,
    );
    expect(
      subtitleFillMayTakeSelection(
        subtitleSource: '/x/zh.srt',
        registeredFileExists: true,
      ),
      isFalse,
    );
    expect(
      subtitleFillMayTakeSelection(
        subtitleSource: '/x/gone.srt',
        registeredFileExists: false,
      ),
      isTrue,
    );
    expect(
      subtitleFillMayTakeSelection(
        subtitleSource: 'off:',
        registeredFileExists: false,
      ),
      isFalse,
    );
  });

  group('LibrarySubtitleFill.run', () {
    late Directory root;
    late FushiDatabase db;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fushi-subtitle-fill-');
      enginePaths = FixedEnginePaths(
        documents: root,
        support: root,
        temp: root,
      );
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
      enginePaths = const UninstalledEnginePaths();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<SubtitleFillItem> fileItem(String uid, {String? source}) async {
      final File video = File(p.join(root.path, 'lib', '$uid.mkv'));
      await video.parent.create(recursive: true);
      await video.writeAsBytes(<int>[0, 1, 2], flush: true);
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: uid,
          videoPath: video.path,
        ),
      );
      if (source != null) await db.updateVideoBookSubtitleSource(uid, source);
      return (await librarySubtitleFillItems(
        db,
        bookUids: <String>[uid],
      )).single;
    }

    Future<SubtitleFillItem> discItem(String uid) async {
      final Directory playlist = Directory(
        p.join(root.path, 'disc', 'BDMV', 'PLAYLIST'),
      );
      await playlist.create(recursive: true);
      await File(
        p.join(playlist.path, '00001.mpls'),
      ).writeAsBytes(<int>[1], flush: true);
      final String path = p.join(playlist.path, '00001.p01.mpls');
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(bookUid: uid, title: uid, videoPath: path),
      );
      final SubtitleFillItem item = (await librarySubtitleFillItems(
        db,
        bookUids: <String>[uid],
      )).single;
      expect(item.isDisc, isTrue);
      return item;
    }

    LibrarySubtitleFill fill(
      _FakeHost host, {
      VideoSubtitleBackfillService? backfill,
      Map<String, VideoProbeFacts> facts = const <String, VideoProbeFacts>{},
    }) => LibrarySubtitleFill(
      database: db,
      host: host,
      backfill: backfill,
      probe: (String path) async =>
          facts[p.basename(path)] ?? VideoProbeFacts.empty,
    );

    test('内封日语文本轨：登记 embedded:<n>，不下载不生成', () async {
      final SubtitleFillItem item = await fileItem('a');
      final _FakeHost host = _FakeHost(root);
      final List<SubtitleFillOutcome> out =
          await fill(
            host,
            facts: <String, VideoProbeFacts>{
              'a.mkv': const VideoProbeFacts(
                subtitleTracks: <SubtitleTrackFacts>[
                  SubtitleTrackFacts(index: 2, codec: 'ass', language: 'eng'),
                  SubtitleTrackFacts(index: 3, codec: 'ass', language: 'jpn'),
                ],
              ),
            },
          ).run(<SubtitleFillItem>[
            item,
          ], const LibrarySubtitleFillOptions(language: 'ja'));
      expect(out.single.action, SubtitleFillAction.selectedEmbedded);
      expect(
        (await db.getVideoBookByBookUid('a'))!.subtitleSource,
        'embedded:1',
      );
      expect(host.calls, isEmpty);
    });

    test('只有日语 PGS：OCR；OCR 不可用时退到生成', () async {
      final SubtitleFillItem item = await fileItem('b');
      const VideoProbeFacts pgs = VideoProbeFacts(
        durationMs: 24 * 60 * 1000,
        subtitleTracks: <SubtitleTrackFacts>[
          SubtitleTrackFacts(
            index: 2,
            codec: 'hdmv_pgs_subtitle',
            language: 'jpn',
          ),
        ],
      );
      final _FakeHost ok = _FakeHost(root);
      final List<SubtitleFillOutcome> first =
          await fill(ok, facts: <String, VideoProbeFacts>{'b.mkv': pgs}).run(
            <SubtitleFillItem>[item],
            const LibrarySubtitleFillOptions(language: 'ja'),
          );
      expect(first.single.action, SubtitleFillAction.ocr);
      expect(ok.calls, <String>['ocr:b:0']);

      await db.updateVideoBookSubtitleSource('b', null);
      await File(first.single.path!).delete();
      final _FakeHost broken = _FakeHost(root, ocrFails: true);
      final List<SubtitleFillOutcome> second =
          await fill(
            broken,
            facts: <String, VideoProbeFacts>{'b.mkv': pgs},
          ).run(<SubtitleFillItem>[
            item,
          ], const LibrarySubtitleFillOptions(language: 'ja'));
      expect(second.single.action, SubtitleFillAction.generated);
      expect(broken.calls, <String>['ocr:b:0', 'generate:b']);
      expect(second.single.notes.first, startsWith('ocr:'));
    });

    test('已有日语 sidecar：不动；只有中文的：补', () async {
      final SubtitleFillItem ja = await fileItem('c');
      await File(
        p.join(root.path, 'lib', 'c.ja.srt'),
      ).writeAsString(_srt('こんにちは'));
      final SubtitleFillItem zh = await fileItem('d');
      await File(
        p.join(root.path, 'lib', 'd.zh.srt'),
      ).writeAsString(_srt('你好'));
      final _FakeHost host = _FakeHost(root);
      final List<SubtitleFillOutcome> out = await fill(host).run(
        <SubtitleFillItem>[ja, zh],
        const LibrarySubtitleFillOptions(language: 'ja'),
      );
      expect(out[0].action, SubtitleFillAction.alreadyCovered);
      expect(out[1].action, SubtitleFillAction.generated);
    });

    test('用户选着一份还在的中文文件：补，但不顶替选择', () async {
      final File zhFile = File(p.join(root.path, 'mine.zh.srt'))
        ..createSync(recursive: true)
        ..writeAsStringSync(_srt('你好'));
      final SubtitleFillItem item = await fileItem('e', source: zhFile.path);
      final List<SubtitleFillOutcome> out = await fill(_FakeHost(root)).run(
        <SubtitleFillItem>[item],
        const LibrarySubtitleFillOptions(language: 'ja'),
      );
      expect(out.single.action, SubtitleFillAction.generated);
      expect(out.single.selectionChanged, isFalse);
      expect(
        (await db.getVideoBookByBookUid('e'))!.subtitleSource,
        zhFile.path,
      );
    });

    test('dry-run 只判不做', () async {
      final SubtitleFillItem item = await fileItem('f');
      final _FakeHost host = _FakeHost(root);
      final List<SubtitleFillOutcome> out = await fill(host).run(
        <SubtitleFillItem>[item],
        const LibrarySubtitleFillOptions(language: 'ja', dryRun: true),
      );
      expect(out.single.action, SubtitleFillAction.planned);
      expect(out.single.plan, SubtitleCoverageKind.missing);
      expect(host.calls, isEmpty);
    });

    test('太短的条目（特典）不生成', () async {
      final SubtitleFillItem item = await fileItem('g');
      final _FakeHost host = _FakeHost(root);
      final List<SubtitleFillOutcome> out =
          await fill(
            host,
            facts: <String, VideoProbeFacts>{
              'g.mkv': const VideoProbeFacts(durationMs: 90 * 1000),
            },
          ).run(<SubtitleFillItem>[
            item,
          ], const LibrarySubtitleFillOptions(language: 'ja'));
      expect(out.single.action, SubtitleFillAction.skipped);
      expect(host.calls, isEmpty);
    });

    test('原盘没刮削身份：下载这档记原因，直接生成', () async {
      final SubtitleFillItem item = await discItem('disc1');
      final _FakeHost host = _FakeHost(root, retimeMatch: 85);
      final List<SubtitleFillOutcome> out =
          await fill(host, backfill: _backfill()).run(<SubtitleFillItem>[
            item,
          ], const LibrarySubtitleFillOptions(language: 'ja'));
      expect(out.single.action, SubtitleFillAction.generated);
      expect(out.single.notes.first, contains('not been scraped'));
    });

    test('取消：后面的集记 cancelled', () async {
      final SubtitleFillItem a = await fileItem('h1');
      final SubtitleFillItem b = await fileItem('h2');
      final SubtitleCancelSource cancel = SubtitleCancelSource();
      final _FakeHost host = _FakeHost(root, onGenerate: cancel.cancel);
      final List<SubtitleFillOutcome> out = await fill(host).run(
        <SubtitleFillItem>[a, b],
        const LibrarySubtitleFillOptions(language: 'ja'),
        cancel: cancel,
      );
      expect(out[1].action, SubtitleFillAction.cancelled);
    });

    test('撤销：删产物、还原选择', () async {
      final SubtitleFillItem item = await fileItem('u');
      final List<SubtitleFillOutcome> out = await fill(_FakeHost(root)).run(
        <SubtitleFillItem>[item],
        const LibrarySubtitleFillOptions(language: 'ja'),
      );
      final String produced = out.single.path!;
      expect(File(produced).existsSync(), isTrue);
      expect((await db.getVideoBookByBookUid('u'))!.subtitleSource, produced);
      expect(await undoLibrarySubtitleFill(db, out), 1);
      expect(File(produced).existsSync(), isFalse);
      expect((await db.getVideoBookByBookUid('u'))!.subtitleSource, isNull);
    });

    test('选集：分集取代的整卷、BDMV/STREAM 散 m2ts 不进', () async {
      final Directory pl = Directory(
        p.join(root.path, 'd2', 'BDMV', 'PLAYLIST'),
      )..createSync(recursive: true);
      File(p.join(pl.path, '00001.mpls')).writeAsBytesSync(<int>[1]);
      for (final (String uid, String path) in <(String, String)>[
        ('whole', p.join(pl.path, '00001.mpls')),
        ('ep1', p.join(pl.path, '00001.p01.mpls')),
        ('bonus', p.join(pl.path, '00002.mpls')),
        ('m2ts', p.join(root.path, 'd2', 'BDMV', 'STREAM', '00000.m2ts')),
      ]) {
        await db.upsertVideoBook(
          VideoBooksCompanion.insert(bookUid: uid, title: uid, videoPath: path),
        );
      }
      final List<String> uids = <String>[
        for (final SubtitleFillItem i in await librarySubtitleFillItems(db))
          i.bookUid,
      ];
      expect(uids, unorderedEquals(<String>['ep1', 'bonus']));
    });
  });

  group('原盘下载后的版本适配', () {
    late Directory root;
    late FushiDatabase db;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fushi-subtitle-fill-bd-');
      enginePaths = FixedEnginePaths(
        documents: root,
        support: root,
        temp: root,
      );
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
      enginePaths = const UninstalledEnginePaths();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<SubtitleFillItem> scrapedDisc() async {
      final Directory pl = Directory(
        p.join(root.path, 'Show', 'BDMV', 'PLAYLIST'),
      )..createSync(recursive: true);
      File(p.join(pl.path, '00001.mpls')).writeAsBytesSync(<int>[1]);
      final String path = p.join(pl.path, '00001.p02.mpls');
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'ep2',
          title: 'ep2',
          videoPath: path,
        ),
      );
      await _scrapeAsEpisode(db, 'ep2', season: 1, episode: 2);
      return (await librarySubtitleFillItems(
        db,
        bookUids: <String>['ep2'],
      )).single;
    }

    test('命中率高：用重定时版，删下载原件', () async {
      final SubtitleFillItem item = await scrapedDisc();
      final _RecordingProvider provider = _RecordingProvider();
      final _FakeHost host = _FakeHost(root, retimeMatch: 85);
      final List<SubtitleFillOutcome> out =
          await LibrarySubtitleFill(
            database: db,
            host: host,
            backfill: VideoSubtitleBackfillService(
              registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[
                provider,
              ]),
            ),
            probe: (String _) async => VideoProbeFacts.empty,
          ).run(<SubtitleFillItem>[
            item,
          ], const LibrarySubtitleFillOptions(language: 'ja'));
      expect(provider.lastRequest!.effectiveEpisode, 2);
      expect(out.single.action, SubtitleFillAction.downloadedRetimed);
      expect(out.single.matchPercent, 85);
      expect(host.calls, <String>['generate:ep2', 'retime:ep2']);
      expect(
        (await db.getVideoBookByBookUid('ep2'))!.subtitleSource,
        out.single.path,
      );
      expect(
        File(
          p.join(root.path, 'video_subtitles', 'disc-ep2.ja.srt'),
        ).existsSync(),
        isFalse,
      );
    });

    test('命中率低：判不是这个版本，改用 ASR 稿', () async {
      final SubtitleFillItem item = await scrapedDisc();
      final _FakeHost host = _FakeHost(root, retimeMatch: 12);
      final List<SubtitleFillOutcome> out =
          await LibrarySubtitleFill(
            database: db,
            host: host,
            backfill: VideoSubtitleBackfillService(
              registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[
                _RecordingProvider(),
              ]),
            ),
            probe: (String _) async => VideoProbeFacts.empty,
          ).run(<SubtitleFillItem>[
            item,
          ], const LibrarySubtitleFillOptions(language: 'ja'));
      expect(out.single.action, SubtitleFillAction.generated);
      expect(out.single.notes.last, contains('12%'));
    });
  });
}

VideoSubtitleBackfillService _backfill() => VideoSubtitleBackfillService(
  registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[
    _RecordingProvider(),
  ]),
);

/// 把 [bookUid] 刮成一部 anilist 剧集的第 [season] 季第 [episode] 集（作品挂在这一集上）。
Future<void> _scrapeAsEpisode(
  FushiDatabase db,
  String bookUid, {
  required int season,
  required int episode,
}) async {
  final int workId = await db
      .into(db.videoMetadataWorks)
      .insert(
        VideoMetadataWorksCompanion.insert(
          bookUid: Value<String?>(bookUid),
          mediaType: 'tv',
          title: 'Show',
          updatedAt: 0,
        ),
      );
  await db
      .into(db.videoMetadataProviderIdentities)
      .insert(
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:anilist:100',
          workId: Value<int?>(workId),
          provider: 'anilist',
          externalId: '100',
          isPrimary: const Value<bool>(true),
          updatedAt: 0,
        ),
      );
  final int seasonId = await db
      .into(db.videoMetadataSeasons)
      .insert(
        VideoMetadataSeasonsCompanion.insert(
          workId: workId,
          seasonNumber: season,
          updatedAt: 0,
        ),
      );
  await db
      .into(db.videoMetadataEpisodes)
      .insert(
        VideoMetadataEpisodesCompanion.insert(
          seasonId: seasonId,
          bookUid: Value<String?>(bookUid),
          episodeNumber: episode,
          updatedAt: 0,
        ),
      );
}

String _srt(String line) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < 12; i++) {
    final int s = 10 + i * 4;
    b.write(
      '${i + 1}\n00:00:${s.toString().padLeft(2, '0')},000 --> '
      '00:00:${s.toString().padLeft(2, '0')},900\n$line$i\n\n',
    );
  }
  return b.toString();
}

class _FakeHost implements LibrarySubtitleFillHost {
  _FakeHost(
    this.root, {
    this.ocrFails = false,
    this.retimeMatch = 90,
    this.onGenerate,
  });

  final Directory root;
  final bool ocrFails;
  final int retimeMatch;
  final void Function()? onGenerate;
  final List<String> calls = <String>[];

  Future<String> _write(String name) async {
    final File f = File(p.join(root.path, 'out', name));
    await f.parent.create(recursive: true);
    await f.writeAsString(_srt('こんにちは'));
    return f.path;
  }

  @override
  Future<SubtitleFillProduct> ocrGraphicTrack(
    SubtitleFillItem item,
    int trackIndex,
    String language,
    SubtitleCancelToken cancel,
  ) async {
    calls.add('ocr:${item.bookUid}:$trackIndex');
    if (ocrFails) throw const SubtitleFillStepFailure('ocr model missing');
    return SubtitleFillProduct(
      path: await _write('${item.bookUid}.ocr.ja.srt'),
    );
  }

  @override
  Future<SubtitleFillProduct> generate(
    SubtitleFillItem item,
    String language,
    SubtitleCancelToken cancel,
  ) async {
    calls.add('generate:${item.bookUid}');
    onGenerate?.call();
    return SubtitleFillProduct(path: await _write('${item.bookUid}.ja.srt'));
  }

  @override
  Future<SubtitleFillRetimed> retime(
    SubtitleFillItem item,
    String subtitlePath,
    String referenceSrtPath,
    SubtitleCancelToken cancel,
  ) async {
    calls.add('retime:${item.bookUid}');
    return SubtitleFillRetimed(
      path: await _write('${item.bookUid}.retimed.srt'),
      matchPercent: retimeMatch,
      medianShiftMs: 1200,
    );
  }
}

class _Cand extends VideoSubtitleCandidate {
  _Cand()
    : super(
        providerId: 'one',
        remoteId: '1',
        fileName: 'Show - 02.ja.srt',
        language: 'ja',
        providerPriority: 0,
        episode: 2,
      );
}

class _RecordingProvider implements VideoSubtitleProvider {
  VideoSubtitleSearchRequest? lastRequest;

  @override
  bool get allowsFreeProbeDownload => false;

  @override
  String get id => 'one';

  @override
  int get priority => 0;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    lastRequest = request;
    return ProviderBatchResult<VideoSubtitleCandidate>.success(
      <VideoSubtitleCandidate>[_Cand()],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async => VideoSubtitleDownload(
    bytes: Uint8List.fromList(utf8.encode(_srt('こんにちは'))),
    fileName: candidate.fileName,
    language: 'ja',
  );

  @override
  void close() {}
}
