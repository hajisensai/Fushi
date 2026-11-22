import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_gpu.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 观察用：真 app 里歌词页 → 全屏歌词动画 → 镜台（Flutter GPU 真 3D）的真实像素。
///
/// 一首静音 WAV 配同名 `.lrc`（逐行同步歌词），焦点驱动点工具栏「歌词动画」按钮、在样式
/// 面板里选「镜台」，播放中隔几秒拍一张。断言 Flutter GPU 管线在这台机器的后端（Windows
/// 上是 ANGLE / GLES）建得起来——镜台没退回 Canvas 后备实现。素材全在临时目录，不碰用户库。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('全屏歌词动画：镜台走 Flutter GPU', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    await enableFocusNavigation(tester);
    final FocusDriver driver = FocusDriver(tester);

    final Directory dir = await Directory.systemTemp.createTemp('diorama-gpu');
    final String song = '${dir.path}${Platform.pathSeparator}song.wav';
    final String lrc = '${dir.path}${Platform.pathSeparator}song.lrc';
    await tester.runAsync(() async {
      File(song).writeAsBytesSync(_silentWav(seconds: 120));
      File(lrc).writeAsStringSync(_lrc);
    });

    final String userMode = appModel.prefsRepo.musicVisualizerMode;
    final bool userRandom = appModel.prefsRepo.musicVisualizerRandom;
    final NavigatorState nav = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    Future<void> frames(int n, [int ms = 100]) async {
      for (int i = 0; i < n; i++) {
        await tester.pump(Duration(milliseconds: ms));
      }
    }

    try {
      await appModel.prefsRepo.setMusicVisualizerRandom(false);
      await appModel.musicSession.engine.playQueue(<MusicPlayItem>[
        MusicPlayItem(
          trackUid: 'obs-diorama',
          path: song,
          title: '夜空の歌',
          artist: 'Starlight 99',
          durationMs: 120000,
        ),
      ]);
      await appModel.musicSession.engine.play();
      unawaited(
        nav.push<void>(
          adaptivePageRoute<void>(
            context: nav.context,
            builder: (_) => const MusicLyricsPage(),
          ),
        ),
      );
      await frames(10);
      bool settled() =>
          (tester.state(find.byType(MusicLyricsPage)) as dynamic)
                  .lyricsLoadSettled
              as bool;
      for (int i = 0; i < 100 && !settled(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(settled(), isTrue, reason: '同名 .lrc 应解析完');
      await captureFlutterFrame(tester, '01-lyrics-page', settle: false);

      // 工具栏「歌词动画」：宽度够时平铺，不够时收在「⋯」里。焦点驱动，Enter 确认。
      final Finder button = find.byKey(
        const ValueKey<String>('music_lyrics_visualizer'),
      );
      if (button.evaluate().isEmpty) {
        final Finder more = find.byKey(kFushiToolbarOverflowKey);
        expect(more, findsOneWidget, reason: '工具栏应有「⋯」');
        expect(await _focusOn(tester, more), isTrue, reason: '「⋯」应能拿到焦点');
        await driver.activate();
        await frames(6);
        final Finder item = find.byKey(
          const ValueKey<String>('music_lyrics_visualizer_menu_item'),
        );
        expect(item, findsOneWidget, reason: '「⋯」里应有歌词动画');
        expect(await _focusOn(tester, item), isTrue, reason: '歌词动画菜单项应能拿到焦点');
      } else {
        expect(await _focusOn(tester, button), isTrue, reason: '歌词动画按钮应能拿到焦点');
      }
      debugPrint(
        '[diorama-gpu] opening picker: inline=${button.evaluate().isNotEmpty} '
        'focus=${driver.focused?.debugLabel}',
      );
      // 歌词页自己把 Enter 绑成了播放类快捷键时，Enter 落不到按钮上：先走焦点控件的标准
      // ActivateIntent（同一个焦点、同一条激活路径），没有再发 Enter。
      if (!await driver.activateIntent()) await driver.activate();
      await frames(10);
      debugPrint(
        '[diorama-gpu] picker open='
        '${find.byKey(const ValueKey<String>('music_visualizer_random')).evaluate().isNotEmpty}',
      );

      final Finder tile = find.byKey(
        const ValueKey<String>('music_visualizer_style_diorama'),
      );
      await captureFlutterFrame(tester, '02-picker', settle: false);
      // 网格是懒构建的：镜台卡可能还没建出来。Tab 走焦点时网格会把焦点项滚进视口。
      final bool focusedTile =
          (tile.evaluate().isNotEmpty && await _focusOn(tester, tile)) ||
          await driver.focusWidget(tile, maxSteps: 120);
      debugPrint('[diorama-gpu] tile focused=$focusedTile');
      expect(focusedTile, isTrue, reason: '镜台样式卡应能拿到焦点');
      await captureFlutterFrame(
        tester,
        '03-picker-diorama-focused',
        settle: false,
      );
      if (!await driver.activateIntent()) await driver.activate();

      // 等 Flutter GPU 判定（加载着色器包）落地，再推几秒让相机落位、文字纹理上 GPU。
      for (int i = 0; i < 100 && !DioramaGpu.resolved; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint(
        '[diorama-gpu] resolved=${DioramaGpu.resolved} '
        'pipelines=${DioramaGpu.pipelines != null}',
      );
      expect(DioramaGpu.resolved, isTrue);
      expect(
        DioramaGpu.pipelines,
        isNotNull,
        reason: 'Flutter GPU 管线应在真 app 里建起来（没退回 Canvas 后备）',
      );
      expect(
        find.byKey(const ValueKey<String>('music_visualizer')),
        findsOneWidget,
      );

      final List<String> names = <String>[
        '04-diorama-line1',
        '05-diorama-line2',
        '06-diorama-transition',
        '07-diorama-line4',
      ];
      for (final String name in names) {
        await frames(30);
        final ObserveShot shot = await captureFlutterFrame(
          tester,
          name,
          settle: false,
        );
        debugPrint(
          '[diorama-gpu] $name saved=${shot.saved} '
          'pos=${appModel.musicSession.engine.position.inMilliseconds}ms',
        );
      }

      // Esc 退出全屏（焦点驱动）。
      debugPrint('[diorama-gpu] exit visualizer');
      await driver.back();
      await frames(5);
      debugPrint('[diorama-gpu] exited');
    } catch (e, st) {
      // 真 app 改了 FlutterError.onError，测试失败的原文会被框架吞成一条无关断言；先打出来。
      debugPrint('[diorama-gpu] FAILED: $e\n$st');
      rethrow;
    } finally {
      debugPrint('[diorama-gpu] cleanup');
      await appModel.prefsRepo.setMusicVisualizerMode(userMode);
      await appModel.prefsRepo.setMusicVisualizerRandom(userRandom);
      if (nav.canPop()) nav.pop();
      await frames(5);
      await appModel.musicSession.engine.pause();
      debugPrint('[diorama-gpu] paused');
      await appModel.musicSession.engine.stop();
      debugPrint('[diorama-gpu] cleanup done');
    }
  });
}

/// 把焦点交给 [target] 自己的可聚焦控件（按钮 / 卡片的 InkWell 焦点节点），并确认真落上了。
///
/// `FocusDriver.requestFocusInside` 只认显式传了 focusNode 的 [Focus]，按钮内部 InkWell
/// 自建的节点找不到时会退去聚焦外层路由——看着成功，Enter 却落空。这里从目标最深处的元素
/// 往上取最近的焦点节点，就是那颗按钮自己的。
Future<bool> _focusOn(WidgetTester tester, Finder target) async {
  final List<Element> inside = find
      .descendant(of: target, matching: find.byWidgetPredicate((_) => true))
      .evaluate()
      .toList();
  if (inside.isEmpty) return false;
  final FocusNode? node = Focus.maybeOf(inside.last);
  if (node == null) return false;
  node.requestFocus();
  await tester.pump(const Duration(milliseconds: 250));
  return FocusManager.instance.primaryFocus == node;
}

const String _lrc = '''
[00:00.50]夜空に光る星を数えて
[00:03.50]遠い街の灯りが揺れる
[00:06.50]君の声が聞こえた気がした
[00:09.50]明日へ続く道を歩こう
[00:12.50]風が運ぶ歌を口ずさむ
[00:15.50]ずっとこのまま夢を見ていたい
''';

/// 单声道 16-bit 8kHz 静音 WAV。
Uint8List _silentWav({required int seconds}) {
  const int rate = 8000;
  final int dataLen = rate * 2 * seconds;
  final ByteData b = ByteData(44 + dataLen);
  void str(int off, String v) {
    for (int i = 0; i < v.length; i++) {
      b.setUint8(off + i, v.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, dataLen, Endian.little);
  return b.buffer.asUint8List();
}
