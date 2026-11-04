import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

// 主播放 / 暂停键的外形契约：MD3 下视频、有声书、音乐的主播放键一律是同一个
// M3E 多边形（[fushiPlayButtonPolygon]，12 瓣饼干），形状只在
// fushi_m3e_player.dart 定义一次；Apple（glass）设计系统保持原外形。
void main() {
  late bool Function() originalShaderSupport;
  setUp(() {
    originalShaderSupport = debugShaderFilterSupported;
    debugShaderFilterSupported = () => true;
  });
  tearDown(() => debugShaderFilterSupported = originalShaderSupport);

  ThemeData theme({bool glass = false}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
    eink: false,
  );

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    bool glass = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(glass: glass),
        home: FushiGlassScope(
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );
    await tester.pump();
  }

  bool isPlayPolygon(ShapeBorder? shape) =>
      shape is MaterialShapeBorder &&
      identical(shape.shape, fushiPlayButtonPolygon);

  /// [root] 子树里所有 Material / ShapeDecoration 的外形。
  List<ShapeBorder?> shapesUnder(WidgetTester tester, Finder root) =>
      <ShapeBorder?>[
        for (final Material m in tester.widgetList<Material>(
          find.descendant(of: root, matching: find.byType(Material)),
        ))
          m.shape,
        for (final DecoratedBox d in tester.widgetList<DecoratedBox>(
          find.descendant(of: root, matching: find.byType(DecoratedBox)),
        ))
          if (d.decoration is ShapeDecoration)
            (d.decoration as ShapeDecoration).shape,
      ];

  test('the play polygon is the 12-sided M3E cookie', () {
    expect(
      identical(fushiPlayButtonPolygon, MaterialShapes.cookie12Sided),
      isTrue,
    );
    expect(isPlayPolygon(fushiPlayButtonBorder()), isTrue);
  });

  for (final bool playing in <bool>[false, true]) {
    testWidgets('FushiExpressivePlayButton is the play polygon (playing: '
        '$playing)', (WidgetTester tester) async {
      await pump(
        tester,
        FushiExpressivePlayButton(
          isPlaying: playing,
          size: 64,
          onPressed: () {},
        ),
      );
      expect(
        shapesUnder(tester, find.byType(FushiExpressivePlayButton)),
        contains(predicate<ShapeBorder?>(isPlayPolygon)),
      );
    });
  }

  testWidgets('FushiExpressivePlayButton keeps the Apple shape under glass', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      FushiExpressivePlayButton(isPlaying: false, size: 64, onPressed: () {}),
      glass: true,
    );
    expect(
      shapesUnder(tester, find.byType(FushiExpressivePlayButton)),
      isNot(contains(predicate<ShapeBorder?>(isPlayPolygon))),
    );
  });

  testWidgets('video VideoM3ePlayPauseButton is the play polygon', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      VideoM3ePlayPauseButton(
        playing: true,
        extent: 40,
        width: 52,
        onPressed: () {},
      ),
    );
    expect(
      shapesUnder(tester, find.byType(VideoM3ePlayPauseButton)),
      contains(predicate<ShapeBorder?>(isPlayPolygon)),
    );
  });

  testWidgets('FushiToolbarFab(playButton) is the play polygon on MD3 only', (
    WidgetTester tester,
  ) async {
    Widget fab({required bool playButton}) => FushiToolbarFab(
      icon: FushiIcons.play,
      tooltip: 'play',
      onPressed: () {},
      morphing: true,
      playButton: playButton,
    );
    await pump(tester, fab(playButton: true));
    expect(
      shapesUnder(tester, find.byType(FushiToolbarFab)),
      contains(predicate<ShapeBorder?>(isPlayPolygon)),
    );
    // 非播放键 FAB 不受影响。
    await pump(tester, fab(playButton: false));
    expect(
      shapesUnder(tester, find.byType(FushiToolbarFab)),
      isNot(contains(predicate<ShapeBorder?>(isPlayPolygon))),
    );
  });

  testWidgets('icon-button play keys take the polygon through style.shape', (
    WidgetTester tester,
  ) async {
    // 有声书底栏 / 书架迷你条的播放键都是 FushiIconButtonControl + 固定
    // style.shape：确认这条路径真把多边形画出来，不被 M3E 形变盖掉。
    await pump(
      tester,
      FushiIconButtonControl.filled(
        icon: const FushiIcon(FushiIcons.play),
        tooltip: 'play',
        style: ButtonStyle(
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            fushiPlayButtonBorder(),
          ),
        ),
        onPressed: () {},
      ),
    );
    expect(
      shapesUnder(tester, find.byType(FushiIconButtonControl)),
      contains(predicate<ShapeBorder?>(isPlayPolygon)),
    );
  });

  test('audiobook play keys are wired to the shared play polygon', () {
    // 有声书底栏 / 迷你条依赖控制器与 AppModel，挂整页太重：源码钉住它们
    // 取的是共享定义，而不是各自再写一份形状。
    final String bar = File(
      'lib/src/media/audiobook/audiobook_play_bar.dart',
    ).readAsStringSync();
    expect(bar, contains('fushiPlayButtonBorder()'));
    expect(bar, contains('playButton: true'));
    final String mini = File(
      'lib/src/media/audiobook/now_listening_mini_bar.dart',
    ).readAsStringSync();
    expect(mini, contains('fushiPlayButtonBorder()'));
    // 播放键多边形只在 fushi_m3e_player.dart 定义一次。
    for (final String path in <String>[
      'lib/src/media/audiobook/audiobook_play_bar.dart',
      'lib/src/media/audiobook/now_listening_mini_bar.dart',
      'lib/src/media/video/video_m3e_chrome.dart',
      'lib/src/utils/components/fushi_floating_toolbar.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains('cookie12Sided')),
        reason: '$path must reuse fushiPlayButtonPolygon',
      );
    }
  });
}
