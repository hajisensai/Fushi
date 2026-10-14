// 「高级制卡」对话框的真实像素预览（给人目检宽屏 / 漫画 / 手机三种形态）。
//
// 不是回归测试：用生产组件与主题工厂在离屏光栅里画出交互稿的四种形态，写成 PNG。
// 默认 skip；设 `FUSHI_DESIGN_PREVIEW_OUT=<输出目录>` 才运行（与 design_preview 下的
// 预览同一约定）。中文字体探测 `FUSHI_PREVIEW_CJK_FONT` / Windows 等线 / 黑体。
@Tags(<String>['design-preview'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_dialog.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/fushi_icon_fonts.dart';
import 'advanced_mining_test_host.dart';

final String? _outDir = Platform.environment['FUSHI_DESIGN_PREVIEW_OUT'];

const String _latinFamily = 'FushiPreview';
const String _cjkFamily = 'FushiPreviewCJK';

void main() {
  if (_outDir == null || _outDir!.isEmpty) {
    test(
      'advanced mining preview（未设 FUSHI_DESIGN_PREVIEW_OUT，跳过）',
      () {},
      skip: 'set FUSHI_DESIGN_PREVIEW_OUT to render previews',
    );
    return;
  }
  final Directory out = Directory(_outDir!)..createSync(recursive: true);

  setUpAll(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    await _loadFonts();
    await loadFushiIconFonts();
  });

  testWidgets('desktop video', (WidgetTester tester) async {
    final FakeAdvancedMiningHost host = FakeAdvancedMiningHost();
    await _capture(
      tester,
      File('${out.path}/advanced_mining_desktop_video.png'),
      size: const Size(1040, 720),
      platform: TargetPlatform.windows,
      caps: host.videoPage(),
    );
  });

  testWidgets('desktop manga', (WidgetTester tester) async {
    final Uint8List page = (await tester.runAsync(_mangaPagePng))!;
    final FakeAdvancedMiningHost host = FakeAdvancedMiningHost();
    await _capture(
      tester,
      File('${out.path}/advanced_mining_desktop_manga.png'),
      size: const Size(1040, 720),
      platform: TargetPlatform.windows,
      caps: host.capabilities(
        deck: host.deck(),
        sentence: host.sentence(),
        manga: host.manga(pageBytes: page),
      ),
    );
  });

  testWidgets('phone sheet', (WidgetTester tester) async {
    final FakeAdvancedMiningHost host = FakeAdvancedMiningHost();
    await _capture(
      tester,
      File('${out.path}/advanced_mining_phone_sheet.png'),
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      caps: host.videoPage(),
      settle: () async {
        await tester.tap(find.text(t.popup_advanced_mining_audio_section));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('phone manga crop 360 en', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    addTearDown(() => LocaleSettings.setLocale(AppLocale.zhCn));
    final Uint8List page = (await tester.runAsync(_mangaPagePng))!;
    final FakeAdvancedMiningHost host = FakeAdvancedMiningHost();
    await _capture(
      tester,
      File('${out.path}/advanced_mining_phone_crop_360_en.png'),
      size: const Size(360, 780),
      platform: TargetPlatform.android,
      brightness: Brightness.dark,
      caps: host.capabilities(
        deck: host.deck(),
        sentence: host.sentence(),
        manga: host.manga(pageBytes: page, modelAvailable: false),
      ),
      settle: () async {
        await tester.tap(find.text(t.popup_advanced_mining_image_section));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('phone manga crop', (WidgetTester tester) async {
    final Uint8List page = (await tester.runAsync(_mangaPagePng))!;
    final FakeAdvancedMiningHost host = FakeAdvancedMiningHost();
    await _capture(
      tester,
      File('${out.path}/advanced_mining_phone_crop.png'),
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      brightness: Brightness.dark,
      caps: host.capabilities(
        deck: host.deck(),
        sentence: host.sentence(),
        manga: host.manga(pageBytes: page, modelAvailable: false),
      ),
      settle: () async {
        await tester.tap(find.text(t.popup_advanced_mining_image_section));
        await tester.pumpAndSettle();
      },
    );
  });
}

/// 画一张假漫画页（四格分镜 + 人物剪影 + 气泡），当作 loadPage 的原图字节。
Future<Uint8List> _mangaPagePng() async {
  const double w = 330 * 3, h = 466 * 3;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, w, h),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final Paint frame = Paint()
    ..color = const Color(0xFF2A2A2A)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6;
  for (final Rect r in FakeAdvancedMiningHost.mangaSuggestions.panels) {
    final Rect px = Rect.fromLTRB(
      r.left * w,
      r.top * h,
      r.right * w,
      r.bottom * h,
    );
    canvas.drawRect(px, Paint()..color = const Color(0xFFECEAE6));
    canvas.drawRect(px, frame);
  }
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(600, 470, 132, 210),
      const Radius.circular(66),
    ),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(618, 708, 228, 210),
      const Radius.circular(60),
    ),
    Paint()..color = const Color(0xFFB9B2A8),
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(90, 510, 180, 330),
      const Radius.circular(90),
    ),
    Paint()..color = const Color(0xFFC9C3BA),
  );
  final ui.Image image = await recorder.endRecording().toImage(
    w.toInt(),
    h.toInt(),
  );
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _loadFonts() async {
  final String? flutterRoot = _flutterRoot();
  final FontLoader latinLoader = FontLoader(_latinFamily);
  if (flutterRoot != null) {
    for (final String w in <String>['Regular', 'Medium', 'Bold']) {
      final String path =
          '$flutterRoot/bin/cache/artifacts/material_fonts/Roboto-$w.ttf';
      if (File(path).existsSync()) latinLoader.addFont(_bytes(path));
    }
  }
  await latinLoader.load();
  final String? cjk = _findCjkFont();
  if (cjk != null) {
    await (FontLoader(_cjkFamily)..addFont(_bytes(cjk))).load();
  }
  if (flutterRoot != null) {
    final String icons =
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(icons).existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(_bytes(icons))).load();
    }
  }
}

Future<ByteData> _bytes(String path) async =>
    ByteData.sublistView(File(path).readAsBytesSync());

String? _flutterRoot() {
  final String? env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && Directory(env).existsSync()) return env;
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
    r'C:\Windows\Fonts\Deng.ttf',
    r'C:\Windows\Fonts\simhei.ttf',
  ];
  for (final String path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

ThemeData _theme(Brightness brightness, TargetPlatform platform) {
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
  return base.copyWith(platform: platform);
}

/// 起一个「视频画面」底，在上面打开对话框，整窗截图。
Future<void> _capture(
  WidgetTester tester,
  File file, {
  required Size size,
  required TargetPlatform platform,
  required AdvancedMiningCapabilities caps,
  Brightness brightness = Brightness.light,
  Future<void> Function()? settle,
  double dpr = 2,
}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = size * dpr;
  addTearDown(tester.view.reset);
  const Key key = ValueKey<String>('preview-boundary');
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(brightness, platform),
      builder: (BuildContext context, Widget? child) =>
          RepaintBoundary(key: key, child: child),
      home: FushiFocusRoot(
        child: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) => DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0xFF5C6B7A), Color(0xFF3E4852)],
                ),
              ),
              child: Center(
                child: TextButton(
                  onPressed: () => unawaited(
                    showAdvancedMiningDialog(context: ctx, capabilities: caps),
                  ),
                  child: const Text(
                    'それでも、僕は諦めきれなかった。',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byType(TextButton));
  // 原页图解码是真实异步 IO，要在 runAsync 里给它时间。
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
  if (settle != null) await settle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(key));
  final ui.Image image = (await tester.runAsync(
    () => boundary.toImage(pixelRatio: dpr),
  ))!;
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(data!.buffer.asUint8List());
}
