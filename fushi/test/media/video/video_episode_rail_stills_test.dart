import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart'
    show kPendingCoverImage;
import 'package:fushi/src/media/video/metadata/video_metadata_image_provider.dart';
import 'package:fushi/src/media/video/video_episode_rail.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 拍板 design-player-episode-rail-stills：播放器内选集面板（`VideoEpisodeRail`）
/// 与合集选集页同一套取图——手动封面 > 分集剧照 > 自动截图，末尾垫合集段回落；
/// 首选图加载失败依次回落。
void main() {
  group('videoPanelEpisodeThumbCandidates', () {
    final ImageProvider cover = FileImage(File('cover.jpg'));
    final ImageProvider still = FileImage(File('still.jpg'));
    final ImageProvider series = FileImage(File('series.jpg'));

    test('手动封面：封面 > 剧照 > 合集段', () {
      expect(
        videoPanelEpisodeThumbCandidates(
          cover: cover,
          coverIsUserChosen: true,
          still: still,
          seriesFallback: series,
        ),
        <ImageProvider>[cover, still, series],
      );
    });

    test('自动截图封面：剧照 > 截图 > 合集段', () {
      expect(
        videoPanelEpisodeThumbCandidates(
          cover: cover,
          coverIsUserChosen: false,
          still: still,
          seriesFallback: series,
        ),
        <ImageProvider>[still, cover, series],
      );
    });

    test('封面来源还没读到且封面与剧照都有：停在待定占位，不先闪剧照', () {
      expect(
        videoPanelEpisodeThumbCandidates(
          cover: cover,
          coverIsUserChosen: null,
          still: still,
          seriesFallback: series,
        ).first,
        same(kPendingCoverImage),
      );
    });

    test('没剧照（远端集 / 未刮削）：截图 > 合集段，与旧链一致', () {
      expect(
        videoPanelEpisodeThumbCandidates(
          cover: cover,
          coverIsUserChosen: false,
          still: null,
          seriesFallback: series,
        ),
        <ImageProvider>[cover, series],
      );
    });

    test('只有剧照：剧照 > 合集段；全空：空表（面板占位）', () {
      expect(
        videoPanelEpisodeThumbCandidates(
          cover: null,
          coverIsUserChosen: false,
          still: still,
          seriesFallback: series,
        ),
        <ImageProvider>[still, series],
      );
      expect(
        videoPanelEpisodeThumbCandidates(
          cover: null,
          coverIsUserChosen: null,
          still: null,
          seriesFallback: null,
        ),
        isEmpty,
      );
    });
  });

  group('VideoEpisodeRail 取图回落', () {
    Future<void> pumpRail(WidgetTester tester, VideoEpisodeEntry entry) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoEpisodeRail(
              episodes: <VideoEpisodeEntry>[entry],
              currentIndex: 0,
              onTapEpisode: (int _) {},
              colorScheme: const ColorScheme.dark(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Iterable<ImageProvider> shownImages(WidgetTester tester) => tester
        .widgetList<Image>(find.byType(Image))
        .map((Image image) => image.image);

    testWidgets('首选剧照加载失败：面板换下一张（自动截图）', (WidgetTester tester) async {
      final ImageProvider brokenStill = _BrokenImage();
      final ImageProvider frame = _NeverLoadingImage();
      final List<ImageProvider> images = videoPanelEpisodeThumbCandidates(
        cover: frame,
        coverIsUserChosen: false,
        still: brokenStill,
        seriesFallback: null,
      );
      await pumpRail(
        tester,
        VideoEpisodeEntry(
          title: '第1话',
          cover: images.first,
          coverFallbacks: images.skip(1).toList(),
        ),
      );
      final Iterable<ImageProvider> shown = shownImages(tester);
      expect(shown, contains(frame));
      expect(shown, isNot(contains(brokenStill)));
    });

    testWidgets('剧照优先：截图在后备里时面板先挂剧照', (WidgetTester tester) async {
      final ImageProvider still = _NeverLoadingImage();
      final ImageProvider frame = _NeverLoadingImage();
      final List<ImageProvider> images = videoPanelEpisodeThumbCandidates(
        cover: frame,
        coverIsUserChosen: false,
        still: still,
        seriesFallback: null,
      );
      await pumpRail(
        tester,
        VideoEpisodeEntry(
          title: '第1话',
          cover: images.first,
          coverFallbacks: images.skip(1).toList(),
        ),
      );
      final Iterable<ImageProvider> shown = shownImages(tester);
      expect(shown, contains(still));
      expect(shown, isNot(contains(frame)));
    });

    testWidgets('全部失败：退占位图标', (WidgetTester tester) async {
      await pumpRail(
        tester,
        VideoEpisodeEntry(
          title: '第1话',
          cover: _BrokenImage(),
          coverFallbacks: <ImageProvider>[_BrokenImage()],
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(FushiIcons.video), findsOneWidget);
    });
  });

  test('播放器选集面板复用共享选图函数（不另写一套）', () {
    final String source = File(
      'lib/src/pages/implementations/video_fushi/episode.part.dart',
    ).readAsStringSync();
    expect(source, contains('videoPanelEpisodeThumbCandidates('));
    expect(source, contains('videoFileEpisodeStillImage('));
    expect(source, contains('coverFallbacks:'));
    final String page = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    expect(page, contains('_loadPlaylistEpisodeThumbSources(refs)'));
  });
}

/// 一加载就报错的图（模拟远程剧照 404 / 文件坏掉）。
class _BrokenImage extends ImageProvider<_BrokenImage> {
  @override
  Future<_BrokenImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_BrokenImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _BrokenImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    Future<ImageInfo>.error(StateError('broken still')),
  );
}

/// 永远不出帧的图（只用来确认它被挂上了）。
class _NeverLoadingImage extends ImageProvider<_NeverLoadingImage> {
  @override
  Future<_NeverLoadingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_NeverLoadingImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _NeverLoadingImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}
