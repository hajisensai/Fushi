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

// 详情页海报位：漫画 / 条漫封面要整张显示（用户 2026-11-12「封面显示全」）。
// 海报位比例夹在 0.5～1，异形图（长条 / 横跨页）在海报位里等比缩进，不再被
// 调用方的 BoxFit.cover 裁掉。
void main() {
  const ValueKey<String> posterKey = ValueKey<String>('poster');

  Future<Size> posterSize(WidgetTester tester, double aspect) async {
    final _PendingImage image = _PendingImage('cover-$aspect');
    CoverProbeMemo.rememberAspect(
      image,
      aspect,
      epoch: CoverProviderEpoch.of(image),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MediaPosterDetailHero(
              title: 'Title',
              poster: const ColoredBox(key: posterKey, color: Colors.teal),
              posterImage: image,
              primaryAction: MediaDetailPrimaryButton(
                icon: FushiIcons.play,
                label: 'Read',
                onPressed: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.getSize(find.byKey(posterKey));
  }

  testWidgets('条漫长图（1:4）整张显示：内容按固有比例、不被裁成海报位比例', (WidgetTester tester) async {
    final Size size = await posterSize(tester, 0.25);
    expect(size.width / size.height, moreOrLessEquals(0.25, epsilon: 0.01));
  });

  testWidgets('横跨页（2:1）整张显示：内容按固有比例等比缩进海报位', (WidgetTester tester) async {
    final Size size = await posterSize(tester, 2);
    expect(size.width / size.height, moreOrLessEquals(2, epsilon: 0.01));
  });

  testWidgets('常规竖版封面（0.7）照旧铺满海报位', (WidgetTester tester) async {
    final Size size = await posterSize(tester, 0.7);
    expect(size.width / size.height, moreOrLessEquals(0.7, epsilon: 0.01));
  });
}
