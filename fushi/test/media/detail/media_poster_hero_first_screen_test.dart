import 'dart:async';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:fushi/src/utils/cover_provider_epoch.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 永不解码完成的图片源：宽高比只来自 [CoverProbeMemo]，测试里不真解码。
class _PendingImage extends ImageProvider<_PendingImage> {
  const _PendingImage(this.name);

  final String name;

  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_PendingImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _PendingImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}

// BUG-5587：横屏手机（宽 ≥720 走宽式、高只有 ~400）上，16:9 背景带按视口 72%
// 给高，标题与「继续阅读 / 开始观看」被挤出首屏。背景带要给首屏标题块让位。
void main() {
  const ValueKey<String> primaryKey = ValueKey<String>('primary');

  Future<void> pumpHero(WidgetTester tester, Size size, String tag) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _PendingImage backdrop = _PendingImage('backdrop-$tag');
    final _PendingImage cover = _PendingImage('cover-$tag');
    for (final (_PendingImage image, double aspect)
        in <(_PendingImage, double)>[(backdrop, 16 / 9), (cover, 2 / 3)]) {
      CoverProbeMemo.rememberAspect(
        image,
        aspect,
        epoch: CoverProviderEpoch.of(image),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaPosterDetailHero(
              title: '吾輩は猫である',
              originalTitle: '夏目漱石',
              continueLabel: 'Read 35%',
              poster: const ColoredBox(color: Colors.teal),
              posterImage: cover,
              backdrop: backdrop,
              primaryAction: MediaDetailPrimaryButton(
                key: primaryKey,
                icon: FushiIcons.play,
                label: 'Continue reading',
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('横屏手机：主按钮整个落在首屏里', (WidgetTester tester) async {
    await pumpHero(tester, const Size(914, 411), 'phone');
    final Rect primary = tester.getRect(find.byKey(primaryKey));
    expect(primary.bottom, lessThanOrEqualTo(411));
    expect(tester.takeException(), isNull);
  });

  testWidgets('800 高桌面窗口：主按钮也在首屏，背景带只收一点', (WidgetTester tester) async {
    await pumpHero(tester, const Size(1280, 800), 'desktop-800');
    // 首屏上限 800-240=560，视口 72% 上限 576：取 560。
    final Rect primary = tester.getRect(find.byKey(primaryKey));
    expect(primary.top, greaterThan(500));
    expect(primary.bottom, lessThanOrEqualTo(800));
  });

  testWidgets('1000 高桌面窗口：背景带照旧按整图 / 视口比例给', (WidgetTester tester) async {
    await pumpHero(tester, const Size(1280, 1000), 'desktop-1000');
    // 1280 宽 16:9 整图高 720，视口 72% 上限 720，首屏上限 760：背景带 720。
    final Rect primary = tester.getRect(find.byKey(primaryKey));
    expect(primary.top, greaterThan(720));
    expect(primary.bottom, lessThanOrEqualTo(1000));
  });
}
