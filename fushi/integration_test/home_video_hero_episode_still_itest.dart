import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/generate_test_image.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _bookUid = 'video/itest-hero-episode-still';

/// 首页「继续观看」主卡：本地散片的这一集有刮削剧照时，大图必须是剧照而不是竖版
/// 封面；删掉剧照后回落到封面。两帧截图都落 `.codex-test`，人眼对比。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hero card shows the episode still, falls back to the poster', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    final FushiDatabase db = appModel.database;

    final Directory dir = await Directory.systemTemp.createTemp('hero_still_');
    const TestImageGenerator gen = TestImageGenerator();
    // 竖版「封面」偏红蓝渐变；剧照横版 16:9，seed 不同花纹不同，截图一眼可辨。
    final File poster = File('${dir.path}/poster.png')
      ..writeAsBytesSync(gen.pngBytes(width: 400, height: 600, seed: 1));
    final File still = File('${dir.path}/still.png')
      ..writeAsBytesSync(gen.pngBytes(width: 1280, height: 720, seed: 9));
    final File video = File('${dir.path}/Show - S01E01.mp4')
      ..writeAsBytesSync(<int>[0]);

    await VideoBookRepository(db).saveVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>(_bookUid),
        title: const Value<String>('Beyond Time Gaze S01E01'),
        videoPath: Value<String>(video.path),
        coverPath: Value<String?>(poster.path),
        lastPositionMs: const Value<int>(293000),
        lastPlayedAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: const Value<String?>(_bookUid),
        mediaType: 'tv',
        title: 'Beyond Time Gaze',
        updatedAt: 1,
      ),
    );
    final int seasonId = await db.upsertVideoMetadataSeason(
      VideoMetadataSeasonsCompanion.insert(
        workId: workId,
        seasonNumber: 1,
        updatedAt: 1,
      ),
    );
    await db.upsertVideoMetadataEpisode(
      VideoMetadataEpisodesCompanion.insert(
        seasonId: seasonId,
        bookUid: const Value<String?>(_bookUid),
        episodeNumber: 1,
        updatedAt: 1,
      ),
    );
    final VideoMetadataEpisodeRow episode =
        (await db.getVideoMetadataEpisodesByBook(_bookUid)).single;
    await db.replaceVideoMetadataImages(
      episodeId: episode.id,
      images: <VideoMetadataImagesCompanion>[
        VideoMetadataImagesCompanion.insert(
          episodeId: Value<int?>(episode.id),
          provider: 'tmdb',
          kind: 'thumb',
          remoteUrl: 'https://invalid.example/still.png',
          localPath: Value<String?>(still.path),
          updatedAt: 1,
        ),
      ],
    );

    HomePage.debugSelectTab?.call(HomeTab.video);
    await tester.pump(const Duration(seconds: 1));
    HomeVideoPage.debugRefreshVideos?.call();
    await tester.pump(const Duration(seconds: 3));
    final ObserveShot withStill = await captureFlutterFrame(
      tester,
      'hero-with-episode-still',
    );
    debugPrint('[hero-still] with still: ${withStill.path}');
    expect(withStill.saved, isTrue);

    // 回落：删掉这一集的剧照，主卡应回到封面（今天的行为）。
    await db.replaceVideoMetadataImages(
      episodeId: episode.id,
      images: const <VideoMetadataImagesCompanion>[],
    );
    HomeVideoPage.debugRefreshVideos?.call();
    await tester.pump(const Duration(seconds: 3));
    final ObserveShot fallback = await captureFlutterFrame(
      tester,
      'hero-fallback-poster',
    );
    debugPrint('[hero-still] fallback: ${fallback.path}');
    expect(fallback.saved, isTrue);

    await dir.delete(recursive: true);
  });
}
