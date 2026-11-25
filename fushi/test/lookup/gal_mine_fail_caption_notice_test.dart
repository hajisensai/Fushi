import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/overlay_queued_mines.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';
import 'package:material_ui/material_ui.dart';

/// 拍板台 pr4413-mine-fail-closed-card（选 b）：gal 查词后台写卡失败时，发起它的查词卡
/// 若已关（用户挖完就关卡、继续推剧情），把失败闪在游戏内台词浮窗上——全屏游戏里主窗
/// toast 看不见，推回查词卡的那一推也落空了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const GlobalLookupRoute galRoute = GlobalLookupRoute.galCard(
    routeEpoch: 3,
    lookupEpoch: 7,
  );
  const Map<String, Object?> failedReply = <String, Object?>{
    'ankiConnect': false,
    'noteId': null,
    'message': 'Anki 没开',
  };

  setUp(() {
    OverlayQueuedMines.debugReset();
    OverlayQueuedMines.debugPusher =
        (GlobalLookupRoute route, Map<String, Object?> json) async {};
  });

  tearDown(() {
    OverlayQueuedMines.debugReset();
    MineNotices.filter = (MineToastStatus _) => true;
  });

  QueuedMineTicket begin({bool Function()? originOnScreen}) =>
      OverlayQueuedMines.begin(
        expression: '猫',
        reading: 'ねこ',
        route: galRoute,
        originOnScreen: originOnScreen,
      );

  group('OverlayQueuedMines.unseenFailure', () {
    test('card closed + failure → reported with the host reason', () {
      final QueuedMineSettlement? unseen = OverlayQueuedMines.unseenFailure(
        begin(originOnScreen: () => false),
        failedReply,
      );
      expect(unseen, isNotNull);
      expect(unseen!.outcome, QueuedMineOutcome.failed);
      expect(unseen.expression, '猫');
      expect(unseen.message, 'Anki 没开');
    });

    test('card still on screen → the card says it in place, no flash', () {
      expect(
        OverlayQueuedMines.unseenFailure(
          begin(originOnScreen: () => true),
          failedReply,
        ),
        isNull,
      );
    });

    test('the probe is asked when the write SETTLES, not when it began', () {
      bool onScreen = true;
      final QueuedMineTicket ticket = begin(originOnScreen: () => onScreen);
      // 用户挖完就关卡：排队那一刻卡还在，落地时已不在。
      onScreen = false;
      expect(OverlayQueuedMines.unseenFailure(ticket, failedReply), isNotNull);
    });

    test('no probe given → treated as on screen (never guesses)', () {
      expect(OverlayQueuedMines.unseenFailure(begin(), failedReply), isNull);
    });

    test('landed / duplicate / still offline-queued are not failures', () {
      final QueuedMineTicket ticket = begin(originOnScreen: () => false);
      for (final Map<String, Object?> reply in <Map<String, Object?>>[
        <String, Object?>{'ankiConnect': true, 'noteId': 9},
        <String, Object?>{
          'ankiConnect': false,
          'duplicate': true,
          'message': '重复卡片',
        },
        <String, Object?>{'ankiConnect': false, 'queued': true},
      ]) {
        expect(
          OverlayQueuedMines.unseenFailure(ticket, reply),
          isNull,
          reason: '$reply',
        );
      }
    });

    test('the user muted failure notices → nothing flashes either', () {
      MineNotices.filter = (MineToastStatus status) =>
          status != MineToastStatus.failed;
      expect(
        OverlayQueuedMines.unseenFailure(
          begin(originOnScreen: () => false),
          failedReply,
        ),
        isNull,
      );
    });
  });

  group('galHookNoticeColors', () {
    test('no theme → M3 baseline error red, opaque', () {
      expect(galHookNoticeColors(null), (
        background: 0xFFB3261E,
        text: 0xFFFFFFFF,
      ));
    });

    test('MD3 → errorContainer / onErrorContainer, forced opaque', () {
      final ThemeData theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
      );
      final GalHookNoticeColors colors = galHookNoticeColors(theme);
      expect(
        colors.background,
        0xFF000000 | (theme.colorScheme.errorContainer.toARGB32() & 0xFFFFFF),
      );
      expect(
        colors.text,
        0xFF000000 | (theme.colorScheme.onErrorContainer.toARGB32() & 0xFFFFFF),
      );
    });

    test('e-ink → black on white text', () {
      final ThemeData theme = ThemeData(
        extensions: const <ThemeExtension<dynamic>>[FushiEinkTheme(true)],
      );
      expect(galHookNoticeColors(theme), (
        background: 0xFF000000,
        text: 0xFFFFFFFF,
      ));
    });
  });

  group('flashNotice channel', () {
    const MethodChannel channel = MethodChannel(
      'app.fushi.reader/gal_hook_text',
    );
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      GalHookTextOverlayChannel.platformOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      GalHookTextOverlayChannel.platformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('carries text, ARGB colours and the three motion phases', () async {
      await GalHookTextOverlayChannel.flashNotice(
        text: '「猫」没写进 Anki：Anki 没开',
        backgroundColor: 0xFFB3261E,
        textColor: 0xFFFFFFFF,
        enterMs: 325,
        holdMs: 8000,
        exitMs: 165,
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'flashNotice');
      expect(calls.single.arguments, <String, Object?>{
        'text': '「猫」没写进 Anki：Anki 没开',
        'bgColor': 0xFFB3261E,
        'textColor': 0xFFFFFFFF,
        'enterMs': 325,
        'holdMs': 8000,
        'exitMs': 165,
      });
    });

    test('empty text / unsupported platform send nothing', () async {
      await GalHookTextOverlayChannel.flashNotice(
        text: '',
        backgroundColor: 0,
        textColor: 0,
        enterMs: 0,
        holdMs: 0,
        exitMs: 0,
      );
      GalHookTextOverlayChannel.platformOverride = false;
      await GalHookTextOverlayChannel.flashNotice(
        text: 'x',
        backgroundColor: 0,
        textColor: 0,
        enterMs: 0,
        holdMs: 0,
        exitMs: 0,
      );
      expect(calls, isEmpty);
    });
  });

  group('wiring (Windows)', () {
    String read(String path) => File(path).readAsStringSync();

    test('the gal controller flashes unseen background-write failures', () {
      final String src = read(
        'lib/src/lookup/gal_hook_text_overlay_controller.dart',
      );
      // 判据是派发时捕获的查词 route 在落地那一刻是否仍有效（关卡 / 换词都会作废它）。
      expect(
        src,
        contains('GlobalLookupController.instance.mineOriginOnScreen(origin)'),
      );
      expect(src, contains('OverlayQueuedMines.unseenFailure('));
      expect(src, contains('GalHookTextOverlayChannel.flashNotice('));
      // 时长取动效 token，不另立常量。
      expect(src, contains('FushiMotion.medium.inMilliseconds'));
      expect(src, contains('FushiNoticeDwell.mineFailed.inMilliseconds'));
    });

    test('native routes flashNotice to the caption window', () {
      expect(
        read('windows/runner/flutter_window.cpp'),
        contains('gal_hook_text_window_->FlashNotice('),
      );
      final String window = read('windows/runner/floating_lyric_window.cpp');
      // 隐藏时清掉：浮窗重新显示时不冒出一条过期的失败。
      expect(
        RegExp(
          r'void FloatingLyricWindow::Hide\(\) \{[^}]*ClearNotice\(\);',
        ).hasMatch(window),
        isTrue,
      );
      // 点胶囊只收起它，排在按钮 / 查词 / 拖窗之前。
      final int dismiss = window.indexOf('DismissNotice();\n        return 0;');
      final int controls = window.indexOf(
        'const std::string action = ControlActionAt(x, y);',
      );
      expect(dismiss, greaterThan(0));
      expect(dismiss, lessThan(controls));
    });
  });
}
