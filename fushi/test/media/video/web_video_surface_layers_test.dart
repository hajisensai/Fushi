import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/web_video_return_bar.dart';
import 'package:fushi/src/media/video/web_video_surface_layers.dart';

/// BUG-5612：网页档视频槽叠层。OSD 层原来自带 `Positioned.fill`、又被套一层
/// `Positioned(top: 返回条高)`，Debug 报 `Incorrect use of ParentDataWidget`。叠层改成
/// 只收未定位子树、定位只做一次；OSD 让在返回条下面，顶部系统让位不重复让。
void main() {
  const double topPadding = 32;
  const Key surfaceKey = ValueKey<String>('surface');
  const Key videoKey = ValueKey<String>('video');
  const Key barKey = ValueKey<String>('bar');
  const Key osdCardKey = ValueKey<String>('osd-card');

  Future<void> pumpLayers(WidgetTester tester, {required bool hasVideo}) {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(1280, 720),
            padding: EdgeInsets.only(top: topPadding),
          ),
          child: WebVideoSurfaceLayers(
            surface: const ColoredBox(key: surfaceKey, color: Colors.white),
            hasVideo: hasVideo,
            video: const SizedBox.expand(key: videoKey),
            adCover: const ColoredBox(color: Colors.black),
            returnBar: const SizedBox.expand(key: barKey),
            // 与播放页 OSD 同形：SafeArea + 左上角卡片（页面里是 `_buildOsdOverlay`）。
            osd: const SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(key: osdCardKey, width: 120, height: 40),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('露出站点页面：无 ParentData 断言，OSD 与站点页面都让在返回条下面', (
    WidgetTester tester,
  ) async {
    await pumpLayers(tester, hasVideo: false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    const double barExtent = topPadding + kWebVideoReturnBarRowHeight;
    expect(tester.getSize(find.byKey(barKey)).height, barExtent);
    expect(tester.getTopLeft(find.byKey(surfaceKey)).dy, barExtent);
    // 返回条已吃掉顶部系统让位，OSD 的 SafeArea 不再多让 32。
    expect(
      tester.getTopLeft(find.byKey(osdCardKey)),
      const Offset(0, barExtent),
    );
    expect(find.byKey(videoKey), findsNothing);
  });

  testWidgets('有站点视频：画面铺满，返回条与本层 OSD 不挂', (WidgetTester tester) async {
    await pumpLayers(tester, hasVideo: true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(tester.getTopLeft(find.byKey(surfaceKey)).dy, 0);
    expect(tester.getSize(find.byKey(videoKey)), const Size(1280, 720));
    expect(find.byKey(barKey), findsNothing);
    expect(find.byKey(osdCardKey), findsNothing);
  });
}
