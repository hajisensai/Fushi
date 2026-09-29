import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:path/path.dart' as p;

/// 补字幕服务接上「按内嵌字幕轨对齐」钩子后的两条边界：
/// - 对齐要几十秒（整片抽轨），这期间别人落了同名 sidecar 就放弃自己这份，
///   不拿 rename 覆盖掉它；
/// - 本机文件照常调用对齐钩子（网络路径的跳过由 `isNetworkMediaPath` 单测钉住，
///   这里的视频必须真实存在，造不出 UNC 路径）。
void main() {
  late Directory root;
  late File video;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-backfill-align-');
    video = File(p.join(root.path, 'Show - S01E01.mkv'));
    await video.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  SubtitleBackfillTarget target() => SubtitleBackfillTarget(
    bookUid: 'book-1',
    videoPath: video.path,
    media: VideoMediaReference(
      providerId: 'anilist',
      mediaId: '100',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: 'Show',
      season: 1,
      episode: 1,
    ),
  );

  test('本机文件：落盘前调用对齐钩子，写的是对齐结果', () async {
    final List<String> alignedFor = <String>[];
    final VideoSubtitleBackfillService service = VideoSubtitleBackfillService(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[
        _OneSubtitleProvider(),
      ]),
      subtitleAligner: (Uint8List bytes, String videoPath) async {
        alignedFor.add(videoPath);
        return Uint8List.fromList(_srt(offsetSeconds: 2).codeUnits);
      },
    );
    final SubtitleBackfillResult result = await service.backfill(target());
    expect(result.outcome, SubtitleBackfillOutcome.installed);
    expect(alignedFor, <String>[video.path]);
    expect(
      File(result.installedPath!).readAsStringSync(),
      _srt(offsetSeconds: 2),
    );
  });

  test('对齐期间同名 sidecar 已被别人落下：不覆盖，临时文件清掉', () async {
    final String sidecar = p.join(root.path, 'Show - S01E01.ja.srt');
    final VideoSubtitleBackfillService service = VideoSubtitleBackfillService(
      registry: VideoSubtitleRegistry(<VideoSubtitleProvider>[
        _OneSubtitleProvider(),
      ]),
      subtitleAligner: (Uint8List bytes, String videoPath) async {
        // 模拟对齐这几十秒里用户 / 另一条路径落了同名 sidecar。
        File(sidecar).writeAsStringSync('user');
        return Uint8List.fromList(_srt(offsetSeconds: 2).codeUnits);
      },
    );
    final SubtitleBackfillResult result = await service.backfill(target());
    expect(result.installedPath, sidecar);
    expect(File(sidecar).readAsStringSync(), 'user');
    expect(File('$sidecar.fushi.tmp').existsSync(), isFalse);
  });
}

String _srt({double offsetSeconds = 0}) {
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < 12; i++) {
    final int startMs = ((10 + i * 5 + offsetSeconds) * 1000).round();
    String ts(int ms) {
      String two(int v) => v.toString().padLeft(2, '0');
      return '${two(ms ~/ 3600000)}:${two((ms ~/ 60000) % 60)}:'
          '${two((ms ~/ 1000) % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
    }

    b.write('${i + 1}\n${ts(startMs)} --> ${ts(startMs + 1500)}\nline $i\n\n');
  }
  return b.toString();
}

class _Cand extends VideoSubtitleCandidate {
  _Cand()
    : super(
        providerId: 'one',
        remoteId: '1',
        fileName: 'Show - 01.ja.srt',
        language: 'ja',
        providerPriority: 0,
        episode: 1,
      );
}

class _OneSubtitleProvider implements VideoSubtitleProvider {
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
    return ProviderBatchResult<VideoSubtitleCandidate>.success(
      <VideoSubtitleCandidate>[_Cand()],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    return VideoSubtitleDownload(
      bytes: Uint8List.fromList(_srt().codeUnits),
      fileName: candidate.fileName,
      language: 'ja',
    );
  }

  @override
  void close() {}
}
