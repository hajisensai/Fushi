import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:path/path.dart' as p;

/// 原盘成员补字幕（虚拟分集路径、无指纹、托管目录）与「按语言判已有」的契约。
void main() {
  late Directory root;
  late Directory managed;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-backfill-disc-');
    managed = Directory(p.join(root.path, 'video_subtitles'));
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  VideoMediaReference media() => VideoMediaReference(
    providerId: 'anilist',
    mediaId: '100',
    mediaKind: VideoMetadataMediaKind.tv,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: 'Show',
    season: 1,
    episode: 2,
  );

  /// 一张只有 `00001.mpls` 的盘；成员是它切出来的第 2 集 `00001.p02.mpls`（虚拟路径）。
  Future<String> discEpisodePath() async {
    final Directory playlist = Directory(
      p.join(root.path, 'Show Vol.1', 'BDMV', 'PLAYLIST'),
    );
    await playlist.create(recursive: true);
    await File(
      p.join(playlist.path, '00001.mpls'),
    ).writeAsBytes(<int>[0x4d, 0x50, 0x4c, 0x53], flush: true);
    await File(
      p.join(root.path, 'Show Vol.1', 'BDMV', 'index.bdmv'),
    ).writeAsString('INDX0200', flush: true);
    return p.join(playlist.path, '00001.p02.mpls');
  }

  SubtitleBackfillTarget discTarget(String path) => SubtitleBackfillTarget(
    bookUid: 'disc/book:2',
    videoPath: path,
    media: media(),
    explicitLanguage: 'ja',
    managedSubtitleDirectory: managed.path,
  );

  test('虚拟分集路径不判「视频没了」，搜索请求不带文件指纹', () async {
    final _Provider provider = _Provider();
    final VideoSubtitleBackfillService service = VideoSubtitleBackfillService(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
    );
    final String path = await discEpisodePath();
    expect(File(path).existsSync(), isFalse);
    await service.backfill(discTarget(path));
    expect(provider.lastRequest, isNotNull);
    expect(provider.lastRequest!.fingerprint, isNull);
    expect(provider.lastRequest!.effectiveEpisode, 2);
  });

  test('原盘成员的字幕落托管目录、不进盘目录；再补一次判已有', () async {
    final VideoSubtitleBackfillService service = VideoSubtitleBackfillService(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[
        _Provider(returnsCandidate: true),
      ]),
    );
    final String path = await discEpisodePath();
    final SubtitleBackfillResult first = await service.backfill(
      discTarget(path),
    );
    expect(first.outcome, SubtitleBackfillOutcome.installed);
    expect(
      first.installedPath,
      p.join(managed.path, 'disc-disc_book_2.ja.srt'),
    );
    expect(File(first.installedPath!).existsSync(), isTrue);
    expect(
      Directory(p.dirname(path)).listSync().map((e) => p.basename(e.path)),
      <String>['00001.mpls'],
    );
    final SubtitleBackfillResult second = await service.backfill(
      discTarget(path),
    );
    expect(second.outcome, SubtitleBackfillOutcome.alreadyHasSubtitle);
  });

  group('显式语言时只认该语言的 sidecar', () {
    Future<SubtitleBackfillTarget> fileTarget(
      Map<String, String> sidecars,
    ) async {
      final File video = File(p.join(root.path, 'Show - S01E02.mkv'));
      await video.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
      for (final MapEntry<String, String> e in sidecars.entries) {
        await File(p.join(root.path, e.key)).writeAsString(e.value);
      }
      return SubtitleBackfillTarget(
        bookUid: 'book-2',
        videoPath: video.path,
        media: media(),
        explicitLanguage: 'ja',
      );
    }

    Future<bool> searched(Map<String, String> sidecars) async {
      final _Provider provider = _Provider();
      await VideoSubtitleBackfillService(
        registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[provider]),
      ).backfill(await fileTarget(sidecars));
      return provider.lastRequest != null;
    }

    test('只有中文 sidecar：照样去找日语', () async {
      expect(
        await searched(<String, String>{
          'Show - S01E02.zh.ass': _srt('你好世界这是中文'),
        }),
        isTrue,
      );
    });

    test('有日语 sidecar：不找', () async {
      expect(
        await searched(<String, String>{'Show - S01E02.ja.srt': _srt('こんにちは')}),
        isFalse,
      );
    });

    test('没标语言、正文是日语：不找', () async {
      expect(
        await searched(<String, String>{
          'Show - S01E02.srt': _srt('こんにちは、ひらがなです'),
        }),
        isFalse,
      );
    });

    test('没标语言、正文是英语：照样去找日语', () async {
      expect(
        await searched(<String, String>{
          'Show - S01E02.srt': _srt('Hello there, this is English'),
        }),
        isTrue,
      );
    });
  });

  test('托管文件名只留安全字符', () {
    expect(managedDiscSubtitleStem('a/b\\c:d e'), 'disc-a_b_c_d_e');
    expect(managedDiscSubtitleStem(''), 'disc-unknown');
  });
}

String _srt(String line) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < 12; i++) {
    final int s = 10 + i * 5;
    b.write(
      '${i + 1}\n00:00:${s.toString().padLeft(2, '0')},000 --> '
      '00:00:${s.toString().padLeft(2, '0')},900\n$line$i\n\n',
    );
  }
  return b.toString();
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

class _Provider implements VideoSubtitleProvider {
  _Provider({this.returnsCandidate = false});

  final bool returnsCandidate;
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
      returnsCandidate
          ? <VideoSubtitleCandidate>[_Cand()]
          : const <VideoSubtitleCandidate>[],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async => VideoSubtitleDownload(
    bytes: Uint8List.fromList(utf8.encode(_srt('こんにちは、ひらがなです'))),
    fileName: candidate.fileName,
    language: 'ja',
  );

  @override
  void close() {}
}
