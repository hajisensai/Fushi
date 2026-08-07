import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/video_episode_rail.dart';
import 'package:transparent_image/transparent_image.dart';

/// v68 守卫：选集轨道（播放器/合集详情页共用）的 16:9 卡走朝向自适应，
/// 不再裸 `BoxFit.cover` 硬裁。
///
/// 这里曾是全域**唯一**残留的硬裁点：没刮过的集封面是 2:3 刮削海报或方图 exe
/// 抽帧，`cover` 进 16:9 槽会被裁成中间一条（BUG-1299 同病）。锁「封面经
/// [PortraitCoverImage]（landscapeSlot）渲染」这一结构事实——退回裸 Image.cover
/// 本测试即红。
void main() {
  testWidgets('有封面的集卡经 PortraitCoverImage 渲染（横槽自适应）',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VideoEpisodeRail(
          episodes: <VideoEpisodeEntry>[
            VideoEpisodeEntry(
              title: '第1话',
              cover: MemoryImage(kTransparentImage),
            ),
            const VideoEpisodeEntry(title: '第2话'),
          ],
          currentIndex: 0,
          onTapEpisode: (int _) {},
          colorScheme: const ColorScheme.dark(),
        ),
      ),
    ));
    await tester.pump();

    expect(
      find.byType(PortraitCoverImage),
      findsOneWidget,
      reason: '有封面的集卡必须走朝向自适应组件；裸 BoxFit.cover 会把竖版海报裁成中间一条',
    );
    // 无封面的集仍是占位图标，不经自适应组件。
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
  });
}
