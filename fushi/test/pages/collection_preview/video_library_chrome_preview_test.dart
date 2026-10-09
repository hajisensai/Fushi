@Tags(<String>['preview'])
library;

// 视频库页浮动工具区 / 详情页加载骨架的真实像素预览（改前 / 改后对照，不开真
// app 看布局，记忆 `widget-test-real-pixel-preview` 范式）。
//
// 只在 `FUSHI_PREVIEW=1` 时真跑（写 PNG、加载 Windows 系统字体）。输出目录
// `FUSHI_PREVIEW_OUT`（缺省 `../.claude/preview/video_library_chrome`），文件名后缀
// `FUSHI_PREVIEW_SUFFIX`（`before` / `after`）。
//
//   $env:FUSHI_PREVIEW='1'; $env:FUSHI_PREVIEW_SUFFIX='after'
//   flutter test --no-pub test/pages/collection_preview/video_library_chrome_preview_test.dart
//
// 三组：
//   ① chrome_scrolled：外壳页签 + 页面自己的搜索 / 筛选行（嵌套工具区），内容
//      往下滚、工具区弹回时，工具区背后透出多少内容；
//   ② chrome_after_shrink：滚到下面工具区收起后，列表缩短到一屏放得下（删视频）
//      ——工具区能不能自己回来；
//   ③ skeleton：作品详情页加载骨架（桌面两栏宽度 / 手机）。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/pages/implementations/video_download_subscription_edit_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/utils.dart';

const String _fontFamily = 'PreviewCJK';

const List<String> _fontCandidates = <String>[
  r'C:\Windows\Fonts\NotoSansSC-VF.ttf',
  r'C:\Windows\Fonts\NotoSansJP-Regular.otf',
  r'C:\Windows\Fonts\segoeui.ttf',
];

String get _outDir =>
    Platform.environment['FUSHI_PREVIEW_OUT'] ??
    '${Directory.current.path}/../.claude/preview/video_library_chrome';

String get _suffix => Platform.environment['FUSHI_PREVIEW_SUFFIX'] ?? 'shot';

Future<void> _loadFont() async {
  for (final String path in _fontCandidates) {
    final File file = File(path);
    if (!file.existsSync()) continue;
    final Uint8List bytes = await file.readAsBytes();
    final FontLoader loader = FontLoader(_fontFamily)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    return;
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    final File out = File('$_outDir/${name}_$_suffix.png');
    out.parent.createSync(recursive: true);
    await out.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void _setView(WidgetTester tester, Size logical, double dpr) {
  tester.view.physicalSize = logical * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ThemeData _theme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  colorSchemeSeed: const Color(0xFF6750A4),
  fontFamily: _fontFamily,
);

Widget _pill(String label, {double? width}) => Container(
  width: width,
  height: 44,
  alignment: Alignment.center,
  padding: const EdgeInsets.symmetric(horizontal: 16),
  decoration: BoxDecoration(
    color: const Color(0xFFEDE7F6),
    borderRadius: BorderRadius.circular(22),
    boxShadow: const <BoxShadow>[
      BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2)),
    ],
  ),
  child: Text(label),
);

/// 仿视频库：外壳工具区（页签胶囊）+ 页面嵌套工具区（搜索行 + 标签行）+ 封面网格。
class _LibraryHarness extends StatefulWidget {
  const _LibraryHarness({required this.controller, required this.itemCount});

  final FushiFloatingChromeController controller;
  final ValueNotifier<int> itemCount;

  @override
  State<_LibraryHarness> createState() => _LibraryHarnessState();
}

class _LibraryHarnessState extends State<_LibraryHarness> {
  @override
  Widget build(BuildContext context) {
    return FushiFloatingChromeScope(
      controller: widget.controller,
      child: FushiFloatingChromeOverlay(
        chrome: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: <Widget>[
              _pill('首页  系列  全部视频  发现  媒体服务器  来源  设置'),
              const Spacer(),
              _pill('⟳', width: 44),
            ],
          ),
        ),
        child: NotificationListener<ScrollNotification>(
          onNotification: widget.controller.handleScrollNotification,
          child: FushiFloatingChromeOverlay(
            chrome: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _pill('搜索库'),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      for (final String tag in <String>['1★', '2★', '3★', '4★'])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _pill(tag, width: 64),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            child: Builder(
              builder: (BuildContext context) => ValueListenableBuilder<int>(
                valueListenable: widget.itemCount,
                builder: (BuildContext context, int count, Widget? _) =>
                    GridView.builder(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        FushiFloatingChromeInset.of(context) + 8,
                        16,
                        16,
                      ),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 6,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 2 / 3,
                          ),
                      itemCount: count,
                      itemBuilder: (BuildContext context, int i) =>
                          DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: <Color>[
                                  HSLColor.fromAHSL(
                                    1,
                                    (i * 47) % 360.0,
                                    0.65,
                                    0.55,
                                  ).toColor(),
                                  HSLColor.fromAHSL(
                                    1,
                                    (i * 47 + 60) % 360.0,
                                    0.7,
                                    0.35,
                                  ).toColor(),
                                ],
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '作品 $i',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  final bool skip = Platform.environment['FUSHI_PREVIEW'] != '1';

  Future<void> pumpLibrary(
    WidgetTester tester,
    GlobalKey key,
    FushiFloatingChromeController controller,
    ValueNotifier<int> count,
  ) async {
    _setView(tester, const Size(1280, 800), 1.0);
    await tester.runAsync(_loadFont);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            body: _LibraryHarness(controller: controller, itemCount: count),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('01 chrome scrolled（内容滚到工具区底下）', (WidgetTester tester) async {
    final GlobalKey key = GlobalKey();
    final FushiFloatingChromeController controller =
        FushiFloatingChromeController();
    final ValueNotifier<int> count = ValueNotifier<int>(60);
    await pumpLibrary(tester, key, controller, count);
    // 往下滚：工具区收起；再往上滚一点：工具区弹回，内容停在工具区底下。
    await tester.drag(find.byType(GridView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(GridView), const Offset(0, 120));
    await tester.pumpAndSettle();
    await _capture(tester, key, '01_chrome_scrolled');
  }, skip: skip);

  testWidgets('02 chrome after shrink（删到一屏放得下）', (WidgetTester tester) async {
    final GlobalKey key = GlobalKey();
    final FushiFloatingChromeController controller =
        FushiFloatingChromeController();
    final ValueNotifier<int> count = ValueNotifier<int>(60);
    await pumpLibrary(tester, key, controller, count);
    await tester.drag(find.byType(GridView), const Offset(0, -900));
    await tester.pumpAndSettle();
    count.value = 6;
    await tester.pumpAndSettle();
    await _capture(tester, key, '02_chrome_after_shrink');
  }, skip: skip);

  for (final (String name, Size size, double dpr) in <(String, Size, double)>[
    ('03_skeleton_desktop', const Size(1600, 900), 1.0),
    ('04_skeleton_mobile', const Size(390, 844), 2.0),
  ]) {
    testWidgets('$name 加载骨架', (WidgetTester tester) async {
      _setView(tester, size, dpr);
      await tester.runAsync(_loadFont);
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(),
            home: RepaintBoundary(
              key: key,
              child: const Scaffold(body: MediaDetailSkeleton()),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await _capture(tester, key, name);
    }, skip: skip);
  }

  testWidgets('05 编辑订阅对话框', (WidgetTester tester) async {
    _setView(tester, const Size(720, 1000), 1.5);
    await tester.runAsync(_loadFont);
    LocaleSettings.setLocale(AppLocale.zhCn);
    addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
    final GlobalKey key = GlobalKey();
    final VideoDownloadSubscriptionRow subscription =
        VideoDownloadSubscriptionRow(
          subscriptionId: 's1',
          resourceProvider: 'nyaa:default',
          metadataProvider: 'anilist',
          externalId: '1',
          mediaKind: 'tv',
          discoveryCategory: 'anime',
          title: 'FX戦士くるみちゃん',
          year: 2026,
          season: 1,
          coverUrl: null,
          searchQuery: 'FX Senshi Kurumi-chan',
          filterJson:
              '{"strict":true,"releaseGroup":"SubsPlease",'
              '"resolution":"1080p","trustedOnly":true}',
          mode: 'ongoing',
          startAfterEpisode: 1,
          backendKind: 'embedded',
          backendProfileId: null,
          fingerprint: 'embedded',
          category: 'fushi-video',
          targetSourceId: 1,
          collectionId: null,
          organizationPolicy: 'library',
          subtitlePolicy: 'bestEffort',
          enabled: true,
          nextCheckAt: null,
          claimedBy: null,
          claimExpiresAt: null,
          retryCount: 0,
          lastCheckedAt: null,
          lastMatchedAt: null,
          fulfilledAt: null,
          lastError: null,
          createdAt: 1,
          updatedAt: 2,
        );
    final MediaSourceRow source = MediaSourceRow(
      videoGroupingMode: 'series',
      id: 1,
      label: '动画',
      mediaKind: 'video',
      transport: 'local',
      rootPath: '/anime',
      configJson: '{}',
      mediaCount: 0,
      lastScannedAt: null,
      lastScanError: null,
      recursive: true,
      sortOrder: 0,
      createdAt: 1,
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(),
          // 对话框是叠在 Navigator 上的另一条路由：边界要包住整个 Navigator。
          builder: (BuildContext context, Widget? child) =>
              RepaintBoundary(key: key, child: child),
          home: Builder(
            builder: (BuildContext _) => Scaffold(
              body: Builder(
                builder: (BuildContext context) => Center(
                  child: FilledButton(
                    onPressed: () => showVideoDownloadSubscriptionEditDialog(
                      context: context,
                      subscription: subscription,
                      sources: <MediaSourceRow>[source],
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _capture(tester, key, '05_subscription_edit');
  }, skip: skip);
}
