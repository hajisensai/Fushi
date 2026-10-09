// 2026-10 UI / 动效重做的效果图渲染器。
//
// 这不是回归测试：它用**真实的生产组件与主题工厂**（buildFushiThemeData、
// adaptiveNavRail / adaptiveBottomBar、FushiCard、FushiListItem、
// FushiSharedAxisPageTransitionsBuilder、FushiPressScale、FushiStaggeredEntrance）在 flutter
// test 的离屏光栅里画出静态效果图与动效分帧胶片，写成 PNG。
//
// 默认 skip；只有设了 `FUSHI_DESIGN_PREVIEW_OUT=<输出目录>` 才运行。入口脚本
// `tool/design_preview/render_previews.sh`（另有 .ps1）负责设环境变量、跑本文件、
// 再用 ffmpeg / ImageMagick（可选）把分帧拼成 GIF。
//
// 字体：flutter test 默认用 Ahem 方块字，效果图必须换真字体。拉丁字用 Flutter SDK
// 自带的 Roboto（`bin/cache/artifacts/material_fonts/`），CJK 依次探测
// `FUSHI_PREVIEW_CJK_FONT` / Linux Noto CJK / Windows 微软雅黑 / macOS 苹方。
@Tags(<String>['design-preview'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';

final String? _outDir = Platform.environment['FUSHI_DESIGN_PREVIEW_OUT'];

const String _latinFamily = 'FushiPreview';
const String _cjkFamily = 'FushiPreviewCJK';

void main() {
  if (_outDir == null || _outDir!.isEmpty) {
    test(
      'design preview（未设 FUSHI_DESIGN_PREVIEW_OUT，跳过）',
      () {},
      skip: 'set FUSHI_DESIGN_PREVIEW_OUT to render previews',
    );
    return;
  }
  final Directory out = Directory(_outDir!)..createSync(recursive: true);

  setUpAll(() async {
    await _loadFonts();
  });

  for (final Brightness brightness in Brightness.values) {
    final String tag = brightness == Brightness.light ? 'light' : 'dark';

    testWidgets('desktop library ($tag)', (WidgetTester tester) async {
      await _capture(
        tester,
        File('${out.path}/01_desktop_library_$tag.png'),
        size: const Size(1280, 800),
        brightness: brightness,
        child: const _DesktopLibraryScene(),
      );
    });

    testWidgets('mobile library ($tag)', (WidgetTester tester) async {
      await _capture(
        tester,
        File('${out.path}/02_mobile_library_$tag.png'),
        size: const Size(390, 844),
        brightness: brightness,
        platform: TargetPlatform.android,
        child: const _MobileLibraryScene(),
      );
    });

    testWidgets('components ($tag)', (WidgetTester tester) async {
      await _capture(
        tester,
        File('${out.path}/03_components_$tag.png'),
        size: const Size(960, 640),
        brightness: brightness,
        child: const _ComponentsScene(),
      );
    });
  }

  testWidgets('motion: nav pill', (WidgetTester tester) async {
    await _captureNavPillFilmstrip(
      tester,
      File('${out.path}/10_motion_nav_pill.png'),
      frameDir: Directory('${out.path}/frames/nav_pill'),
    );
  });

  testWidgets('motion: page transition', (WidgetTester tester) async {
    await _capturePageTransitionFilmstrip(
      tester,
      File('${out.path}/11_motion_page_transition.png'),
      frameDir: Directory('${out.path}/frames/page_transition'),
    );
  });

  testWidgets('motion: press', (WidgetTester tester) async {
    await _capturePressFilmstrip(
      tester,
      File('${out.path}/12_motion_press.png'),
      frameDir: Directory('${out.path}/frames/press'),
    );
  });

  testWidgets('motion: staggered entrance', (WidgetTester tester) async {
    await _captureStaggerFilmstrip(
      tester,
      File('${out.path}/13_motion_stagger.png'),
      frameDir: Directory('${out.path}/frames/stagger'),
    );
  });

  testWidgets('motion: curves', (WidgetTester tester) async {
    await _capture(
      tester,
      File('${out.path}/14_motion_curves.png'),
      size: const Size(960, 360),
      brightness: Brightness.light,
      child: const _CurvesScene(),
    );
  });
}

// ───────────────────────────── 基础设施 ─────────────────────────────

Future<void> _loadFonts() async {
  final String? flutterRoot = _flutterRoot();
  final List<String> latin = <String>[
    if (flutterRoot != null)
      for (final String w in <String>['Regular', 'Medium', 'Bold'])
        '$flutterRoot/bin/cache/artifacts/material_fonts/Roboto-$w.ttf',
  ];
  final FontLoader latinLoader = FontLoader(_latinFamily);
  for (final String path in latin) {
    if (File(path).existsSync()) {
      latinLoader.addFont(_bytes(path));
    }
  }
  await latinLoader.load();

  final String? cjk = _findCjkFont();
  if (cjk != null) {
    final FontLoader cjkLoader = FontLoader(_cjkFamily)..addFont(_bytes(cjk));
    await cjkLoader.load();
  } else {
    // ignore: avoid_print
    print(
      '[design-preview] 找不到 CJK 字体，中文会显示为方块；'
      '设 FUSHI_PREVIEW_CJK_FONT=<ttf/otf/ttc 路径>',
    );
  }

  if (flutterRoot != null) {
    final String icons =
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(icons).existsSync()) {
      final FontLoader iconLoader = FontLoader('MaterialIcons')
        ..addFont(_bytes(icons));
      await iconLoader.load();
    }
  }
}

Future<ByteData> _bytes(String path) async =>
    ByteData.sublistView(File(path).readAsBytesSync());

String? _flutterRoot() {
  final String? env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && Directory(env).existsSync()) return env;
  // flutter_tester 位于 <root>/bin/cache/artifacts/engine/<platform>/。
  Directory dir = File(Platform.resolvedExecutable).parent;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/bin/flutter').existsSync()) return dir.path;
    dir = dir.parent;
  }
  return null;
}

String? _findCjkFont() {
  final List<String> candidates = <String>[
    if (Platform.environment['FUSHI_PREVIEW_CJK_FONT'] case final String p) p,
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc',
    r'C:\Windows\Fonts\msyh.ttc',
    r'C:\Windows\Fonts\YuGothM.ttc',
    '/System/Library/Fonts/PingFang.ttc',
    '/System/Library/Fonts/Hiragino Sans GB.ttc',
  ];
  for (final String path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

ThemeData _theme(Brightness brightness, {TargetPlatform? platform}) {
  final ThemeData base = buildFushiThemeData(
    scheme: buildFushiColorScheme(
      seedColor: kFushiDefaultSeed,
      brightness: brightness,
    ),
    textTheme: FushiTypeScale.buildTextTheme(
      const TextStyle(
        fontFamily: _latinFamily,
        fontFamilyFallback: <String>[_cjkFamily],
      ),
    ),
  );
  return base.copyWith(platform: platform ?? TargetPlatform.windows);
}

Widget _app(
  Widget child, {
  required Brightness brightness,
  TargetPlatform? platform,
  Key? boundaryKey,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _theme(brightness, platform: platform),
    home: RepaintBoundary(
      key: boundaryKey,
      child: FushiFocusRoot(child: child),
    ),
  );
}

Future<void> _setView(WidgetTester tester, Size size, double dpr) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = size * dpr;
  addTearDown(tester.view.reset);
}

Future<ui.Image> _grab(WidgetTester tester, Key key, double dpr) async {
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(key));
  return (await tester.runAsync(() => boundary.toImage(pixelRatio: dpr)))!;
}

Future<void> _writePng(WidgetTester tester, ui.Image image, File file) async {
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(data!.buffer.asUint8List());
}

Future<void> _capture(
  WidgetTester tester,
  File file, {
  required Size size,
  required Brightness brightness,
  required Widget child,
  TargetPlatform? platform,
  double dpr = 2,
}) async {
  await _setView(tester, size, dpr);
  const Key key = ValueKey<String>('preview-boundary');
  await tester.pumpWidget(
    _app(child, brightness: brightness, platform: platform, boundaryKey: key),
  );
  await tester.pumpAndSettle();
  final ui.Image image = await _grab(tester, key, dpr);
  await _writePng(tester, image, file);
}

/// 把若干帧横向拼成一张胶片，帧下标注时间；同时把每帧单独写进 [frameDir]
/// 供脚本合成 GIF。
Future<void> _writeFilmstrip(
  WidgetTester tester, {
  required List<ui.Image> frames,
  required List<String> labels,
  required File file,
  required Directory frameDir,
  required Color background,
  required Color labelColor,
  String? title,
}) async {
  frameDir.createSync(recursive: true);
  for (int i = 0; i < frames.length; i++) {
    await _writePng(
      tester,
      frames[i],
      File('${frameDir.path}/${i.toString().padLeft(3, '0')}.png'),
    );
  }
  const double gap = 24;
  const double labelHeight = 56;
  final double titleHeight = title == null ? 0 : 72;
  final double fw = frames.first.width.toDouble();
  final double fh = frames.first.height.toDouble();
  final double width = gap + frames.length * (fw + gap);
  final double height = titleHeight + gap + fh + labelHeight;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = background,
  );
  void text(String s, Offset at, double size, FontWeight weight) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontFamily: _latinFamily,
          fontFamilyFallback: const <String>[_cjkFamily],
          fontSize: size,
          fontWeight: weight,
          color: labelColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  if (title != null) text(title, const Offset(gap, gap), 30, FontWeight.w600);
  for (int i = 0; i < frames.length; i++) {
    final double x = gap + i * (fw + gap);
    canvas.drawImage(frames[i], Offset(x, titleHeight + gap), Paint());
    text(
      labels[i],
      Offset(x, titleHeight + gap + fh + 12),
      24,
      FontWeight.w500,
    );
  }
  final ui.Image strip =
      await tester.runAsync(
            () =>
                recorder.endRecording().toImage(width.round(), height.round()),
          )
          as ui.Image;
  await _writePng(tester, strip, file);
}

// ───────────────────────────── 示例数据 ─────────────────────────────

class _Book {
  const _Book(this.title, this.author, this.glyph, this.hue, this.progress);

  final String title;
  final String author;
  final String glyph;
  final double hue;
  final double progress;
}

const List<_Book> _books = <_Book>[
  _Book('夜のピクニック', '恩田 陸', '夜', 230, 0.62),
  _Book('コンビニ人間', '村田 沙耶香', '店', 150, 1),
  _Book('博士の愛した数式', '小川 洋子', '数', 30, 0.18),
  _Book('キッチン', '吉本 ばなな', '台', 350, 0.4),
  _Book('ノルウェイの森', '村上 春樹', '森', 110, 0),
  _Book('雪国', '川端 康成', '雪', 200, 0.85),
  _Book('こころ', '夏目 漱石', '心', 280, 0.05),
  _Book('羅生門', '芥川 龍之介', '門', 15, 0),
  _Book('銀河鉄道の夜', '宮沢 賢治', '星', 255, 0.33),
  _Book('舟を編む', '三浦 しをん', '舟', 190, 0.71),
  _Book('火花', '又吉 直樹', '火', 5, 0),
  _Book('蜜蜂と遠雷', '恩田 陸', '音', 45, 0.12),
];

const List<AdaptiveNavItem> _navItems = <AdaptiveNavItem>[
  AdaptiveNavItem(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: '首页',
  ),
  AdaptiveNavItem(
    icon: Icons.menu_book_outlined,
    selectedIcon: Icons.menu_book,
    label: '书架',
  ),
  AdaptiveNavItem(
    icon: Icons.video_library_outlined,
    selectedIcon: Icons.video_library,
    label: '视频',
  ),
  AdaptiveNavItem(
    icon: Icons.sports_esports_outlined,
    selectedIcon: Icons.sports_esports,
    label: '游戏',
  ),
  AdaptiveNavItem(
    icon: Icons.translate_outlined,
    selectedIcon: Icons.translate,
    label: '词典',
  ),
  AdaptiveNavItem(
    icon: Icons.explore_outlined,
    selectedIcon: Icons.explore,
    label: '浏览',
  ),
];

/// 程序生成的封面：HSL 渐变 + 大号汉字 + 细标题，不依赖任何图片资源。
class _Cover extends StatelessWidget {
  const _Cover({required this.book});

  final _Book book;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color a = HSLColor.fromAHSL(
      1,
      book.hue,
      0.45,
      dark ? 0.32 : 0.62,
    ).toColor();
    final Color b = HSLColor.fromAHSL(
      1,
      (book.hue + 40) % 360,
      0.5,
      dark ? 0.18 : 0.42,
    ).toColor();
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: FushiBorderRadius.card,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[a, b],
        ),
      ),
      child: Stack(
        children: <Widget>[
          Positioned(
            right: -8,
            bottom: -18,
            child: Text(
              book.glyph,
              style: TextStyle(
                fontSize: 96,
                height: 1,
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.22),
              ),
            ),
          ),
          Positioned(
            left: 12,
            top: 12,
            right: 12,
            child: Text(
              book.title,
              maxLines: 3,
              style: const TextStyle(
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({required this.book, this.width = 148});

  final _Book book;
  final double width;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 2 / 3,
            child: FushiPressScale(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: FushiBorderRadius.card,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: cs.shadow.withValues(alpha: 0.12),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _Cover(book: book),
                    if (book.progress > 0)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 8,
                        child: LinearProgressIndicator(
                          value: book.progress,
                          minHeight: 4,
                          color: Colors.white,
                          stopIndicatorColor: Colors.transparent,
                          backgroundColor: Colors.white.withValues(alpha: 0.3),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.listTitle.copyWith(fontSize: 14),
          ),
          Text(
            book.progress >= 1
                ? '${book.author} · 已读完'
                : book.progress > 0
                ? '${book.author} · ${(book.progress * 100).round()}%'
                : book.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.metadata,
          ),
        ],
      ),
    );
  }
}

class _ContinueHero extends StatelessWidget {
  const _ContinueHero({required this.book, this.compact = false});

  final _Book book;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    return FushiCard(
      color: cs.primaryContainer,
      onTap: () {},
      padding: EdgeInsets.all(compact ? 14 : 18),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: compact ? 56 : 72,
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: _Cover(book: book),
            ),
          ),
          SizedBox(width: compact ? 14 : 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '继续阅读',
                  style: tt.labelLarge?.copyWith(
                    color: cs.onPrimaryContainer.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (compact ? tt.titleMedium : tt.titleLarge)?.copyWith(
                    color: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(value: book.progress),
                const SizedBox(height: 6),
                Text(
                  '第 7 章 · 剩余约 42 分钟',
                  style: tt.labelMedium?.copyWith(
                    color: cs.onPrimaryContainer.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          if (!compact) ...<Widget>[
            const SizedBox(width: 18),
            FilledButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('继续'),
            ),
          ],
        ],
      ),
    );
  }
}

// ───────────────────────────── 静态场景 ─────────────────────────────

class _DesktopLibraryScene extends StatelessWidget {
  const _DesktopLibraryScene();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Scaffold(
      backgroundColor: cs.surface,
      body: Row(
        children: <Widget>[
          Builder(
            builder: (BuildContext context) => adaptiveNavRail(
              context: context,
              currentIndex: 1,
              onTap: (_) {},
              items: _navItems,
              leading: Padding(
                padding: const EdgeInsets.only(top: 20, bottom: 8),
                child: Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: FushiBorderRadius.control,
                  ),
                  child: Text(
                    '伏',
                    style: tt.titleLarge?.copyWith(color: cs.onPrimary),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ColoredBox(
              color: cs.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 28, 32, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text('书架', style: tokens.type.pageTitle),
                        const SizedBox(width: 12),
                        Text('128 本', style: tokens.type.metadata),
                        const Spacer(),
                        SizedBox(
                          width: 260,
                          child: TextField(
                            decoration: InputDecoration(
                              isDense: true,
                              prefixIcon: const Icon(Icons.search, size: 20),
                              hintText: '搜索书名、作者',
                              filled: true,
                              fillColor: tokens.surfaces.search,
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          onPressed: () {},
                          icon: const Icon(Icons.tune),
                        ),
                        const SizedBox(width: 4),
                        Tooltip(
                          message: '导入',
                          child: IconButton.filled(
                            onPressed: () {},
                            icon: const Icon(Icons.add),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        for (final (String label, bool on) in <(String, bool)>[
                          ('全部', true),
                          ('在读', false),
                          ('已读完', false),
                          ('有声书', false),
                          ('#轻小说', false),
                        ])
                          FilterChip(
                            label: Text(label),
                            selected: on,
                            onSelected: (_) {},
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _ContinueHero(book: _books[0]),
                    const SizedBox(height: 24),
                    Text('最近添加', style: tt.titleMedium),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ClipRect(
                        child: Wrap(
                          spacing: 20,
                          runSpacing: 20,
                          children: <Widget>[
                            for (final _Book book in _books.skip(1))
                              _BookCard(book: book),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileLibraryScene extends StatelessWidget {
  const _MobileLibraryScene();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Scaffold(
      backgroundColor: cs.surface,
      bottomNavigationBar: Builder(
        builder: (BuildContext context) => adaptiveBottomBar(
          context: context,
          currentIndex: 1,
          onTap: (_) {},
          items: _navItems.take(5).toList(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('书架', style: tokens.type.pageTitle),
                  const Spacer(),
                  IconButton(onPressed: () {}, icon: const Icon(Icons.search)),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.more_vert),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _ContinueHero(book: _books[5], compact: true),
              const SizedBox(height: 16),
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const <ButtonSegment<int>>[
                  ButtonSegment<int>(value: 0, label: Text('网格')),
                  ButtonSegment<int>(value: 1, label: Text('列表')),
                  ButtonSegment<int>(value: 2, label: Text('合集')),
                ],
                selected: const <int>{0},
                onSelectionChanged: (_) {},
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ClipRect(
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints c) {
                      const double spacing = 14;
                      final double w = (c.maxWidth - spacing * 2) / 3;
                      return Wrap(
                        spacing: spacing,
                        runSpacing: 16,
                        children: <Widget>[
                          for (final _Book book in _books.skip(1).take(9))
                            _BookCard(book: book, width: w),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComponentsScene extends StatelessWidget {
  const _ComponentsScene();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    Widget section(String title, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: tokens.type.sectionLabel),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
    return Scaffold(
      backgroundColor: cs.surface,
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('组件', style: tokens.type.pageTitle),
                  const SizedBox(height: 18),
                  section(
                    '按钮',
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        FilledButton(
                          onPressed: () {},
                          child: const Text('导入书籍'),
                        ),
                        FilledButton.tonal(
                          onPressed: () {},
                          child: const Text('同步'),
                        ),
                        OutlinedButton(
                          onPressed: () {},
                          child: const Text('取消'),
                        ),
                        TextButton(onPressed: () {}, child: const Text('了解更多')),
                      ],
                    ),
                  ),
                  section(
                    '筛选与分段',
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Wrap(
                          spacing: 8,
                          children: <Widget>[
                            FilterChip(
                              label: const Text('N1'),
                              selected: true,
                              onSelected: (_) {},
                            ),
                            FilterChip(
                              label: const Text('N2'),
                              selected: false,
                              onSelected: (_) {},
                            ),
                            FilterChip(
                              label: const Text('常用'),
                              selected: false,
                              onSelected: (_) {},
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SegmentedButton<int>(
                          showSelectedIcon: false,
                          segments: const <ButtonSegment<int>>[
                            ButtonSegment<int>(value: 0, label: Text('翻页')),
                            ButtonSegment<int>(value: 1, label: Text('滚动')),
                            ButtonSegment<int>(value: 2, label: Text('视觉小说')),
                          ],
                          selected: const <int>{0},
                          onSelectionChanged: (_) {},
                        ),
                      ],
                    ),
                  ),
                  section(
                    '进度（M3 2024 样式）',
                    const SizedBox(
                      width: 360,
                      child: Column(
                        children: <Widget>[
                          LinearProgressIndicator(value: 0.64),
                          SizedBox(height: 14),
                          LinearProgressIndicator(value: 0.2),
                        ],
                      ),
                    ),
                  ),
                  section(
                    '浮层',
                    Row(
                      children: <Widget>[
                        _StaticTooltip(text: '添加到 Anki（Ctrl+E）'),
                        const SizedBox(width: 16),
                        Material(
                          color: cs.inverseSurface,
                          shape: RoundedRectangleBorder(
                            borderRadius: FushiBorderRadius.card,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                            child: Row(
                              children: <Widget>[
                                Text(
                                  '已加入书架',
                                  style: tt.bodyMedium?.copyWith(
                                    color: cs.onInverseSurface,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                TextButton(
                                  onPressed: () {},
                                  style: TextButton.styleFrom(
                                    foregroundColor: cs.inversePrimary,
                                  ),
                                  child: const Text('撤销'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 28),
            SizedBox(
              width: 340,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(height: 46),
                  FushiCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        FushiListItem(
                          leading: const Icon(Icons.palette_outlined),
                          title: const Text('主题'),
                          subtitle: const Text('跟随系统 · 默认色'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {},
                        ),
                        FushiListItem(
                          leading: const Icon(Icons.animation_outlined),
                          title: const Text('减弱动态效果'),
                          subtitle: const Text('跟随系统无障碍设置'),
                          trailing: Switch(value: true, onChanged: (_) {}),
                          onTap: () {},
                        ),
                        FushiListItem(
                          leading: const Icon(Icons.vibration),
                          title: const Text('触感反馈'),
                          subtitle: const Text('切换页签时轻震'),
                          trailing: Switch(value: false, onChanged: (_) {}),
                          onTap: () {},
                        ),
                        FushiListItem(
                          leading: const Icon(Icons.language),
                          title: const Text('界面语言'),
                          trailing: const Text('简体中文'),
                          onTap: () {},
                          selected: true,
                          selectedShape: FushiListItemSelectedShape.pill,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    decoration: InputDecoration(
                      labelText: 'AnkiConnect 地址',
                      hintText: 'http://127.0.0.1:8765',
                      filled: true,
                      fillColor: cs.surfaceContainerLow,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// [Tooltip] 只在悬停后才出现，这里按主题的 tooltipTheme 静态画一个。
class _StaticTooltip extends StatelessWidget {
  const _StaticTooltip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final TooltipThemeData theme = TooltipTheme.of(context);
    return Container(
      padding: theme.padding,
      decoration: theme.decoration,
      child: Text(text, style: theme.textStyle),
    );
  }
}

class _CurvesScene extends StatelessWidget {
  const _CurvesScene();

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    final List<(String, Curve, Duration)> curves = <(String, Curve, Duration)>[
      ('enter · 临界阻尼弹簧', FushiMotion.enter, FushiMotion.long),
      (
        'exit · emphasizedAccelerate',
        FushiMotion.exit,
        FushiMotion.longReverse,
      ),
      ('standard', FushiMotion.standard, FushiMotion.short),
      ('release · spatial fast 弹簧回弹', FushiMotion.release, FushiMotion.short),
    ];
    return Scaffold(
      backgroundColor: cs.surface,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('动效曲线与时长（FushiMotion）', style: tt.titleLarge),
            const SizedBox(height: 16),
            Expanded(
              child: Row(
                children: <Widget>[
                  for (final (String name, Curve curve, Duration d) in curves)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: FushiCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(
                                child: CustomPaint(
                                  painter: _CurvePainter(
                                    curve: curve,
                                    color: cs.primary,
                                    grid: cs.outlineVariant,
                                  ),
                                  child: const SizedBox.expand(),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(name, style: tt.labelLarge, maxLines: 2),
                              Text(
                                '${d.inMilliseconds} ms',
                                style: tt.labelMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({required this.curve, required this.color, required this.grid});

  final Curve curve;
  final Color color;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint g = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final double top = size.height * 0.1;
    final double bottom = size.height * 0.9;
    canvas.drawLine(Offset(0, bottom), Offset(size.width, bottom), g);
    canvas.drawLine(Offset(0, top), Offset(size.width, top), g);
    final Path path = Path();
    for (int i = 0; i <= 100; i++) {
      final double t = i / 100;
      final double v = curve.transform(t);
      final Offset p = Offset(t * size.width, bottom - v * (bottom - top));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter oldDelegate) =>
      curve != oldDelegate.curve || color != oldDelegate.color;
}

// ───────────────────────────── 动效胶片 ─────────────────────────────

/// 底栏从「首页」切到「书架」：药丸横向展开、图标交叉淡化。
Future<void> _captureNavPillFilmstrip(
  WidgetTester tester,
  File file, {
  required Directory frameDir,
}) async {
  const double dpr = 3;
  const Size size = Size(180, 72);
  await _setView(tester, size, dpr);
  const Key key = ValueKey<String>('nav-boundary');
  final ValueNotifier<int> index = ValueNotifier<int>(0);
  addTearDown(index.dispose);
  await tester.pumpWidget(
    _app(
      ValueListenableBuilder<int>(
        valueListenable: index,
        builder: (BuildContext context, int i, _) => Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Builder(
              builder: (BuildContext context) => adaptiveBottomBar(
                context: context,
                currentIndex: i,
                onTap: (_) {},
                items: _navItems.take(2).toList(),
              ),
            ),
          ),
        ),
      ),
      brightness: Brightness.light,
      platform: TargetPlatform.android,
      boundaryKey: key,
    ),
  );
  await tester.pumpAndSettle();
  index.value = 1;
  final List<ui.Image> frames = <ui.Image>[];
  final List<String> labels = <String>[];
  const int step = 30;
  for (int ms = 0; ms <= 210; ms += step) {
    await tester.pump(
      ms == 0 ? Duration.zero : const Duration(milliseconds: step),
    );
    frames.add(await _grab(tester, key, dpr));
    labels.add('${ms}ms');
  }
  final ColorScheme cs = _theme(Brightness.light).colorScheme;
  await _writeFilmstrip(
    tester,
    frames: frames,
    labels: labels,
    file: file,
    frameDir: frameDir,
    background: cs.surfaceContainerHighest,
    labelColor: cs.onSurface,
    title: '底栏选中药丸：32→64 横向展开 + 图标交叉淡化（${FushiMotion.short.inMilliseconds}ms）',
  );
}

/// 桌面 push：新的共享轴转场 vs 旧 Zoom 转场，真实 `Navigator.push` 逐帧采样，
/// 上下两行同一时刻对照。
Future<void> _capturePageTransitionFilmstrip(
  WidgetTester tester,
  File file, {
  required Directory frameDir,
}) async {
  const double dpr = 1;
  const Size size = Size(480, 300);
  await _setView(tester, size, dpr);
  const Key key = ValueKey<String>('page-boundary');

  Widget page(String title, Color tint, IconData icon, int rows) => Builder(
    builder: (BuildContext context) {
      final TextTheme tt = Theme.of(context).textTheme;
      final ColorScheme cs = Theme.of(context).colorScheme;
      return Material(
        color: cs.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              height: 56,
              color: tint.withValues(alpha: 0.16),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: <Widget>[
                  Icon(icon, color: tint),
                  const SizedBox(width: 10),
                  Text(title, style: tt.titleLarge),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < rows; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        height: 30,
                        decoration: BoxDecoration(
                          color: tint.withValues(alpha: 0.10 + i * 0.05),
                          borderRadius: FushiBorderRadius.card,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  const int frameCount = 7;
  final List<String> labels = <String>[
    for (int i = 0; i < frameCount; i++)
      '${(i * FushiMotion.long.inMilliseconds / (frameCount - 1)).round()}ms',
  ];
  final List<List<ui.Image>> rows = <List<ui.Image>>[];
  for (final bool useNew in <bool>[true, false]) {
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    ThemeData theme = _theme(Brightness.light);
    if (!useNew) {
      theme = theme.copyWith(
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          },
        ),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        builder: (BuildContext context, Widget? child) =>
            RepaintBoundary(key: key, child: child),
        navigatorKey: nav,
        home: page('书架', Colors.indigo, Icons.menu_book, 5),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              page('夜のピクニック', Colors.teal, Icons.article_outlined, 3),
        ),
      ),
    );
    // Zoom 的时长是 300ms（Flutter 默认），新转场 360ms；两行都按各自时长等分
    // 采样，标签按新转场标注，对照的是「转场进行到第几成」。
    final Duration total = useNew
        ? FushiMotion.long
        : const Duration(milliseconds: 300);
    final List<ui.Image> frames = <ui.Image>[];
    await tester.pump();
    frames.add(await _grab(tester, key, dpr));
    for (int i = 1; i < frameCount; i++) {
      await tester.pump(total ~/ (frameCount - 1));
      frames.add(await _grab(tester, key, dpr));
    }
    await tester.pumpAndSettle();
    rows.add(frames);
  }

  final ColorScheme cs = _theme(Brightness.light).colorScheme;
  final List<ui.Image> strips = <ui.Image>[];
  final List<(String, String)> titles = <(String, String)>[
    ('new', '新：新页上滑 24px + 淡入，旧页原地压暗不动（360ms）'),
    ('old', '旧：ZoomPageTransitionsBuilder（300ms，整窗缩放，位移随窗口变大）'),
  ];
  for (int r = 0; r < rows.length; r++) {
    final File tmp = File('${frameDir.path}/_row_$r.png');
    await _writeFilmstrip(
      tester,
      frames: rows[r],
      labels: labels,
      file: tmp,
      frameDir: Directory('${frameDir.path}/${titles[r].$1}'),
      background: cs.surfaceContainerHighest,
      labelColor: cs.onSurface,
      title: titles[r].$2,
    );
    final Uint8List bytes = tmp.readAsBytesSync();
    final ui.Codec codec = (await tester.runAsync(
      () => ui.instantiateImageCodec(bytes),
    ))!;
    final ui.FrameInfo frame = (await tester.runAsync(codec.getNextFrame))!;
    strips.add(frame.image);
    tmp.deleteSync();
  }
  final int width = strips.map((ui.Image i) => i.width).reduce(math.max);
  final int height = strips.fold(0, (int a, ui.Image i) => a + i.height);
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  double y = 0;
  for (final ui.Image strip in strips) {
    canvas.drawImage(strip, Offset(0, y), Paint());
    y += strip.height;
  }
  final ui.Image combined = (await tester.runAsync(
    () => recorder.endRecording().toImage(width, height),
  ))!;
  await _writePng(tester, combined, file);
}

/// 按下 → 保持 → 松手回弹。
Future<void> _capturePressFilmstrip(
  WidgetTester tester,
  File file, {
  required Directory frameDir,
}) async {
  const double dpr = 2;
  const Size size = Size(200, 300);
  await _setView(tester, size, dpr);
  const Key key = ValueKey<String>('press-boundary');
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (BuildContext context) => Material(
          color: Theme.of(context).colorScheme.surface,
          child: Center(child: _BookCard(book: _books[8], width: 150)),
        ),
      ),
      brightness: Brightness.light,
      boundaryKey: key,
    ),
  );
  await tester.pumpAndSettle();
  final List<ui.Image> frames = <ui.Image>[];
  final List<String> labels = <String>[];
  final TestGesture gesture = await tester.startGesture(
    tester.getCenter(find.byType(FushiPressScale)),
  );
  int ms = 0;
  Future<void> shot(String label) async {
    frames.add(await _grab(tester, key, dpr));
    labels.add(label);
  }

  await tester.pump();
  await shot('按下 0ms');
  for (int i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 30));
    ms += 30;
    await shot('按下 ${ms}ms');
  }
  await gesture.up();
  ms = 0;
  await tester.pump();
  await shot('松手 0ms');
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 45));
    ms += 45;
    await shot('松手 ${ms}ms');
  }
  final ColorScheme cs = _theme(Brightness.light).colorScheme;
  await _writeFilmstrip(
    tester,
    frames: frames,
    labels: labels,
    file: file,
    frameDir: frameDir,
    background: cs.surfaceContainerHighest,
    labelColor: cs.onSurface,
    title: '按压反馈：按下 90ms 缩到 0.97，松手 180ms 带 ~1% 过冲回弹',
  );
}

/// 书架首屏错峰进场。
Future<void> _captureStaggerFilmstrip(
  WidgetTester tester,
  File file, {
  required Directory frameDir,
}) async {
  const double dpr = 1;
  const Size size = Size(520, 380);
  await _setView(tester, size, dpr);
  const Key key = ValueKey<String>('stagger-boundary');
  final ValueNotifier<bool> show = ValueNotifier<bool>(false);
  addTearDown(show.dispose);
  await tester.pumpWidget(
    _app(
      ValueListenableBuilder<bool>(
        valueListenable: show,
        builder: (BuildContext context, bool visible, _) => Material(
          color: Theme.of(context).colorScheme.surface,
          child: !visible
              ? const SizedBox.expand()
              : FushiEntranceScope(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: <Widget>[
                        for (int i = 0; i < 8; i++)
                          FushiStaggeredEntrance(
                            index: i,
                            child: _BookCard(book: _books[i + 1], width: 108),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
      brightness: Brightness.light,
      boundaryKey: key,
    ),
  );
  await tester.pumpAndSettle();
  show.value = true;
  final List<ui.Image> frames = <ui.Image>[];
  final List<String> labels = <String>[];
  const int step = 60;
  for (int ms = 0; ms <= 540; ms += step) {
    await tester.pump(
      ms == 0 ? Duration.zero : const Duration(milliseconds: step),
    );
    frames.add(await _grab(tester, key, dpr));
    labels.add('${ms}ms');
  }
  await tester.pumpAndSettle();
  final ColorScheme cs = _theme(Brightness.light).colorScheme;
  await _writeFilmstrip(
    tester,
    frames: frames,
    labels: labels,
    file: file,
    frameDir: frameDir,
    background: cs.surfaceContainerHighest,
    labelColor: cs.onSurface,
    title: '书架首屏错峰进场：每项错 35ms、淡入 + 上移 16px（滚动带出的卡不播）',
  );
}
