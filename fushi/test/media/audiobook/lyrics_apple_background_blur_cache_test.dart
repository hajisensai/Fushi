import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_apple.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/shared/lyrics_shell/lyrics_shell_backgrounds.dart';
import 'package:material_ui/material_ui.dart';

/// Apple 歌词页背景的两层整屏高斯模糊（sigma 36 / 48）只在输入变化时离屏算一次，
/// 之后当静态图合成：Impeller 没有栅格缓存，用 ImageFiltered 层时覆盖层每出一帧
/// 都要整屏重新模糊（手机发热、掉帧）。
class _FakeClock implements LyricsPlayerClock {
  @override
  Duration get position => Duration.zero;

  @override
  Duration get duration => const Duration(minutes: 1);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

LyricsPlayerData _data(ImageProvider? cover) => LyricsPlayerData(
  title: 't',
  cover: cover,
  isPlaying: true,
  speed: 1,
  lyricsMasked: false,
  clock: _FakeClock(),
);

/// 四色象限 + 斜条纹的测试封面（PNG 字节）。
Future<Uint8List> _coverPng(Color a, Color b) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const double w = 200;
  const double h = 300;
  canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = a);
  canvas.drawRect(
    const Rect.fromLTWH(w / 2, 0, w / 2, h / 2),
    Paint()..color = b,
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, h / 2, w / 2, h / 2),
    Paint()..color = const Color(0xFFE0C020),
  );
  for (int i = 0; i < 6; i++) {
    canvas.drawLine(
      Offset(i * 40.0, 0),
      Offset(i * 40.0 + 120, h),
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..strokeWidth = 8,
    );
  }
  final ui.Image image = await recorder.endRecording().toImage(
    w.toInt(),
    h.toInt(),
  );
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

/// 宿主：背景 + 一个高频变化的兄弟（模拟进度条 / 换句动画让覆盖层每帧重建）。
class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.cover,
    required this.boundaryKey,
    this.accent = Colors.blue,
  });

  final ImageProvider? cover;
  final GlobalKey boundaryKey;
  final Color accent;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int tick = 0;

  void bump() => setState(() => tick++);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: widget.accent),
      ),
      home: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          RepaintBoundary(
            key: widget.boundaryKey,
            child: Builder(
              builder: (BuildContext context) =>
                  // 每次重建都换一个新的设计实例（与覆盖层的 mirror 补间同形）。
                  AppleLyricsPlayerDesign(
                    mirrorProgress: tick / 1000,
                  ).buildBackground(context, _data(widget.cover)),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 10.0 + tick % 50,
              height: 4,
              child: const ColoredBox(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// 改造前的背景（ImageFiltered 层），只用于像素对照。
class _LegacyBackground extends StatelessWidget {
  const _LegacyBackground({required this.cover});

  final ImageProvider cover;

  static List<double> _matrix(double saturation, double opacity) {
    const double lr = 0.2126;
    const double lg = 0.7152;
    const double lb = 0.0722;
    final double inv = 1 - saturation;
    return <double>[
      lr * inv + saturation, lg * inv, lb * inv, 0, 0, //
      lr * inv, lg * inv + saturation, lb * inv, 0, 0, //
      lr * inv, lg * inv, lb * inv + saturation, 0, 0, //
      0, 0, 0, opacity, 0, //
    ];
  }

  Widget _blurred(double sigma, double sat, double op, TileMode mode) =>
      ColorFiltered(
        colorFilter: ColorFilter.matrix(_matrix(sat, op)),
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: mode,
          ),
          child: Image(
            image: ResizeImage.resizeIfNeeded(160, null, cover),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            const ColoredBox(color: Colors.black),
            Positioned(
              left: -w * 0.125,
              top: -h * 0.125,
              width: w * 1.25,
              height: h * 1.25,
              child: _blurred(36, 1.6, 0.6, TileMode.clamp),
            ),
            Positioned(
              left: w * 0.05 + w * 0.24,
              top: h * 0.05 + h * 0.2,
              width: w * 0.9,
              height: h * 0.9,
              child: Transform.rotate(
                angle: math.pi,
                child: _blurred(48, 1.5, 0.38, TileMode.decal),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.black.withValues(alpha: 0.2),
                    Colors.black.withValues(alpha: 0.46),
                    Colors.black.withValues(alpha: 0.74),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

void main() {
  late List<ui.Image> rendered;

  setUp(() {
    rendered = <ui.Image>[];
    LyricsShellAppleBackground.debugOnBlurredBackgroundRendered = rendered.add;
  });

  tearDown(() {
    LyricsShellAppleBackground.debugOnBlurredBackgroundRendered = null;
  });

  /// 让真实图片解码跑完（解码走引擎异步回调，fake async 里推不动）。
  Future<void> settleDecode(WidgetTester tester, bool Function() done) async {
    for (int i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done(), isTrue, reason: '封面解码没有在时限内完成');
  }

  testWidgets('覆盖层其它部分反复重绘时模糊只算一次；输入变化才重算；图片按时释放', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    final Uint8List bytesA = (await tester.runAsync(
      () => _coverPng(const Color(0xFF2050D0), const Color(0xFFD03040)),
    ))!;
    final Uint8List bytesB = (await tester.runAsync(
      () => _coverPng(const Color(0xFF20A060), const Color(0xFF8030C0)),
    ))!;
    final MemoryImage coverA = MemoryImage(bytesA);
    final MemoryImage coverB = MemoryImage(bytesB);
    final GlobalKey boundary = GlobalKey();
    final GlobalKey<_HostState> host = GlobalKey<_HostState>();

    Future<void> pumpHost(ImageProvider? cover, {Color accent = Colors.blue}) =>
        tester.pumpWidget(
          _Host(key: host, cover: cover, boundaryKey: boundary, accent: accent),
        );

    await pumpHost(coverA);
    await settleDecode(tester, () => rendered.isNotEmpty);
    expect(rendered, hasLength(1));
    expect(
      find.byKey(const ValueKey<String>('lyrics_apple_blurred_cover')),
      findsOneWidget,
    );
    // 背景里不再有任何每帧执行的模糊层。
    expect(find.byType(ImageFiltered), findsNothing);

    // 覆盖层 60 帧重建 + 重绘（进度条、补间），模糊一次都不重算。
    for (int i = 0; i < 60; i++) {
      host.currentState!.bump();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(rendered, hasLength(1), reason: '输入没变，不得重新模糊');
    final ui.Image first = rendered.single;
    expect(first.debugDisposed, isFalse);

    // 配色 / 主题变化：不影响有封面时的模糊层，不重算。
    await pumpHost(coverA, accent: Colors.orange);
    await tester.pump();
    expect(rendered, hasLength(1));

    // 窗口尺寸变化：重算一次，旧图释放。
    tester.view.physicalSize = const Size(1280, 760);
    await tester.pump();
    expect(rendered, hasLength(2));
    expect(first.debugDisposed, isTrue);
    expect(rendered[1].width, 1280);
    expect(rendered[1].height, 760);

    // DPR 变化：按新物理像素重算。
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(2560, 1520);
    await tester.pump();
    expect(rendered, hasLength(3));
    expect(rendered[1].debugDisposed, isTrue);
    expect(rendered[2].width, 2560);

    // 换封面：新图解码完成前保留旧快照（不闪黑），完成后重算一次。
    await pumpHost(coverB);
    expect(rendered, hasLength(3));
    expect(rendered[2].debugDisposed, isFalse, reason: '新封面解码前不闪黑');
    await settleDecode(tester, () => rendered.length == 4);
    expect(rendered[2].debugDisposed, isTrue);
    for (int i = 0; i < 10; i++) {
      host.currentState!.bump();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(rendered, hasLength(4));

    // 封面去掉：快照释放，回到配色渐变底。
    await pumpHost(null);
    await tester.pump();
    expect(rendered[3].debugDisposed, isTrue);
    expect(
      find.byKey(const ValueKey<String>('lyrics_apple_blurred_cover')),
      findsNothing,
    );

    // 再放回封面后卸载：所有快照都已释放。
    await pumpHost(coverA);
    await settleDecode(tester, () => rendered.length == 5);
    await tester.pumpWidget(const SizedBox());
    for (final ui.Image image in rendered) {
      expect(image.debugDisposed, isTrue);
    }
  });

  testWidgets('封面解码失败：与原实现一致只剩黑底，不产出快照', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final GlobalKey boundary = GlobalKey();
    await tester.pumpWidget(
      _Host(
        cover: MemoryImage(Uint8List.fromList(<int>[1, 2, 3, 4])),
        boundaryKey: boundary,
      ),
    );
    for (int i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    tester.takeException();
    expect(rendered, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('lyrics_apple_blurred_cover')),
      findsNothing,
    );
  });

  for (final double dpr in <double>[1, 2]) {
    testWidgets('像素对照：离屏快照与原 ImageFiltered 实现一致（DPR $dpr）', (
      WidgetTester tester,
    ) async {
      const Size logical = Size(390, 600);
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = logical * dpr;
      addTearDown(tester.view.reset);
      final Uint8List bytes = (await tester.runAsync(
        () => _coverPng(const Color(0xFF2050D0), const Color(0xFFD03040)),
      ))!;
      final MemoryImage cover = MemoryImage(bytes);

      // 设了 FUSHI_LYRICS_BG_DUMP_DIR 时把两份像素存成 PNG，供人眼前后对照。
      final String? dumpDir = Platform.environment['FUSHI_LYRICS_BG_DUMP_DIR'];

      Future<Uint8List> capture(
        Widget child,
        bool Function() ready,
        String name,
      ) async {
        final GlobalKey key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(key: key, child: child),
          ),
        );
        await settleDecode(tester, ready);
        // 原实现的 Image 解码完后还要一帧才画上。
        await tester.pump();
        final RenderRepaintBoundary boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final Uint8List? rgba = await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage(pixelRatio: dpr);
          final ByteData? data = await image.toByteData();
          if (dumpDir != null) {
            final ByteData? png = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '$dumpDir/lyrics_bg_${name}_dpr${dpr.toInt()}.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          }
          image.dispose();
          return data!.buffer.asUint8List();
        });
        return rgba!;
      }

      final Uint8List legacy = await capture(
        _LegacyBackground(cover: cover),
        () =>
            tester.any(find.byType(RawImage)) &&
            tester
                .widgetList<RawImage>(find.byType(RawImage))
                .every((RawImage r) => r.image != null),
        'legacy',
      );
      final Uint8List current = await capture(
        Builder(
          builder: (BuildContext context) => const AppleLyricsPlayerDesign()
              .buildBackground(context, _data(cover)),
        ),
        () => rendered.isNotEmpty,
        'cached',
      );
      expect(current.length, legacy.length);
      int maxDiff = 0;
      int sumDiff = 0;
      for (int i = 0; i < legacy.length; i++) {
        final int d = (legacy[i] - current[i]).abs();
        sumDiff += d;
        if (d > maxDiff) maxDiff = d;
      }
      final double meanDiff = sumDiff / legacy.length;
      // ignore: avoid_print
      print('DPR $dpr pixel diff: max=$maxDiff mean=$meanDiff');
      expect(maxDiff, lessThanOrEqualTo(3));
      expect(meanDiff, lessThan(0.5));
    });
  }
}
