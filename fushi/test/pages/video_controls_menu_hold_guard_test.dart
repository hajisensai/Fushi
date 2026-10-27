import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 反馈 eeWvjG93_d（Windows 视频播放器）：点控制条右下的「⋯」打开溢出菜单，菜单
/// 弹出的同一帧整条控制条（连同「⋯」本身）消失。
///
/// 根因：菜单是一条 popup 路由，它的 modal barrier 盖满整页。`MouseTracker` 在帧尾
/// 对静止的鼠标重新命中，命中链里不再有 media_kit 桌面控制条的 `MouseRegion`，于是
/// 它收到 `onExit` → fork 的 `onExit()` 把 `visible` 置 false；移动端则是自动隐藏
/// Timer 在菜单开着时照样到点。
///
/// 修复：fork 两端各加 `holdVisible`（`ValueListenable<bool>`），为 true 时指针离开与
/// 自动隐藏 Timer 都不收控制条，放开时按 hover 重新倒计时；视频页把
/// [VideoControlBar.onMenuOpenChanged] 接到 `_controlsHeld`，再把它装进两端
/// theme 的 `holdVisible`。
///
/// 三层守卫：
/// ① 机制层：纯框架部件证明「从按钮弹出菜单 → 底下的 MouseRegion 立刻 onExit」
///    （fork 的 media_kit 控制条需要 libmpv，headless 跑不了，只能证明触发机制本身）。
/// ② fork 源码守卫：`holdVisible` 字段 / 构造 / copyWith、绑定解绑、MouseRegion
///    onExit 与每个自动隐藏 Timer 都先看 `_held`。
/// ③ 页面源码守卫：两端 theme 装配 `holdVisible: _controlsHeld`，每条
///    `VideoControlBar` 都接了 `onMenuOpenChanged` 与 `singleActionButtonBuilder`。
void main() {
  group('机制：从控制条弹出菜单会让底下的 MouseRegion onExit', () {
    testWidgets('鼠标停在按钮上弹出 popup 菜单 → MouseRegion 收到 onExit', (
      WidgetTester tester,
    ) async {
      int exits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MouseRegion(
              onExit: (_) => exits++,
              child: Center(
                child: Builder(
                  builder: (BuildContext context) => ElevatedButton(
                    onPressed: () => showMenu<int>(
                      context: context,
                      position: const RelativeRect.fromLTRB(100, 100, 100, 100),
                      items: const <PopupMenuEntry<int>>[
                        PopupMenuItem<int>(value: 1, child: Text('speed')),
                      ],
                    ),
                    child: const Text('more'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('more')));
      await tester.pump();
      expect(exits, 0);

      await tester.tap(find.text('more'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('speed'), findsOneWidget);
      expect(
        exits,
        greaterThan(0),
        reason: '菜单 barrier 盖住整页，静止的鼠标被判离开控制条——这就是控制条消失的触发点',
      );
    });
  });

  group('fork 源码守卫：holdVisible', () {
    String readFork(String name) => File(
      '../third_party/media_kit_video/lib/media_kit_video_controls/src/controls/$name',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    for (final String name in <String>[
      'material_desktop.dart',
      'material.dart',
    ]) {
      test('$name：theme 暴露 holdVisible，State 绑定 / 解绑', () {
        final String fork = readFork(name);
        expect(
          containsCodeLine(fork, 'final ValueListenable<bool>? holdVisible;'),
          isTrue,
        );
        expect(containsCodeLine(fork, 'this.holdVisible,'), isTrue);
        expect(
          containsCodeLine(fork, 'ValueListenable<bool>? holdVisible,'),
          isTrue,
          reason: 'copyWith 参数',
        );
        expect(
          containsCodeLine(
            fork,
            'holdVisible: holdVisible ?? this.holdVisible,',
          ),
          isTrue,
        );
        expect(
          containsCodeLine(fork, '_holdVisible?.addListener(_onHoldChanged);'),
          isTrue,
        );
        expect(
          containsCodeLine(
            fork,
            '_holdVisible?.removeListener(_onHoldChanged);',
          ),
          isTrue,
        );
      });

      test('$name：每个自动隐藏 Timer 都先看 _held', () {
        final String fork = maskComments(readFork(name));
        // 自动隐藏的唯一形态：Timer 回调里 `visible = false`。凡是在 Timer 回调里
        // 收起控制条的地方，判据都必须带 `!_held`。
        final RegExp unguarded = RegExp(
          r'Timer\([^;]*?\{\s*if \(mounted\) \{\s*setState\(\(\) \{\s*visible = false;',
          dotAll: true,
        );
        expect(unguarded.hasMatch(fork), isFalse);
        expect(
          RegExp(r'if \(mounted && !_held\) \{').allMatches(fork).length,
          4,
        );
      });
    }

    test('桌面：MouseRegion 的 onExit 在 hold 期间不收控制条', () {
      final String fork = readFork('material_desktop.dart');
      expect(containsCodeLine(fork, 'onExit: (_) => onExit(),'), isFalse);
      final int at = fork.indexOf('onExit: (_) {');
      expect(at, greaterThan(0));
      expect(fork.substring(at, at + 120), contains('if (_held) return;'));
    });
  });

  group('页面源码守卫：菜单开着时按住控制条 + 只有一项不弹菜单', () {
    late String src;
    setUpAll(() => src = readVideoFushiSource());

    test('两端 theme 都装配 holdVisible: _controlsHeld', () {
      final String desktop = methodBody(
        src,
        'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(',
      );
      expect(containsCodeLine(desktop, 'holdVisible: _controlsHeld,'), isTrue);
      final String mobile = methodBody(
        src,
        'MaterialVideoControlsThemeData _mobileControlsTheme(',
      );
      expect(containsCodeLine(mobile, 'holdVisible: _controlsHeld,'), isTrue);
    });

    test('每条 VideoControlBar 都接了菜单开关回调与单项按钮', () {
      final int bars = RegExp(r'VideoControlBar\(').allMatches(src).length;
      expect(bars, greaterThan(0));
      expect(
        RegExp(
          r'onMenuOpenChanged: _onVideoBarMenuOpenChanged,',
        ).allMatches(src).length,
        bars,
      );
      expect(
        RegExp(r'singleActionButtonBuilder: \(').allMatches(src).length,
        bars,
      );
    });
  });
}
