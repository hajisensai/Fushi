import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_batch.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_content_language.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_language_probe.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

/// 来源无关的合集批量编排：判据委托 `chooseSubtitleForEpisode`、下载走 registry、
/// 落盘名带 bookUid 前缀、单集失败不中断整批。
class _Cand extends VideoSubtitleCandidate {
  _Cand(String name, {int? episode, String language = 'ja'})
    : super(
        providerId: 'fake',
        remoteId: name,
        fileName: name,
        language: language,
        providerPriority: 1,
        episode: episode,
      );
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
}
