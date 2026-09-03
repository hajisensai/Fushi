import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_batch.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

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
  _FakeProvider({this.failNames = const <String>{}});

  final Set<String> failNames;
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
        '1\n00:00:01,000 --> 00:00:02,000\nx\n'.codeUnits,
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
