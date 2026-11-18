import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:material_ui/material_ui.dart';

// BUG-4860：封面盖层（远端下载进行中的压暗 + 进度环）曾是姿态变换外的兄弟层
// （`Positioned.fromRect(slot.rect)`），封面斜放 / 缩放 / 位移、按圆角裁切，盖层
// 却画成一块不旋转、直角、错位的暗块。盖层必须与它压着的那张封面同在一个姿态
// 变换里（书封 / 海报 / 唱片摆法还要同在封面卡的圆角裁切里），四角与封面重合。
void main() {
  const ValueKey<String> overlayKey = ValueKey<String>('overlay');
  const ValueKey<String> frontKey = ValueKey<String>('front');

  Widget overlay() =>
      const ColoredBox(key: overlayKey, color: Color(0x7A000000));

  Future<void> pumpBlock(WidgetTester tester, FushiCoverBlock block) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 480, height: 220, child: block),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 盖层与 [cover] 同在一个姿态 [Transform] 里、四角重合；[clipped] 时两者最近的
  /// [ShellClip] 是同一个（封面卡自己的圆角裁切，不是整块色块的外层裁切）。
  void expectOverlayFollowsCover(
    WidgetTester tester,
    Finder cover, {
    required bool clipped,
  }) {
    final Finder overlayFinder = find.byKey(overlayKey);
    expect(overlayFinder, findsOneWidget);
    final Finder pose = find
        .ancestor(of: cover, matching: find.byType(Transform))
        .first;
    expect(
      find.descendant(of: pose, matching: overlayFinder),
      findsOneWidget,
      reason: '盖层不在封面的姿态变换里',
    );
    if (clipped) {
      final Finder coverClip = find
          .ancestor(of: cover, matching: find.byType(ShellClip))
          .first;
      final Finder overlayClip = find
          .ancestor(of: overlayFinder, matching: find.byType(ShellClip))
          .first;
      expect(
        identical(coverClip.evaluate().single, overlayClip.evaluate().single),
        isTrue,
        reason: '盖层不在封面卡的圆角裁切里',
      );
      // 封面卡裁切在姿态变换里面（裁切随封面旋转）。
      expect(find.descendant(of: pose, matching: coverClip), findsOneWidget);
    }
    // 屏上四角与封面重合（变换后的坐标），不是未变换的槽矩形。
    for (final Offset Function(Finder) corner in <Offset Function(Finder)>[
      tester.getTopLeft,
      tester.getTopRight,
      tester.getBottomLeft,
      tester.getBottomRight,
    ]) {
      final Offset a = corner(overlayFinder);
      final Offset b = corner(cover);
      expect((a - b).distance, lessThan(0.01), reason: '盖层四角与封面错位');
    }
  }

  testWidgets('书封扇形：盖层压最前那张，随它旋转并按它的圆角裁切', (WidgetTester tester) async {
    await pumpBlock(
      tester,
      FushiCoverBlock(
        size: FushiCoverBlockSize.regular,
        art: FushiCoverBlockArt.book,
        title: '下载中的漫画',
        covers: const <Widget>[
          ColoredBox(key: frontKey, color: Colors.red),
          ColoredBox(color: Colors.green),
          ColoredBox(color: Colors.blue),
        ],
        coverOverlay: overlay(),
      ),
    );
    expectOverlayFollowsCover(tester, find.byKey(frontKey), clipped: true);
  });

  testWidgets('单本书封（远端占位卡）：盖层随封面姿态', (WidgetTester tester) async {
    await pumpBlock(
      tester,
      FushiCoverBlock(
        size: FushiCoverBlockSize.half,
        art: FushiCoverBlockArt.book,
        title: '下载中的漫画',
        covers: const <Widget>[ColoredBox(key: frontKey, color: Colors.red)],
        coverOverlay: overlay(),
      ),
    );
    expectOverlayFollowsCover(tester, find.byKey(frontKey), clipped: true);
  });

  testWidgets('单张竖海报（海报立在起始侧）：盖层随海报姿态', (WidgetTester tester) async {
    await pumpBlock(
      tester,
      FushiCoverBlock(
        size: FushiCoverBlockSize.regular,
        art: FushiCoverBlockArt.portrait,
        title: '下载中的剧集',
        covers: const <Widget>[ColoredBox(key: frontKey, color: Colors.red)],
        coverOverlay: overlay(),
      ),
    );
    expectOverlayFollowsCover(tester, find.byKey(frontKey), clipped: true);
  });

  testWidgets('唱片摆法：盖层随封面姿态', (WidgetTester tester) async {
    await pumpBlock(
      tester,
      FushiCoverBlock(
        size: FushiCoverBlockSize.regular,
        art: FushiCoverBlockArt.square,
        title: '下载中的专辑',
        covers: const <Widget>[ColoredBox(key: frontKey, color: Colors.red)],
        disc: const ColoredBox(color: Colors.black),
        coverOverlay: overlay(),
      ),
    );
    expectOverlayFollowsCover(tester, find.byKey(frontKey), clipped: true);
  });

  testWidgets('横版剧照：盖层与剧照同在一个姿态变换里', (WidgetTester tester) async {
    await pumpBlock(
      tester,
      FushiCoverBlock(
        size: FushiCoverBlockSize.regular,
        art: FushiCoverBlockArt.landscape,
        title: '下载中的视频',
        covers: const <Widget>[
          SizedBox.expand(
            child: ColoredBox(key: frontKey, color: Colors.red),
          ),
        ],
        coverOverlay: overlay(),
      ),
    );
    expectOverlayFollowsCover(tester, find.byKey(frontKey), clipped: false);
  });
}
