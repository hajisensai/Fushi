// BUG-1266：YouTube 播放时设置面板「播放」分类里的画质入口行永远不出现。
//
// 自锁链：行的 visible 谓词曾要求 `qualityOptionCount > 0`，而 YouTube 的画质档是**懒解析**
// 的——只有点开画质菜单（即点这一行）触发 getManifest 之后 `_youtubeVariants` 才非空，在那
// 之前 `_qualityOptionCount` 恒 0。于是「要出现得先有档位、要有档位得先点它」，行永不显示；
// 桌面端只剩右键菜单（判据是 `_hasQualityMenu`，与此不一致），移动端彻底没入口。
//
// 这里按用户真实所见断言：渲染真实设置面板 → 切到「播放」分类 → 画质行必须在**尚未解析出
// 任何档位**时就已经可见、且可点。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/utils.dart';

import '../helpers/video_quick_settings_harness.dart';

Future<VideoSheetHarness> _pumpPlaybackCategory(
  WidgetTester tester, {
  required int qualityOptionCount,
  required VoidCallback? onOpenQuality,
  String? qualityCurrentLabel,
}) async {
  final VideoSheetHarness harness = await VideoSheetHarness.create();
  addTearDown(harness.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: buildVideoSheetUnderTest(
          harness: harness,
          host: buildTestVideoHost(
            qualityOptionCount: qualityOptionCount,
            qualityCurrentLabel: qualityCurrentLabel,
            onOpenQuality: onOpenQuality,
          ),
          initialCategory: 'playback',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  testWidgets('YouTube 懒解析前（档位数 0）画质入口仍可见并可点 —— BUG-1266 回归门', (
    WidgetTester tester,
  ) async {
    int opened = 0;
    await _pumpPlaybackCategory(
      tester,
      // 这就是 YouTube 起播后、用户点开画质菜单之前的真实状态：
      // `_youtubeVariants` 还空着，但页面已把 onOpenQuality 接线（`_isYoutubeStream` 为 true）。
      qualityOptionCount: 0,
      qualityCurrentLabel: t.video_quality_auto,
      onOpenQuality: () => opened++,
    );

    final Finder row = find.text(t.video_quality);
    expect(row, findsOneWidget, reason: '懒解析前画质行不可见 = 入口自锁，YouTube 永远调不了画质');

    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(opened, 1, reason: '画质行可见但点不动，等于没有入口');
  });

  testWidgets('已解析出档位时画质入口照常可见（HLS / 已解析的 YouTube 不回归）', (
    WidgetTester tester,
  ) async {
    await _pumpPlaybackCategory(
      tester,
      qualityOptionCount: 8,
      qualityCurrentLabel: '1080p',
      onOpenQuality: () {},
    );
    expect(find.text(t.video_quality), findsOneWidget);
    // 当前档位作副标题呈现，用户不点开也知道现在播的是哪档。
    expect(find.text('1080p'), findsOneWidget);
  });

  testWidgets('无画质菜单的流（onOpenQuality 未接线）不显示画质行', (
    WidgetTester tester,
  ) async {
    await _pumpPlaybackCategory(
      tester,
      qualityOptionCount: 0,
      onOpenQuality: null,
    );
    expect(find.text(t.video_quality), findsNothing,
        reason: '本地文件 / 单档直链不该出现一个点开只有空面板的画质入口');
  });
}
