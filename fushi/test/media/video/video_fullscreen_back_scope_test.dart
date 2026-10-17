import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_foreground_layers.dart';
import 'package:fushi/src/media/video/video_fullscreen_back_scope.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3449（反馈 _oQPV1HPqX / 2XRS7o4YJ8）：全屏 + 底部剧集轨开着按 Esc，先退了全屏、
/// 剧集轨还留着。
///
/// 全屏是推到根 navigator 的独立路由。焦点不在视频页子树里时，Esc（以及手柄 B 兜底、
/// 鼠标侧键兜底、media_kit 自己的退全屏）都以 `Navigator.maybePop` 的形式到达——栈顶
/// 是全屏路由，视频页那份走逐级退出的 `PopScope` 轮不到，全屏路由直接被 pop。修复是
/// 在全屏路由里挂 [VideoFullscreenBackScope]，把同一份层级表
/// （[topVideoForegroundLayer]）接上去。这里用真 Navigator + 真 PopScope 钉住：
///
/// * 每次 maybePop 只关最上面一层，全屏路由留在栈上；
/// * 层全关完下一次 maybePop 才退全屏；
/// * 显式 `Navigator.pop`（F 键 / 全屏按钮）不经层级表；
/// * media_kit 的 PopScope 只在**真的 pop 了**时才退原生全屏。
void main() {
  /// 模拟全屏路由里与本层并列的 media_kit `_FullscreenInheritedWidgetPopScope`：
  /// 记录每次收到的 didPop，打过补丁后只在 didPop 为真时退原生全屏。
  Widget mediaKitLikePopScope(List<bool> didPops, Widget child) {
    return PopScope<Object?>(
      onPopInvokedWithResult: (bool didPop, Object? _) => didPops.add(didPop),
      child: child,
    );
  }

  Future<NavigatorState> pumpFullscreenRoute(
    WidgetTester tester, {
    required Set<VideoForegroundLayer> open,
    required List<VideoForegroundLayer> closed,
    required List<bool> mediaKitDidPops,
    required List<String> exits,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Text('video-page')),
      ),
    );
    bool dismissTopLayer() {
      final VideoForegroundLayer? layer = topVideoForegroundLayer(
        hasVisibleDictionaryPopup: open.contains(
          VideoForegroundLayer.dictionaryPopup,
        ),
        controlEditActive: open.contains(VideoForegroundLayer.controlEdit),
        controlPopoverOpen: open.contains(VideoForegroundLayer.controlPopover),
        subtitleListVisible: open.contains(VideoForegroundLayer.subtitleList),
        episodeListVisible: open.contains(VideoForegroundLayer.episodeList),
        sidePanelOpen: open.contains(VideoForegroundLayer.sidePanel),
        immersiveLocked: open.contains(VideoForegroundLayer.immersiveLock),
      );
      if (layer == null) return false;
      open.remove(layer);
      closed.add(layer);
      return true;
    }

    unawaited(
      navKey.currentState!.push<void>(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (BuildContext routeContext, _, __) =>
              VideoFullscreenBackScope(
                dismissTopLayer: dismissTopLayer,
                exitFullscreen: () {
                  exits.add('exit');
                  Navigator.of(routeContext).pop();
                },
                child: mediaKitLikePopScope(
                  mediaKitDidPops,
                  const Text('fullscreen-route'),
                ),
              ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('fullscreen-route'), findsOneWidget);
    return navKey.currentState!;
  }

  testWidgets('剧集轨开着：第一次返回只关剧集轨、全屏保持；第二次才退全屏', (WidgetTester tester) async {
    final Set<VideoForegroundLayer> open = <VideoForegroundLayer>{
      VideoForegroundLayer.episodeList,
    };
    final List<VideoForegroundLayer> closed = <VideoForegroundLayer>[];
    final List<bool> mediaKitDidPops = <bool>[];
    final List<String> exits = <String>[];
    final NavigatorState nav = await pumpFullscreenRoute(
      tester,
      open: open,
      closed: closed,
      mediaKitDidPops: mediaKitDidPops,
      exits: exits,
    );

    expect(await nav.maybePop(), isTrue);
    await tester.pumpAndSettle();
    expect(closed, <VideoForegroundLayer>[VideoForegroundLayer.episodeList]);
    expect(exits, isEmpty);
    expect(find.text('fullscreen-route'), findsOneWidget, reason: '全屏路由应还在');
    expect(mediaKitDidPops, <bool>[
      false,
    ], reason: 'media_kit 收到的是「没 pop」，不得据此退原生全屏');

    expect(await nav.maybePop(), isTrue);
    await tester.pumpAndSettle();
    expect(exits, <String>['exit']);
    expect(find.text('fullscreen-route'), findsNothing);
    expect(find.text('video-page'), findsOneWidget, reason: '只退全屏，不退视频页');
    // 真 pop 发生在拦截回调里（嵌套通知），media_kit 先收到 true、外层循环随后补一次
    // false——打过补丁的 media_kit 只认那次 true。
    expect(mediaKitDidPops, contains(true), reason: '真 pop 时 media_kit 才退原生全屏');
  });

  testWidgets('多层同时开着：按层级表从最前台逐层关，全关完才退全屏', (WidgetTester tester) async {
    final Set<VideoForegroundLayer> open = <VideoForegroundLayer>{
      VideoForegroundLayer.immersiveLock,
      VideoForegroundLayer.sidePanel,
      VideoForegroundLayer.episodeList,
      VideoForegroundLayer.subtitleList,
      VideoForegroundLayer.controlPopover,
      VideoForegroundLayer.dictionaryPopup,
    };
    final List<VideoForegroundLayer> closed = <VideoForegroundLayer>[];
    final List<String> exits = <String>[];
    final NavigatorState nav = await pumpFullscreenRoute(
      tester,
      open: open,
      closed: closed,
      mediaKitDidPops: <bool>[],
      exits: exits,
    );

    for (int i = 0; i < 6; i++) {
      await nav.maybePop();
      await tester.pumpAndSettle();
      expect(exits, isEmpty, reason: '第 ${i + 1} 次返回时还有层开着，不应退全屏');
      expect(find.text('fullscreen-route'), findsOneWidget);
    }
    expect(closed, <VideoForegroundLayer>[
      VideoForegroundLayer.dictionaryPopup,
      VideoForegroundLayer.controlPopover,
      VideoForegroundLayer.subtitleList,
      VideoForegroundLayer.episodeList,
      VideoForegroundLayer.sidePanel,
      VideoForegroundLayer.immersiveLock,
    ]);

    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(exits, <String>['exit']);
    expect(find.text('fullscreen-route'), findsNothing);
  });

  testWidgets('显式退全屏（Navigator.pop）不经层级表', (WidgetTester tester) async {
    final Set<VideoForegroundLayer> open = <VideoForegroundLayer>{
      VideoForegroundLayer.episodeList,
    };
    final List<VideoForegroundLayer> closed = <VideoForegroundLayer>[];
    final List<bool> mediaKitDidPops = <bool>[];
    final NavigatorState nav = await pumpFullscreenRoute(
      tester,
      open: open,
      closed: closed,
      mediaKitDidPops: mediaKitDidPops,
      exits: <String>[],
    );

    nav.pop();
    await tester.pumpAndSettle();
    expect(find.text('fullscreen-route'), findsNothing);
    expect(closed, isEmpty);
    expect(mediaKitDidPops, <bool>[true]);
  });

  test('视频页把本层挂进全屏路由、显式退全屏走 Navigator.pop', () {
    final String src = File(
      'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
    ).readAsStringSync();
    expect(src, contains('VideoFullscreenBackScope('));
    expect(src, contains('dismissTopLayer: _dismissTopForegroundLayer'));
    // 显式退全屏若仍走 maybePop，会被本层当成「返回上一级」先去关面板。
    // 只有全屏路由不是栈顶（上面压着对话框）时才保留 maybePop。
    expect(
      RegExp(
        r'if \(_videoFullscreenRoute\?\.isCurrent \?\? false\) \{\s*'
        r'navigator\.pop\(\);',
      ).hasMatch(src),
      isTrue,
    );
  });

  test('vendored media_kit 的全屏 PopScope 只在 didPop 为真时退原生全屏', () {
    final String src = File(
      '../third_party/media_kit_video/lib/media_kit_video_controls/src/'
      'controls/widgets/fullscreen_inherited_widget.dart',
    ).readAsStringSync();
    expect(
      RegExp(
        r'onPopInvokedWithResult:\s*\(bool didPop, Object\? _\)\s*\{\s*'
        r'(//[^\n]*\n\s*)*if \(!didPop\) return;',
      ).hasMatch(src),
      isTrue,
      reason: 'canPop=false 的拦截也会通知 media_kit（didPop=false），它不能借机退原生全屏',
    );
  });
}
