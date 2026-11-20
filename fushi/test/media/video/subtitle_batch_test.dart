import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_batch.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_language_probe.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_archive.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

/// 来源无关的合集批量编排：判据委托 `chooseSubtitleForEpisode`、下载走 registry、
/// 落盘名带 bookUid 前缀、单集失败不中断整批。
class _Cand extends VideoSubtitleCandidate {
  _Cand(String name, {int? season, int? episode, String language = 'ja'})
    : super(
        providerId: 'fake',
        remoteId: name,
        fileName: name,
        language: language,
        providerPriority: 1,
        season: season,
        episode: episode,
      );
}

/// 整季 ZIP 包候选。
class _Pack extends VideoSubtitleCandidate {
  _Pack(String name, {int? season})
    : super(
        providerId: 'fake',
        remoteId: name,
        fileName: name,
        language: 'ja',
        providerPriority: 1,
        season: season,
        archiveFormat: SubtitleArchiveFormat.zip,
      );
}

/// 整季包来源：[failing] 里的包下载抛错，其余回 [entries] 里登记的包内文件。
class _PackProvider implements VideoSubtitleProvider {
  _PackProvider({
    this.failing = const <String>{},
    this.entries = const <String, List<String>>{},
  });

  final Set<String> failing;
  final Map<String, List<String>> entries;
  final List<String> downloaded = <String>[];

  @override
  String get id => 'fake';
  @override
  int get priority => 1;
  @override
  bool get allowsFreeProbeDownload => true;
  @override
  void close() {}

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async => ProviderBatchResult<VideoSubtitleCandidate>.success(
    const <VideoSubtitleCandidate>[],
  );

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    downloaded.add(candidate.fileName);
    if (failing.contains(candidate.fileName)) {
      throw const ExternalProviderFailure(
        providerId: 'fake',
        operation: 'download',
        kind: ExternalProviderFailureKind.rateLimited,
        message: 'slow down',
        statusCode: 429,
      );
    }
    final Uint8List body = Uint8List.fromList(
      utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nx\n'),
    );
    return VideoSubtitleDownload(
      bytes: body,
      fileName: candidate.fileName,
      language: candidate.language,
      archiveEntries: <ArchivedSubtitle>[
        for (final String name
            in entries[candidate.fileName] ?? const <String>[])
          ArchivedSubtitle(fileName: name, bytes: body),
      ],
    );
  }
}

class _FakeProvider implements VideoSubtitleProvider {
  _FakeProvider({
    this.failNames = const <String>{},
    this.bodies = const <String, String>{},
  });

  final Set<String> failNames;

  /// 文件名 → 正文；未列出的回一段不含可判语言文字的 SRT。
  final Map<String, String> bodies;
  final List<String> downloaded = <String>[];

  @override
  String get id => 'fake';
  @override
  int get priority => 1;
  @override
  bool get allowsFreeProbeDownload => true;
  @override
  void close() {}

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async => ProviderBatchResult<VideoSubtitleCandidate>.success(
    const <VideoSubtitleCandidate>[],
  );

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    downloaded.add(candidate.fileName);
    if (failNames.contains(candidate.fileName)) {
      throw const ExternalProviderFailure(
        providerId: 'fake',
        operation: 'download',
        kind: ExternalProviderFailureKind.unavailable,
        message: 'boom',
      );
    }
    return VideoSubtitleDownload(
      bytes: Uint8List.fromList(
        utf8.encode(
          bodies[candidate.fileName] ?? '1\n00:00:01,000 --> 00:00:02,000\nx\n',
        ),
      ),
      fileName: candidate.fileName,
      language: candidate.language,
    );
  }
}

SubtitleBatchTarget _target(int index, String name) => SubtitleBatchTarget(
  bookUid: 'video/$name',
  title: name,
  videoPath: 'C:/v/$name.mkv',
  sortIndex: index,
  isStream: false,
);

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('subtitle_batch_test');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('按集号配文件：命中的下载落盘（bookUid 前缀），没有的记 noMatch 并说明原因', () async {
    final _FakeProvider provider = _FakeProvider();
    final List<SubtitleBatchItem> started = <SubtitleBatchItem>[];
    final List<SubtitleBatchItem> results = await runSubtitleBatch(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      candidates: <VideoSubtitleCandidate>[
        _Cand('Show - 01.ja.srt', episode: 1),
        _Cand('Show - 01.en.srt', episode: 1, language: 'en'),
      ],
      targets: <SubtitleBatchTarget>[
        _target(0, 'Show - 01'),
        _target(1, 'Show - 02'),
      ],
      saveDirectory: tmp.path,
      onItemStart: (SubtitleBatchItem item) async => started.add(item),
    );
    expect(started, hasLength(2));
    expect(results[0].status, SubtitleBatchStatus.done);
    expect(results[0].language, 'ja');
    expect(
      results[0].subtitlePath,
      endsWith('video_Show_-_01__Show - 01.ja.srt'),
    );
    expect(File(results[0].subtitlePath!).existsSync(), isTrue);
    expect(results[1].status, SubtitleBatchStatus.noMatch);
    expect(
      results[1].message,
      'jimaku entry has subtitles but none for this episode',
    );
    // 首选语言：ja 优先于 en（默认权重）。
    expect(provider.downloaded, <String>['Show - 01.ja.srt']);
  });

  test('对齐钩子：本机路径调用；UNC / smb:// 网络路径不抽内嵌轨、原样落盘', () async {
    final _FakeProvider provider = _FakeProvider();
    final List<String> alignedFor = <String>[];
    SubtitleBatchTarget target(int index, String name, String videoPath) =>
        SubtitleBatchTarget(
          bookUid: 'video/$name',
          title: name,
          videoPath: videoPath,
          sortIndex: index,
          isStream: false,
        );
    final List<SubtitleBatchItem> results = await runSubtitleBatch(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      candidates: <VideoSubtitleCandidate>[
        _Cand('Show - 01.ja.srt', episode: 1),
        _Cand('Show - 02.ja.srt', episode: 2),
        _Cand('Show - 03.ja.srt', episode: 3),
      ],
      targets: <SubtitleBatchTarget>[
        target(0, 'Show - 01', 'C:/v/Show - 01.mkv'),
        target(1, 'Show - 02', r'\\nas\anime\Show - 02.mkv'),
        target(2, 'Show - 03', 'smb://nas/anime/Show - 03.mkv'),
      ],
      saveDirectory: tmp.path,
      subtitleAligner: (Uint8List bytes, String videoPath) async {
        alignedFor.add(videoPath);
        return Uint8List.fromList('aligned'.codeUnits);
      },
    );
    expect(alignedFor, <String>['C:/v/Show - 01.mkv']);
    expect(File(results[0].subtitlePath!).readAsStringSync(), 'aligned');
    for (final SubtitleBatchItem item in results.skip(1)) {
      expect(item.status, SubtitleBatchStatus.done);
      expect(
        File(item.subtitlePath!).readAsStringSync(),
        startsWith('1\n00:00:01,000'),
      );
    }
  });

  test('preferredLanguage 把该语言排到前面', () async {
    final _FakeProvider provider = _FakeProvider();
    final List<SubtitleBatchItem> results = await runSubtitleBatch(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      candidates: <VideoSubtitleCandidate>[
        _Cand('Show - 01.ja.srt', episode: 1),
        _Cand('Show - 01.en.srt', episode: 1, language: 'en'),
      ],
      targets: <SubtitleBatchTarget>[_target(0, 'Show - 01')],
      saveDirectory: tmp.path,
      preferredLanguage: 'en',
    );
    expect(results.single.language, 'en');
  });

  group('整批版本一致（Jimaku 12217 实测形状）', () {
    // 某发布组只出了第 1 集、文件名字母序又靠前（`[` < `グ`）：改前逐集独立挑，
    // 第 1 集拿它的 .ass、其余集拿 Netflix .srt，同一季混排。
    String netflix(int ep) =>
        'グロウアップショウ.S01E${ep.toString().padLeft(2, '0')}.WEBRip.Netflix.ja[cc].srt';
    String shincaps(int ep, String ext) =>
        '[shincaps] Grow Up Show - ${ep.toString().padLeft(2, '0')} (AT-X).$ext';
    List<SubtitleBatchTarget> targets(int count) => <SubtitleBatchTarget>[
      for (int ep = 1; ep <= count; ep++)
        _target(ep - 1, 'Show - ${ep.toString().padLeft(2, '0')}'),
    ];

    test('只覆盖第 1 集的版本不再抢走第 1 集：整批落在同一版本', () async {
      final _FakeProvider provider = _FakeProvider();
      await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          _Cand(
            '[Nekomoe kissaten&LoliHouse] Grow Up Show - 01 [WebRip][JPN].ass',
            episode: 1,
          ),
          for (int ep = 1; ep <= 3; ep++) _Cand(netflix(ep), episode: ep),
        ],
        targets: targets(3),
        saveDirectory: tmp.path,
      );
      expect(provider.downloaded, <String>[netflix(1), netflix(2), netflix(3)]);
    });

    test('同语言同覆盖：ASS 版本优先于 SRT 版本，整季都是 .ass', () async {
      final _FakeProvider provider = _FakeProvider();
      await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          for (int ep = 1; ep <= 3; ep++) ...<VideoSubtitleCandidate>[
            _Cand(shincaps(ep, 'srt'), episode: ep),
            _Cand(shincaps(ep, 'ass'), episode: ep),
            _Cand(netflix(ep), episode: ep),
          ],
        ],
        targets: targets(3),
        saveDirectory: tmp.path,
      );
      expect(provider.downloaded, <String>[
        shincaps(1, 'ass'),
        shincaps(2, 'ass'),
        shincaps(3, 'ass'),
      ]);
    });

    test('首选版本缺的集由次选版本补，其余集不受影响', () async {
      final _FakeProvider provider = _FakeProvider();
      await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          for (final int ep in <int>[1, 2, 4])
            _Cand(shincaps(ep, 'ass'), episode: ep),
          for (final int ep in <int>[3, 4]) _Cand(netflix(ep), episode: ep),
        ],
        targets: targets(4),
        saveDirectory: tmp.path,
      );
      expect(provider.downloaded, <String>[
        shincaps(1, 'ass'),
        shincaps(2, 'ass'),
        netflix(3),
        shincaps(4, 'ass'),
      ]);
    });

    String assBody(String line) => <String>[
      '[Events]',
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
          'Effect, Text',
      for (int i = 0; i < 6; i++)
        'Dialogue: 0,0:00:0$i.00,0:00:0$i.90,Default,,0,0,0,,$line',
    ].join('\n');

    test('文件名没写语言的版本按正文判语言：日语正文的全季 ASS 拿下整季，代表文件不重下', () async {
      final _FakeProvider provider = _FakeProvider(
        bodies: <String, String>{
          for (int ep = 1; ep <= 3; ep++)
            shincaps(ep, 'ass'): assBody('サーカスは　みんなを幸せにするんだ'),
        },
      );
      final List<SubtitleBatchItem> results = await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          _Cand(
            '[Nekomoe kissaten&LoliHouse] Grow Up Show - 01 [WebRip][JPN].ass',
            episode: 1,
          ),
          for (int ep = 1; ep <= 3; ep++) ...<VideoSubtitleCandidate>[
            _Cand(shincaps(ep, 'ass'), episode: ep, language: ''),
            _Cand(netflix(ep), episode: ep),
          ],
        ],
        targets: targets(3),
        saveDirectory: tmp.path,
      );
      // 探测下的第 1 集代表文件就是第 1 集要用的那份：只下一次。
      expect(provider.downloaded, <String>[
        shincaps(1, 'ass'),
        shincaps(2, 'ass'),
        shincaps(3, 'ass'),
      ]);
      expect(
        results.map((SubtitleBatchItem i) => i.language).toList(),
        <String>['ja', 'ja', 'ja'],
      );
    });

    test('正文是中文的未标语言版本不压过 ja 版本', () async {
      final _FakeProvider provider = _FakeProvider(
        bodies: <String, String>{
          for (int ep = 1; ep <= 3; ep++)
            shincaps(ep, 'ass'): assBody('马戏团会让所有人都幸福的'),
        },
      );
      await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          for (int ep = 1; ep <= 3; ep++)
            _Cand(shincaps(ep, 'ass'), episode: ep, language: ''),
          for (int ep = 1; ep <= 3; ep++) _Cand(netflix(ep), episode: ep),
        ],
        targets: targets(3),
        saveDirectory: tmp.path,
      );
      expect(provider.downloaded, <String>[
        shincaps(1, 'ass'), // 探测
        netflix(1),
        netflix(2),
        netflix(3),
      ]);
    });

    test('正文也判不出的版本：语言偏好仍高于覆盖，不压过 ja 版本', () async {
      final _FakeProvider provider = _FakeProvider();
      await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          for (int ep = 1; ep <= 3; ep++)
            _Cand(shincaps(ep, 'ass'), episode: ep, language: ''),
          for (int ep = 2; ep <= 3; ep++) _Cand(netflix(ep), episode: ep),
        ],
        targets: targets(3),
        saveDirectory: tmp.path,
      );
      expect(provider.downloaded, <String>[
        shincaps(1, 'ass'), // 探测（同时就是第 1 集要用的那份）
        netflix(2),
        netflix(3),
      ]);
    });

    test('一集目标都不覆盖的未标语言版本（别季 / 未编号）不下载探测', () async {
      final _FakeProvider provider = _FakeProvider();
      await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          _Cand('[Other] Grow Up Show S2 - 20.ass', episode: 20, language: ''),
          _Cand('[Movie] Grow Up Show The Movie.srt', language: ''),
          for (int ep = 1; ep <= 2; ep++) _Cand(netflix(ep), episode: ep),
        ],
        targets: targets(2),
        saveDirectory: tmp.path,
      );
      expect(provider.downloaded, <String>[netflix(1), netflix(2)]);
    });

    test('调用方传入的下载入口被探测与落盘共用：探测下过的文件不再走网络', () async {
      final _FakeProvider provider = _FakeProvider(
        bodies: <String, String>{
          for (int ep = 1; ep <= 2; ep++)
            shincaps(ep, 'ass'): assBody('サーカスは　みんなを幸せにするんだ'),
        },
      );
      final VideoSubtitleRegistry registry = VideoSubtitleRegistry(
        <VideoSubtitleProvider>[provider],
      );
      final Map<String, Future<VideoSubtitleDownload>> shared =
          <String, Future<VideoSubtitleDownload>>{};
      Future<VideoSubtitleDownload> download(VideoSubtitleCandidate c) =>
          shared[c.identityKey] ??= registry.download(c);
      final List<VideoSubtitleCandidate> candidates = <VideoSubtitleCandidate>[
        for (int ep = 1; ep <= 2; ep++)
          _Cand(shincaps(ep, 'ass'), episode: ep, language: ''),
      ];
      // 面板先探过第 1 集的代表文件（同一缓存）。
      await download(candidates.first);
      await runSubtitleBatch(
        registry: registry,
        candidates: candidates,
        targets: targets(2),
        saveDirectory: tmp.path,
        download: download,
      );
      expect(provider.downloaded, <String>[
        shincaps(1, 'ass'),
        shincaps(2, 'ass'),
      ]);
    });

    test('调用方探过但判不出的版本（值 null）不再重探', () async {
      final _FakeProvider provider = _FakeProvider();
      await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          for (int ep = 1; ep <= 2; ep++)
            _Cand(shincaps(ep, 'ass'), episode: ep, language: ''),
          for (int ep = 1; ep <= 2; ep++) _Cand(netflix(ep), episode: ep),
        ],
        targets: targets(2),
        saveDirectory: tmp.path,
        probedVersionLanguages: <String, SubtitleContentLanguage?>{
          subtitleVersionKeyOf(_Cand(shincaps(1, 'ass'), language: '')): null,
        },
      );
      // 没有探测下载：只下了两集实际要用的 Netflix。
      expect(provider.downloaded, <String>[netflix(1), netflix(2)]);
    });

    test('代表文件下载失败（抛错 / 空字节）不记为已探，下到但判不出才记 null', () async {
      final Map<String, SubtitleContentLanguage?> probed =
          await probeUnlabeledVersionLanguages<String>(
            files: <String>['throws', 'empty', 'opaque'],
            targetEpisodes: <int>[1],
            versionOf: (String f) => f,
            declaredLanguageOf: (String _) => '',
            episodeOf: (String _) => 1,
            fetch: (String f) async {
              if (f == 'throws') throw const SocketException('reset');
              if (f == 'empty') return Uint8List(0);
              return Uint8List.fromList(
                utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n123\n'),
              );
            },
          );
      // 暂时性下载失败留给下一次探测重试；判不出是结论，不再重探。
      expect(probed, <String, SubtitleContentLanguage?>{'opaque': null});
    });
  });

  test('唯一的整季包没下下来：每集带同一个异常对象，日志去重后只剩一条', () async {
    final _PackProvider provider = _PackProvider(
      failing: <String>{'Show S1.zip'},
    );
    final List<SubtitleBatchItem> results = await runSubtitleBatch(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      candidates: <VideoSubtitleCandidate>[_Pack('Show S1.zip')],
      targets: <SubtitleBatchTarget>[
        for (int ep = 1; ep <= 3; ep++) _target(ep - 1, 'Show - 0$ep'),
      ],
      saveDirectory: tmp.path,
    );
    expect(provider.downloaded, <String>['Show S1.zip'], reason: '包只下一次');
    expect(
      results.map((SubtitleBatchItem i) => i.status),
      everyElement(SubtitleBatchStatus.noMatch),
    );
    expect(
      results.first.error,
      isA<ExternalProviderFailure>().having(
        (ExternalProviderFailure f) => f.statusCode,
        'statusCode',
        429,
      ),
      reason: '「包没下下来」与「真的没有这一集」要分得开',
    );
    final List<SubtitleBatchItem> distinct = subtitleBatchDistinctFailures(
      results,
    );
    expect(distinct, hasLength(1), reason: '同一个包的失败逐集各记一条，3 集就是 3 条相同的报错');
    expect(distinct.single.episode, 1);
  });

  test('一个包失败、另一个包下成功但没有这一集：这一集不挂别的包的下载异常', () async {
    final _PackProvider provider = _PackProvider(
      failing: <String>{'Show S1 [A].zip'},
      entries: <String, List<String>>{
        'Show S1 [B].zip': <String>['Show - 01.ja.srt'],
      },
    );
    final List<SubtitleBatchItem> results = await runSubtitleBatch(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      candidates: <VideoSubtitleCandidate>[
        _Pack('Show S1 [A].zip'),
        _Pack('Show S1 [B].zip'),
      ],
      targets: <SubtitleBatchTarget>[
        _target(0, 'Show - 01'),
        _target(1, 'Show - 02'),
      ],
      saveDirectory: tmp.path,
    );
    expect(provider.downloaded.toSet(), <String>{
      'Show S1 [A].zip',
      'Show S1 [B].zip',
    });
    expect(results[0].status, SubtitleBatchStatus.done);
    expect(results[1].status, SubtitleBatchStatus.noMatch);
    expect(
      results[1].error,
      isNull,
      reason: 'B 包下成功了、里面没有第 2 集；挂上 A 包的 429 会让行文案说成限流',
    );
    expect(subtitleBatchDistinctFailures(results), isEmpty);
  });

  test('subtitleBatchDistinctFailures：不同的异常各留一条，按首次出现的集', () {
    SubtitleBatchItem item(int episode, Object? error) => SubtitleBatchItem(
      target: _target(episode - 1, 'Show - 0$episode'),
      episode: episode,
    )..error = error;
    final StateError a = StateError('a');
    final StateError b = StateError('a');
    final List<SubtitleBatchItem> distinct = subtitleBatchDistinctFailures(
      <SubtitleBatchItem>[item(1, a), item(2, null), item(3, b), item(4, a)],
    );
    expect(distinct.map((SubtitleBatchItem i) => i.episode), <int>[1, 3]);
  });

  test('未编号字幕只在唯一目标时采用；多目标 → ambiguousUnnumbered', () async {
    final _FakeProvider provider = _FakeProvider();
    final List<VideoSubtitleCandidate> movie = <VideoSubtitleCandidate>[
      _Cand('Movie.ja.srt'),
    ];
    final List<SubtitleBatchItem> sole = await runSubtitleBatch(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      candidates: movie,
      targets: <SubtitleBatchTarget>[_target(0, 'Movie')],
      saveDirectory: tmp.path,
    );
    expect(sole.single.status, SubtitleBatchStatus.done);
    final List<SubtitleBatchItem> many = await runSubtitleBatch(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      candidates: movie,
      targets: <SubtitleBatchTarget>[
        _target(0, 'Part A'),
        _target(1, 'Part B'),
      ],
      saveDirectory: tmp.path,
    );
    expect(
      many.map((SubtitleBatchItem i) => i.status),
      everyElement(SubtitleBatchStatus.noMatch),
    );
    expect(many.first.message, 'jimaku subtitles carry no episode numbers');
  });

  test('单集下载失败记 failed，不中断后面的集', () async {
    final _FakeProvider provider = _FakeProvider(
      failNames: <String>{'Show - 01.ja.srt'},
    );
    final List<SubtitleBatchItem> results = await runSubtitleBatch(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      candidates: <VideoSubtitleCandidate>[
        _Cand('Show - 01.ja.srt', episode: 1),
        _Cand('Show - 02.ja.srt', episode: 2),
      ],
      targets: <SubtitleBatchTarget>[
        _target(0, 'Show - 01'),
        _target(1, 'Show - 02'),
      ],
      saveDirectory: tmp.path,
    );
    expect(results[0].status, SubtitleBatchStatus.failed);
    expect(results[1].status, SubtitleBatchStatus.done);
    // 失败留的是异常对象，不只是 `'$e'` 字符串：面板要靠它分出 401 / 429 / 404。
    expect(
      results[0].error,
      isA<ExternalProviderFailure>().having(
        (ExternalProviderFailure f) => f.kind,
        'kind',
        ExternalProviderFailureKind.unavailable,
      ),
    );
    expect(results[1].error, isNull);
  });

  test('onItemDone 抛错（调用方持久化失败）只算这一集失败：保留已落盘路径，后面的集照常处理', () async {
    final _FakeProvider provider = _FakeProvider();
    final List<int> finished = <int>[];
    final List<SubtitleBatchItem> results = await runSubtitleBatch(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      candidates: <VideoSubtitleCandidate>[
        for (int ep = 1; ep <= 3; ep++)
          _Cand('Show - 0$ep.ja.srt', episode: ep),
      ],
      targets: <SubtitleBatchTarget>[
        for (int ep = 1; ep <= 3; ep++) _target(ep - 1, 'Show - 0$ep'),
      ],
      saveDirectory: tmp.path,
      onItemDone: (SubtitleBatchItem item) async {
        finished.add(item.episode);
        if (item.episode == 2) throw StateError('db write failed');
      },
    );
    expect(finished, <int>[1, 2, 3], reason: '第 2 集持久化抛错不得中断第 3 集');
    expect(
      results.map((SubtitleBatchItem i) => i.status),
      <SubtitleBatchStatus>[
        SubtitleBatchStatus.done,
        SubtitleBatchStatus.failed,
        SubtitleBatchStatus.done,
      ],
    );
    expect(results[1].error, isStateError);
    expect(
      File(results[1].subtitlePath!).existsSync(),
      isTrue,
      reason: '文件已落盘，路径要留着',
    );
  });

  test('SubtitleVersionLanguageProbe：下载失败 / 空字节不进缓存，下次重探；判不出才是结论', () async {
    final _Cand candidate = _Cand('[shincaps] Show - 01.ass', episode: 1);
    int calls = 0;
    final SubtitleVersionLanguageProbe probe = SubtitleVersionLanguageProbe(
      download: (VideoSubtitleCandidate c) async {
        calls++;
        if (calls == 1) throw const SocketException('reset');
        if (calls == 2) {
          return VideoSubtitleDownload(
            bytes: Uint8List(0),
            fileName: c.fileName,
            language: '',
          );
        }
        return VideoSubtitleDownload(
          bytes: Uint8List.fromList(
            utf8.encode(
              '1\n00:00:01,000 --> 00:00:02,000\n'
              'サーカスは　みんなを幸せにするんだ\n',
            ),
          ),
          fileName: c.fileName,
          language: '',
        );
      },
    );
    expect(await probe.probe(candidate), isNull);
    expect(await probe.probe(candidate), isNull);
    expect(
      await probe.probe(candidate),
      SubtitleContentLanguage.japanese,
      reason: '前两次是暂时性失败，不得被缓存成「判不出」',
    );
    expect(await probe.probe(candidate), SubtitleContentLanguage.japanese);
    expect(calls, 3, reason: '判出来之后走缓存，不再下载');

    // 下到了但判不出：是结论，缓存住不再重下。
    int opaqueCalls = 0;
    final SubtitleVersionLanguageProbe opaque = SubtitleVersionLanguageProbe(
      download: (VideoSubtitleCandidate c) async {
        opaqueCalls++;
        return VideoSubtitleDownload(
          bytes: Uint8List.fromList(
            utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n123\n'),
          ),
          fileName: c.fileName,
          language: '',
        );
      },
    );
    expect(await opaque.probe(candidate), isNull);
    expect(await opaque.probe(candidate), isNull);
    expect(opaqueCalls, 1);
  });

  test('resolveSubtitleBatchEpisode：路径 → 标题 → sortIndex+1', () {
    expect(resolveSubtitleBatchEpisode(_target(4, 'Show - 07')), 7);
    expect(
      resolveSubtitleBatchEpisode(
        const SubtitleBatchTarget(
          bookUid: 'x',
          title: 'Show E03',
          videoPath: 'C:/v/untitled.mkv',
          sortIndex: 0,
          isStream: false,
        ),
      ),
      3,
    );
    expect(
      resolveSubtitleBatchEpisode(
        const SubtitleBatchTarget(
          bookUid: 'x',
          title: 'Movie',
          videoPath: 'C:/v/movie.mkv',
          sortIndex: 4,
          isStream: false,
        ),
      ),
      5,
    );
  });

  group('多季防串季（season 隔离）', () {
    test('resolveSubtitleBatchSeason：显式 season → 完整路径（含季目录）→ 标题 → null', () {
      expect(
        resolveSubtitleBatchSeason(
          const SubtitleBatchTarget(
            bookUid: 's2',
            title: 'Show - 01',
            videoPath: 'C:/v/Show - 01.mkv',
            sortIndex: 0,
            isStream: false,
            season: 2,
          ),
        ),
        2,
      );
      expect(resolveSubtitleBatchSeason(_target(0, 'Show S02E01')), 2);
      expect(
        resolveSubtitleBatchSeason(
          const SubtitleBatchTarget(
            bookUid: 'dir-s2',
            title: '01',
            videoPath: 'C:/v/Show/Season 2/01.mkv',
            sortIndex: 0,
            isStream: false,
          ),
        ),
        2,
      );
      expect(
        resolveSubtitleBatchSeason(
          const SubtitleBatchTarget(
            bookUid: 'title-s3',
            title: 'Show S03E01',
            videoPath: 'C:/v/01.mkv',
            sortIndex: 0,
            isStream: false,
          ),
        ),
        3,
      );
      expect(resolveSubtitleBatchSeason(_target(0, 'Show - 01')), isNull);
    });

    test('多季目标只拿到各自季的字幕：仅有第 1 季候选时，第 2 季记 noMatch', () async {
      final _FakeProvider provider = _FakeProvider();
      final List<SubtitleBatchItem> results = await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          _Cand('Show S01E01.ja.srt', season: 1, episode: 1),
        ],
        targets: <SubtitleBatchTarget>[
          _target(0, 'Show S01E01'),
          _target(1, 'Show S02E01'),
        ],
        saveDirectory: tmp.path,
      );
      expect(results[0].status, SubtitleBatchStatus.done);
      expect(results[1].status, SubtitleBatchStatus.noMatch);
      expect(
        results[1].message,
        'subtitle season does not match target season',
      );
      expect(provider.downloaded, <String>['Show S01E01.ja.srt']);
    });

    test('多季目标遇到不标季号的候选：拒绝静默跨季套用到每一季', () async {
      final _FakeProvider provider = _FakeProvider();
      final List<SubtitleBatchItem> results = await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          _Cand('Show - 01.ja.srt', episode: 1),
        ],
        targets: <SubtitleBatchTarget>[
          _target(0, 'Show S01E01'),
          _target(1, 'Show S02E01'),
        ],
        saveDirectory: tmp.path,
      );
      expect(results[0].status, SubtitleBatchStatus.noMatch);
      expect(results[1].status, SubtitleBatchStatus.noMatch);
      expect(provider.downloaded, isEmpty);

      final List<SubtitleBatchItem> mixed = await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          _Cand('Show - 01.ja.srt', episode: 1),
        ],
        targets: <SubtitleBatchTarget>[
          _target(0, 'Show - 01'),
          _target(1, 'Show S02E01'),
        ],
        saveDirectory: tmp.path,
      );
      expect(mixed[0].status, SubtitleBatchStatus.noMatch);
      expect(mixed[1].status, SubtitleBatchStatus.noMatch);
      expect(provider.downloaded, isEmpty);
    });

    test('多季目标 + 多季候选：各自匹配对应季的字幕', () async {
      final _FakeProvider provider = _FakeProvider(
        bodies: const <String, String>{
          'Show S01E01.ja.srt': '1\n00:00:01,000 --> 00:00:02,000\ns1\n',
          'Show S02E01.ja.srt': '1\n00:00:01,000 --> 00:00:02,000\ns2\n',
        },
      );
      final List<SubtitleBatchItem> results = await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
        candidates: <VideoSubtitleCandidate>[
          _Cand('Show S01E01.ja.srt', episode: 1),
          _Cand('Show S02E01.ja.srt', episode: 1),
        ],
        targets: <SubtitleBatchTarget>[
          _target(0, 'Show S01E01'),
          _target(1, 'Show S02E01'),
        ],
        saveDirectory: tmp.path,
      );
      expect(results[0].status, SubtitleBatchStatus.done);
      expect(results[1].status, SubtitleBatchStatus.done);
      expect(File(results[0].subtitlePath!).readAsStringSync(), contains('s1'));
      expect(File(results[1].subtitlePath!).readAsStringSync(), contains('s2'));
    });

    test('整季压缩包按季隔离：合包拆出各自季，第 1 季包不套给第 2 季', () async {
      final _PackProvider completePack = _PackProvider(
        entries: const <String, List<String>>{
          'Show Complete.zip': <String>[
            'Show S01E01.ja.srt',
            'Show S02E01.ja.srt',
          ],
        },
      );
      final List<SubtitleBatchItem> completeResults = await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[completePack]),
        candidates: <VideoSubtitleCandidate>[_Pack('Show Complete.zip')],
        targets: <SubtitleBatchTarget>[
          _target(0, 'Show S01E01'),
          _target(1, 'Show S02E01'),
        ],
        saveDirectory: tmp.path,
      );
      expect(completeResults[0].status, SubtitleBatchStatus.done);
      expect(completeResults[0].subtitlePath, contains('Show S01E01'));
      expect(completeResults[1].status, SubtitleBatchStatus.done);
      expect(completeResults[1].subtitlePath, contains('Show S02E01'));

      final _PackProvider s1OnlyPack = _PackProvider(
        entries: const <String, List<String>>{
          'Show S1.zip': <String>['Show - 01.ja.srt'],
        },
      );
      final List<SubtitleBatchItem> s1OnlyResults = await runSubtitleBatch(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[s1OnlyPack]),
        candidates: <VideoSubtitleCandidate>[_Pack('Show S1.zip', season: 1)],
        targets: <SubtitleBatchTarget>[
          _target(0, 'Show S01E01'),
          _target(1, 'Show S02E01'),
        ],
        saveDirectory: tmp.path,
      );
      expect(s1OnlyResults[0].status, SubtitleBatchStatus.done);
      expect(s1OnlyResults[1].status, SubtitleBatchStatus.noMatch);
      expect(
        s1OnlyResults[1].message,
        'subtitle season does not match target season',
      );
    });
  });
}
