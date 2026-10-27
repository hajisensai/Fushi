import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi/src/ops/ctl_video_subtitle_fetch_routes.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';

/// `video.subtitle.search` 给每条候选标「是不是这部作品」：剧场版搜回 TV 版分集
/// （用户实报：「最終楽章 響け!ユーフォニアム 前編」搜出 S01E03…）时必须带
/// `mismatch`，AI 补字幕技能据此不把它们拿给用户挑。
void main() {
  SubtitleBackfillTarget target() => SubtitleBackfillTarget(
    bookUid: 'b1',
    videoPath: 'x.mkv',
    media: VideoMediaReference(
      providerId: 'anidb',
      mediaId: '1',
      mediaKind: VideoMetadataMediaKind.movie,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: '最終楽章 響け!ユーフォニアム 前編',
    ),
  );

  test('剧场版目标 + TV 分集发布名 → mismatch', () {
    final Map<String, Object?> json = ctlSubtitleWorkMismatchJson(
      target(),
      _Candidate('響け!.ユーフォニアム.S01E03.はじめてアンサンブル.WEBRip.ja.srt'),
    );
    expect(json['mismatch'], isA<String>());
  });

  test('同名剧场版字幕 → 不标', () {
    expect(
      ctlSubtitleWorkMismatchJson(
        target(),
        _Candidate('最終楽章 響け!ユーフォニアム 前編.WEBRip.ja.ass'),
      ),
      isEmpty,
    );
  });
}

class _Candidate extends VideoSubtitleCandidate {
  _Candidate(String fileName)
    : super(
        providerId: 'test',
        remoteId: fileName,
        fileName: fileName,
        language: 'ja',
        providerPriority: 0,
      );
}
