// 横屏手机 + 软键盘：「在线搜索字幕」弹层的搜索框必须完整可见、不溢出。
//
// 现象（用户截图）：横屏播视频时点「问 AI」，输入框自动聚焦弹出键盘，浮动面板被
// 压成 ~130dp 的一条，标题栏 + 上下文 chip 把高度吃光，对话列表高度为 0、输入框被
// 裁掉，既不能输入也不能滚动。
//
// 断言：键盘上方的浮层里，输入框完整可见、对话列表仍有可读高度。
// 设了 `FUSHI_PREVIEW_OUT=<目录>` 还会写 PNG（`FUSHI_PREVIEW_SUFFIX` 给 before / after）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_subtitle_search_sheet.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

final String? _outDir = Platform.environment['FUSHI_PREVIEW_OUT'];
String get _suffix => Platform.environment['FUSHI_PREVIEW_SUFFIX'] ?? 'shot';

const String _latinFamily = 'FushiPreview';

void main() {
  setUpAll(() async {
    if (_outDir == null || _outDir!.isEmpty) return;
    final FontLoader latin = FontLoader(_latinFamily);
    final String root =
        Platform.environment['FLUTTER_ROOT'] ?? 'D:/flutter_sdk/flutter_3.47.6';
    for (final String w in <String>['Regular', 'Medium', 'Bold']) {
      final File f = File(
        '$root/bin/cache/artifacts/material_fonts/Roboto-$w.ttf',
      );
      if (f.existsSync()) {
        latin.addFont(
          Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())),
        );
      }
    }
    await latin.load();
    for (final (String family, String path) in <(String, String)>[
      ('FushiSymbols', 'assets/icon_fonts/FushiSymbolsRounded.ttf'),
      ('FushiSymbolsFilled', 'assets/icon_fonts/FushiSymbolsRoundedFilled.ttf'),
    ]) {
      if (File(path).existsSync()) {
        await (FontLoader(family)..addFont(
              Future<ByteData>.value(
                ByteData.sublistView(File(path).readAsBytesSync()),
              ),
            ))
            .load();
      }
    }
  });

  testWidgets('landscape phone + keyboard: search fields stay visible', (
    WidgetTester tester,
  ) async {
    const double dpr = 2.75;
    const Size logical = Size(800, 360);
    const double keyboard = 200;
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = logical * dpr;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard * dpr);
    addTearDown(tester.view.reset);

    const Key boundaryKey = ValueKey<String>('preview-boundary');
    final ThemeData base = buildFushiThemeData(
      scheme: buildFushiColorScheme(
        seedColor: kFushiDefaultSeed,
        brightness: Brightness.light,
      ),
      designSystem: FushiDesignSystem.auto,
      glassDesign: false,
      textTheme: FushiTypeScale.buildTextTheme(
        const TextStyle(fontFamily: _latinFamily),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: base.copyWith(platform: TargetPlatform.android),
        builder: (BuildContext context, Widget? app) => RepaintBoundary(
          key: boundaryKey,
          child: FushiFocusRoot(child: app!),
        ),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            backgroundColor: const Color(0xFF000000),
            body: Center(
              child: TextButton(
                onPressed: () => showVideoRemoteSubtitleSearchSheet(
                  context: context,
                  search: (String? q, int? e) async =>
                      const VideoRemoteSubtitleSearchResult(
                        query: 'Frieren',
                        episode: 3,
                        candidates: <VideoRemoteSubtitleCandidate>[
                          VideoRemoteSubtitleCandidate(
                            id: '1',
                            fileName: 'frieren_03.ja.srt',
                            provider: 'jimaku',
                            language: 'ja',
                          ),
                          VideoRemoteSubtitleCandidate(
                            id: '2',
                            fileName: 'frieren_03.en.srt',
                            provider: 'jimaku',
                            language: 'en',
                          ),
                        ],
                      ),
                  download: (_) async {},
                  errorText: (Object e) => '$e',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    if (_outDir != null && _outDir!.isNotEmpty) {
      final RenderRepaintBoundary boundary = tester
          .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
      final ui.Image image = (await tester.runAsync(
        () => boundary.toImage(pixelRatio: dpr),
      ))!;
      final ByteData? data = await tester.runAsync<ByteData?>(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
      image.dispose();
      final Directory out = Directory(_outDir!)..createSync(recursive: true);
      File(
        '${out.path}/subtitle_search_landscape_keyboard_$_suffix.png',
      ).writeAsBytesSync(data!.buffer.asUint8List());
    }

    expect(tester.takeException(), isNull, reason: 'no layout overflow');
    for (final String key in <String>[
      'video-remote-subtitle-search-episode',
      'video-remote-subtitle-search-go',
    ]) {
      final Rect r = tester.getRect(find.byKey(ValueKey<String>(key)));
      expect(
        r.bottom,
        lessThanOrEqualTo(logical.height - keyboard + 0.5),
        reason: '$key must sit above the keyboard',
      );
    }
  });
}
