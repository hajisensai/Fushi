// macOS 悬浮字幕 / 桌面歌词原生后端（macos/Runner/FushiFloatingLyric.swift）真机取证。
//
// 不起 AppModel、不开数据库：只经真通道 `app.fushi.reader/floating_lyric` 驱动原生
// NSPanel，再经测试钩子通道 `app.fushi.test/floating_lyric`（环境变量
// FUSHI_TEST_FLOATING_LYRIC 门控，生产启动不注册）取窗口事实、送真 NSEvent 点字、
// 走控制器拖动入口。每一步断言 native → Dart 的回传事件真到了。
//
//   ① show + 双行（当前 + 下一行）+ 音节区间高亮 → probe：可见、.statusBar 级、
//      不可成为 key、不抢前台、工具条子窗存在。打印 `[flyric] READY pid=...` 并停留
//      [_hold]，外部脚本用 ~/fushi_smoke/winprobe <pid> 与 screencapture 取证。
//   ② clickChar（真 NSEvent 按下 / 抬起）→ lookupText 带 index 与 wordRect（屏幕逻辑
//      px），wordRect 落在窗口矩形内。
//   ③ dragBy → windowRectChanged（物理 px）与 probe 一致；hide → 以回传矩形 show →
//      恢复到同一矩形（持久化往返）。
//   ④ 工具条：lock → lockChanged(true)；playPause / nextCue → 控制事件；topmost →
//      层级落到 normal。
//   ⑤ setPassThrough(true) → 正文 ignoresMouseEvents、工具条恒显。
//   ⑥ 物理 px 编码自检（合成多屏配置：Retina + 1x 外屏、外屏拔掉）。
//
// Run (Mac, from fushi/):
//   FUSHI_TEST_FLOATING_LYRIC=1 flutter test \
//     integration_test/macos_floating_lyric_itest.dart -d macos

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart'
    show FloatingLyricStyle;
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_style.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

const Duration _hold = Duration(seconds: 20);
const MethodChannel _test = MethodChannel('app.fushi.test/floating_lyric');

const String _current = '目を覚ますと、見知らぬ天井があった。';
const String _next = 'ここは、どこだ？';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS floating lyric panel: show, lookup, drag, restore', (
    WidgetTester tester,
  ) async {
    if (!Platform.isMacOS) {
      markTestSkipped('macOS-only native back-end');
      return;
    }
    expect(FloatingLyricChannel.supported, isTrue);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));

    final List<String> controls = <String>[];
    final List<({String text, int index, Rect? wordRect})> lookups =
        <({String text, int index, Rect? wordRect})>[];
    final List<FloatingLyricWindowRect> bounds = <FloatingLyricWindowRect>[];
    final List<bool> locks = <bool>[];
    final List<bool> passThroughs = <bool>[];
    void handlers() => FloatingLyricChannel.setEventHandlers(
      onLookupText: (String text, int index, Rect? wordRect) =>
          lookups.add((text: text, index: index, wordRect: wordRect)),
      onPreviousCue: () => controls.add('previousCue'),
      onPlayPause: () => controls.add('playPause'),
      onNextCue: () => controls.add('nextCue'),
      onClose: () => controls.add('close'),
      onLockChanged: locks.add,
      onPassThroughChanged: passThroughs.add,
      onBoundsChanged: (int l, int t, int w, int h) => bounds.add(
        FloatingLyricWindowRect(left: l, top: t, width: w, height: h),
      ),
    );

    Future<Map<String, Object?>> probe() async => Map<String, Object?>.from(
      (await _test.invokeMethod<Map<Object?, Object?>>('probe'))!,
    );

    Future<void> settle(bool Function() done) async {
      final DateTime until = DateTime.now().add(const Duration(seconds: 5));
      while (!done() && DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    final FloatingLyricStyle style = buildFloatingLyricStyle(
      theme: ThemeData(brightness: Brightness.dark),
      settings: const FloatingLyricStyleSettings(
        fontSize: 24,
        textOpacity: 100,
        buttonBgOpacity: 100,
        bgOpacity: 85,
        cornerRadius: 14,
        windowWidth: 0,
        outlineWidth: 1.6,
      ),
    );

    Future<bool> show({FloatingLyricWindowRect? rect}) async {
      final bool shown = await FloatingLyricChannel.show(
        fontSize: style.fontSize,
        textColor: style.textColor,
        bgColor: style.bgColor,
        buttonTextColor: style.buttonTextColor,
        buttonBgColor: style.buttonBgColor,
        highlightColor: style.highlightColor,
        activeColor: style.activeColor,
        cornerRadius: style.cornerRadius,
        windowWidth: style.windowWidth,
        slotTooltips: const <String>[
          'Previous',
          'Play / pause',
          'Next',
          'Lock',
          'Always on top',
          'Close',
        ],
        rect: rect,
        styleExtras: style.nativeStyleArgs,
      );
      handlers();
      return shown;
    }

    try {
      // ① 显示 + 双行 + 区间高亮。
      expect(await show(), isTrue);
      const String block = '$_current\n$_next';
      await FloatingLyricChannel.updateText(
        block,
        currentLineStart: 0,
        currentLineLength: _current.length,
      );
      await FloatingLyricChannel.highlight(start: 6, length: 3);
      await FloatingLyricChannel.setPlaybackState(playing: true);
      await tester.pump(const Duration(milliseconds: 300));

      final Map<String, Object?> first = await probe();
      // ignore: avoid_print
      print('[flyric] probe#1 $first');
      expect(first['visible'], isTrue);
      expect(first['level'], 25, reason: 'NSWindow.Level.statusBar');
      expect(first['canBecomeKey'], isFalse);
      expect(first['isKeyWindow'], isFalse);
      expect(first['ignoresMouseEvents'], isFalse);
      expect(first['highlightStart'], 6);
      expect(first['text'], block);
      final bool isFlutterActive = first['appActive'] == true;
      // ignore: avoid_print
      print('[flyric] app active while panel shown: $isFlutterActive');

      // ignore: avoid_print
      print(
        '[flyric] READY pid=$pid window=${first['windowNumber']} '
        'toolbar=${first['toolbarWindowNumber']}',
      );
      final DateTime until = DateTime.now().add(_hold);
      while (DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      // ignore: avoid_print
      print(
        '[flyric] snapshot ready '
        '${await _test.invokeMethod<Object?>('snapshot', <String, Object?>{'tag': 'ready'})}',
      );

      // ② 真 NSEvent 点字 → lookupText（带字的屏幕逻辑 px 矩形）。
      final Map<Object?, Object?>? click = await _test
          .invokeMethod<Map<Object?, Object?>>('clickChar', <String, Object?>{
            'index': 3,
          });
      await settle(() => lookups.isNotEmpty);
      // ignore: avoid_print
      print('[flyric] click=$click lookups=$lookups');
      expect(lookups, hasLength(1));
      expect(lookups.single.index, 3);
      expect(lookups.single.text, block);
      final Rect word = lookups.single.wordRect!;
      final List<double> frame = (first['frameTopLeft']! as List<Object?>)
          .cast<double>();
      final Rect window = Rect.fromLTWH(frame[0], frame[1], frame[2], frame[3]);
      expect(
        window.contains(word.center),
        isTrue,
        reason: 'wordRect $word (screen logical, top-left) must lie in $window',
      );
      expect(word.width, greaterThan(0));
      // ignore: avoid_print
      print(
        '[flyric] wordRect LTWH=${word.left},${word.top},${word.width},'
        '${word.height} window=$frame',
      );
      final Map<String, Object?> afterClick = await probe();
      expect(
        afterClick['appActive'],
        isFalse,
        reason: 'click must not activate',
      );
      expect(afterClick['isKeyWindow'], isFalse);

      // ③ 拖动 → windowRectChanged（物理 px）；hide → 按回传矩形恢复。
      final Map<String, Object?> dragged = Map<String, Object?>.from(
        (await _test.invokeMethod<Map<Object?, Object?>>(
          'dragBy',
          <String, Object?>{'dx': -160, 'dy': -120},
        ))!,
      );
      await settle(() => bounds.isNotEmpty);
      // ignore: avoid_print
      print('[flyric] dragged=$dragged bounds=${bounds.map((b) => b.toMap())}');
      expect(bounds, isNotEmpty);
      final FloatingLyricWindowRect last = bounds.last;
      final List<double> physical = (dragged['physical']! as List<Object?>)
          .cast<double>();
      expect(<int>[
        last.left,
        last.top,
        last.width,
        last.height,
      ], physical.map((double v) => v.round()).toList());
      expect(
        dragged['frameTopLeft'],
        isNot(equals(first['frameTopLeft'])),
        reason: 'drag must move the panel',
      );
      await FloatingLyricChannel.hide();
      expect(await FloatingLyricChannel.isShowing(), isFalse);
      expect(await show(rect: last), isTrue);
      final Map<String, Object?> restored = await probe();
      // ignore: avoid_print
      print('[flyric] restored=$restored');
      expect(restored['physical'], dragged['physical']);

      // ④ 工具条动作。
      await _test.invokeMethod<void>('toolbarAction', <String, Object?>{
        'action': 'lock',
      });
      await _test.invokeMethod<void>('toolbarAction', <String, Object?>{
        'action': 'playPause',
      });
      await _test.invokeMethod<void>('toolbarAction', <String, Object?>{
        'action': 'nextCue',
      });
      await settle(() => locks.isNotEmpty && controls.length >= 2);
      expect(locks, <bool>[true]);
      expect(controls, <String>['playPause', 'nextCue']);
      final Map<String, Object?> unpinned = Map<String, Object?>.from(
        (await _test.invokeMethod<Map<Object?, Object?>>(
          'toolbarAction',
          <String, Object?>{'action': 'topmost'},
        ))!,
      );
      expect(
        unpinned['level'],
        0,
        reason: 'topmost off = NSWindow.Level.normal',
      );
      await _test.invokeMethod<void>('toolbarAction', <String, Object?>{
        'action': 'topmost',
      });

      // ⑤ 穿透：正文整窗点穿，工具条子窗恒显（唯一回退入口）。
      await FloatingLyricChannel.setPassThrough(true);
      await settle(() => passThroughs.isNotEmpty);
      final Map<String, Object?> through = await probe();
      // ignore: avoid_print
      print('[flyric] passThrough=$through events=$passThroughs');
      expect(through['ignoresMouseEvents'], isTrue);
      expect(through['toolbarVisible'], isTrue);
      expect(passThroughs, <bool>[true]);
      // ignore: avoid_print
      print(
        '[flyric] snapshot passthrough '
        '${await _test.invokeMethod<Object?>('snapshot', <String, Object?>{'tag': 'passthrough'})}',
      );
      await FloatingLyricChannel.setPassThrough(false);

      // ⑥ 物理 px 编码自检（合成多屏）。
      final List<Object?> cases = (await _test.invokeMethod<List<Object?>>(
        'screenSpaceSelfTest',
      ))!;
      final Map<String, Map<Object?, Object?>> byName =
          <String, Map<Object?, Object?>>{
            for (final Object? c in cases)
              (c! as Map<Object?, Object?>)['name']! as String:
                  c as Map<Object?, Object?>,
          };
      // ignore: avoid_print
      print('[flyric] screenSpace=$byName');
      for (final String name in <String>[
        'single-retina',
        'dual-on-retina',
        'dual-on-external',
      ]) {
        expect(
          byName[name]!['decodedFrame'],
          byName[name]!['frame'],
          reason: '$name round trip',
        );
      }
      expect(byName['dual-on-external']!['decodedScreen'], 1);
      expect(byName['external-unplugged']!['decodedScreen'], -1);
    } finally {
      FloatingLyricChannel.clearEventHandlers();
      await FloatingLyricChannel.hide();
    }
  });
}
