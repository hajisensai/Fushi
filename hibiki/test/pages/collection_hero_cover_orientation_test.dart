import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/cover_ui/landscape_cover_image.dart';

/// BUG-1298 守卫：合集详情页 hero 是宽幅槽（整屏宽 × 400~600 高，约 2.7:1），
/// 而它的图源 `MediaCollections.coverPath` 一个列同时承载两种朝向——导入抽帧的
/// 16:9 横图，与刮削写入的 2:3 竖版海报。
///
/// 根因：hero 原先无条件 `BoxFit.cover`。竖版海报（实测 853×1200）铺进 2.7:1 槽
/// 要放大 4.5 倍、只保留中间 **26%** 的高度带——用户刮削封面后 hero 就成了一条
/// 糊满人脸、头顶被切的横带。刮削前该列为 NULL、回落成员抽帧（16:9）才看着正常，
/// 所以现象表现为「刮削封面以后成这样了」。
///
/// 修复：[LandscapeCoverImage] 按图片固有宽高比分流（`PortraitCoverImage` 的镜像）。
/// 本文件锁三件事：
///  1. 横图仍 `BoxFit.cover` 铺满、不引入模糊垫底（Never break userspace）；
///  2. 竖图走模糊垫底 + `BoxFit.contain` 完整前景；
///  3. 遮罩层序——渐变压在模糊垫底之上、清晰海报之下（否则 hero 底部 0xE8 的渐变
///     会把海报下半截压成一片黑，等于换个方式毁掉海报）。
void main() {
  group('LandscapeCoverImage 按图片朝向分流 — BUG-1298', () {
    testWidgets('横图（16:9 抽帧）仍 cover 铺满，不加模糊垫底', (WidgetTester tester) async {
      final MemoryImage provider =
          MemoryImage(await _solidPngBytes(tester, 1600, 900));
      await _pumpHero(tester, provider);

      expect(
        _fitOfImageWith(tester, BoxFit.cover),
        isTrue,
        reason: '横图必须 BoxFit.cover 铺满宽幅槽——这是本组件引入前的行为，'
            '不得回归',
      );
      expect(
        find.byType(ImageFiltered),
        findsNothing,
        reason: '横图不需要模糊垫底；出现垫底说明朝向判定把横图误判成竖图',
      );
    });

    testWidgets('竖版海报（2:3 刮削）走模糊垫底 + contain 完整前景',
        (WidgetTester tester) async {
      // 用户实际刮到的海报尺寸（853×1200），不是随手编的比例。
      final MemoryImage provider =
          MemoryImage(await _solidPngBytes(tester, 853, 1200));
      await _pumpHero(tester, provider);

      expect(
        find.byType(ImageFiltered),
        findsOneWidget,
        reason: '竖版海报必须有模糊垫底填满宽幅槽的两侧，否则要么黑边要么被裁',
      );
      expect(
        _fitOfImageWith(tester, BoxFit.contain),
        isTrue,
        reason: '竖版海报前景必须 contain 完整显示——cover 会放大 4.5 倍只剩'
            '中间 26%，正是 BUG-1298 的现象',
      );
    });

    testWidgets('竖图路径下遮罩压在垫底之上、清晰海报之下', (WidgetTester tester) async {
      final MemoryImage provider =
          MemoryImage(await _solidPngBytes(tester, 853, 1200));
      await _pumpHero(tester, provider);

      // 取渲染出竖图三层的那个 Stack（含 ImageFiltered 垫底的那个）。
      final Stack stack = tester
          .widgetList<Stack>(find.byType(Stack))
          .firstWhere(
              (Stack s) => s.children.any((Widget w) => w is ImageFiltered));

      final int overlayIndex =
          stack.children.indexWhere((Widget w) => w.key == _overlayKey);
      final int blurIndex =
          stack.children.indexWhere((Widget w) => w is ImageFiltered);
      final int foregroundIndex =
          stack.children.indexWhere((Widget w) => w is Padding);

      expect(overlayIndex, isNonNegative, reason: 'overlays 没被渲染进 Stack');
      expect(foregroundIndex, isNonNegative, reason: '清晰前景没被渲染进 Stack');
      expect(
        blurIndex < overlayIndex,
        isTrue,
        reason: '遮罩必须压在模糊垫底之上，否则 hero 文字压在花背景上不可读',
      );
      expect(
        overlayIndex < foregroundIndex,
        isTrue,
        reason: '遮罩绝不能压在清晰海报之上——hero 底部渐变浓到 0xE8，会把海报'
            '下半截压成一片黑（等于换个方式毁掉海报）',
      );
    });
  });

  // 组件写对了，页面没接上去照样是坏的。这条锁调用点。
  test('合集详情页 hero 必须走 LandscapeCoverImage，不得回退裸 cover — BUG-1298', () {
    const String path =
        'lib/src/pages/implementations/media_collection_detail_page.dart';
    final String body = _functionSource(
      File(path).readAsStringSync(),
      'Widget _buildHero(',
    );

    expect(
      body,
      contains('LandscapeCoverImage('),
      reason: 'hero 封面必须经 LandscapeCoverImage 按朝向分流；直接 Image(...) '
          '会把 2:3 刮削海报裁成中间一条（BUG-1298）',
    );
    // 词边界不可省：`LandscapeCoverImage(` 本身就以 `Image(` 结尾，不加负向后行
    // 断言的话，正确写法只要把 `key:` 行删掉就会被误判成回归（变异实测抓到的）。
    expect(
      body,
      isNot(contains(RegExp(r'(?<![A-Za-z_])Image\(\s*image: cover'))),
      reason: 'hero 不得绕过 LandscapeCoverImage 直接渲染 cover——那正是 '
          'BUG-1298 的原始写法',
    );
    expect(
      body,
      contains('overlays: overlays'),
      reason: '两层可读性渐变必须作为 overlays 交给 LandscapeCoverImage 排层序，'
          '留在 hero 自己的 Stack 里会压黑竖版海报',
    );
  });
}

const ValueKey<String> _overlayKey = ValueKey<String>('test-overlay');

/// 把组件放进一个与真实 hero 同比例（2.7:1）的槽里 pump，并等图片解码完成。
Future<void> _pumpHero(WidgetTester tester, ImageProvider provider) async {
  // 先把图解码进 ImageCache（真实事件循环内），这样组件 resolve 时同步命中，
  // 首帧就能拿到固有尺寸，避免测试依赖「等几毫秒」这类时序偶然。
  await tester.runAsync(() => _awaitDecode(provider));

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 1080,
            height: 400,
            child: LandscapeCoverImage(
              image: provider,
              overlays: const <Widget>[
                DecoratedBox(
                  key: _overlayKey,
                  decoration: BoxDecoration(color: Color(0x52000000)),
                ),
              ],
              foregroundPadding: const EdgeInsetsDirectional.only(
                top: kToolbarHeight,
                bottom: 24,
                end: 16,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 是否存在一个采用 [fit] 的 [Image]（前景/垫底共用同一 provider，故按 fit 判定）。
bool _fitOfImageWith(WidgetTester tester, BoxFit fit) => tester
    .widgetList<Image>(find.byType(Image))
    .any((Image image) => image.fit == fit);

/// 解码 [provider] 并在首帧到达后完成（须在 `runAsync` 内调用）。
Future<void> _awaitDecode(ImageProvider provider) {
  final Completer<void> completer = Completer<void>();
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool _) {
      info.dispose();
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    },
    onError: (Object error, StackTrace? stackTrace) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.completeError(error);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// 生成 [w]×[h] 的实色 PNG 字节（须在 `runAsync` 内调用：走真实 GPU/IO 事件循环）。
Future<Uint8List> _solidPngBytes(WidgetTester tester, int w, int h) async {
  Uint8List? bytes;
  await tester.runAsync(() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFF3366AA),
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(w, h);
    final ByteData? data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    bytes = data!.buffer.asUint8List();
  });
  expect(bytes, isNotNull, reason: 'PNG 生成失败，测试无效');
  return bytes!;
}

/// 截取从 [startToken] 起到下一个顶层 `  Widget xxx(` 方法定义之前的源码片段。
String _functionSource(String source, String startToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final RegExp nextWidget = RegExp(r'\n  Widget [_A-Za-z0-9]+\(');
  final RegExpMatch? next = nextWidget.firstMatch(
    source.substring(start + startToken.length),
  );
  final int end =
      next == null ? source.length : start + startToken.length + next.start + 1;
  return source.substring(start, end);
}
