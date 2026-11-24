import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/overlay_bridge_handlers.dart';
import 'package:fushi/src/lookup/overlay_queued_mines.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

/// review-gal-overlay-mine-fail：gal 查词制卡后台写卡的结局要推回发起它的查词卡
/// （全屏游戏里看不见主窗 toast，回退 BUG-1908），同一弹窗再点 ✓ 的 queueOverwrite
/// 要如实回答（以前 native 即时回 null，写卡早已失败也一直说「还在写入」）。
void main() {
  const GlobalLookupRoute galRoute = GlobalLookupRoute.galCard(
    routeEpoch: 3,
    lookupEpoch: 7,
  );
  final List<(GlobalLookupRoute, Map<String, Object?>)> pushed =
      <(GlobalLookupRoute, Map<String, Object?>)>[];

  setUp(() {
    OverlayQueuedMines.debugReset();
    pushed.clear();
    OverlayQueuedMines.debugPusher =
        (GlobalLookupRoute route, Map<String, Object?> json) async =>
            pushed.add((route, json));
  });

  tearDown(() {
    OverlayQueuedMines.debugReset();
    MineNotices.filter = (MineToastStatus _) => true;
  });

  group('QueuedMineSettlement.fromPopupReply', () {
    test('success → landed with the real note id', () {
      final QueuedMineSettlement? s = QueuedMineSettlement.fromPopupReply(
        <String, Object?>{'ankiConnect': true, 'noteId': 42},
        expression: '猫',
        reading: 'ねこ',
      );
      expect(s!.toJson(), <String, Object?>{
        'expression': '猫',
        'reading': 'ねこ',
        'outcome': 'landed',
        'noteId': 42,
      });
    });

    test('failure carries the host reason', () {
      final QueuedMineSettlement? s = QueuedMineSettlement.fromPopupReply(
        <String, Object?>{
          'ankiConnect': false,
          'noteId': null,
          'message': 'Anki 没开',
        },
        expression: '猫',
        reading: '',
      );
      expect(s!.outcome, QueuedMineOutcome.failed);
      expect(s.message, 'Anki 没开');
    });

    test('duplicate is its own outcome; muted duplicate notice drops the '
        'reason', () {
      final Map<String, Object?> reply = <String, Object?>{
        'ankiConnect': false,
        'duplicate': true,
        'message': '重复卡片',
      };
      expect(
        QueuedMineSettlement.fromPopupReply(
          reply,
          expression: '猫',
          reading: '',
        )!.toJson(),
        <String, Object?>{
          'expression': '猫',
          'reading': '',
          'outcome': 'duplicate',
          'message': '重复卡片',
        },
      );
      MineNotices.filter = (MineToastStatus status) =>
          status != MineToastStatus.duplicate;
      final QueuedMineSettlement muted = QueuedMineSettlement.fromPopupReply(
        reply,
        expression: '猫',
        reading: '',
      )!;
      expect(muted.outcome, QueuedMineOutcome.duplicate);
      expect(muted.message, isNull);
    });

    test('still in the offline send queue → nothing to settle', () {
      expect(
        QueuedMineSettlement.fromPopupReply(
          <String, Object?>{'ankiConnect': false, 'queued': true},
          expression: '猫',
          reading: '',
        ),
        isNull,
      );
    });
  });

  group('OverlayQueuedMines', () {
    test(
      'settle pushes the outcome back to the ORIGIN overlay route',
      () async {
        final QueuedMineTicket ticket = OverlayQueuedMines.begin(
          expression: '猫',
          reading: 'ねこ',
          route: galRoute,
        );
        await OverlayQueuedMines.settle(ticket, <String, Object?>{
          'ankiConnect': false,
          'message': 'Anki 没开',
        });
        expect(pushed, hasLength(1));
        expect(pushed.single.$1, galRoute);
        expect(pushed.single.$2, <String, Object?>{
          'expression': '猫',
          'reading': 'ねこ',
          'outcome': 'failed',
          'message': 'Anki 没开',
        });
      },
    );

    test(
      'queueOverwrite answers pending / failed / landed truthfully',
      () async {
        expect(
          OverlayQueuedMines.queueOverwriteReply(
            expression: '猫',
            reading: 'ねこ',
          ).toJson(),
          <String, Object?>{'accepted': false},
          reason: '台账里没有：不收，popup.js 说「还在写入」',
        );
        final QueuedMineTicket ticket = OverlayQueuedMines.begin(
          expression: '猫',
          reading: 'ねこ',
          route: galRoute,
        );
        expect(
          OverlayQueuedMines.queueOverwriteReply(
            expression: '猫',
            reading: 'ねこ',
          ).toJson(),
          <String, Object?>{'accepted': false},
          reason: '还在写：不收（gal 覆写要重抓画面），落地时宿主会推结局',
        );
        await OverlayQueuedMines.settle(ticket, <String, Object?>{
          'ankiConnect': false,
          'message': 'Anki 没开',
        });
        expect(
          OverlayQueuedMines.queueOverwriteReply(
            expression: '猫',
            reading: 'ねこ',
          ).toJson(),
          <String, Object?>{
            'accepted': false,
            'message': 'Anki 没开',
            'settled': 'failed',
          },
          reason: '写卡早已失败：不能再说「还在写入」',
        );

        final QueuedMineTicket again = OverlayQueuedMines.begin(
          expression: '猫',
          reading: 'ねこ',
          route: galRoute,
        );
        await OverlayQueuedMines.settle(again, <String, Object?>{
          'ankiConnect': true,
          'noteId': 9,
        });
        expect(
          OverlayQueuedMines.queueOverwriteReply(
            expression: '猫',
            reading: 'ねこ',
          ).settled,
          QueuedOverwriteSettled.landed,
        );
      },
    );

    test('a superseded ticket still pushes but does not overwrite the newer '
        'pending entry', () async {
      final QueuedMineTicket first = OverlayQueuedMines.begin(
        expression: '猫',
        reading: '',
        route: galRoute,
      );
      OverlayQueuedMines.begin(expression: '猫', reading: '', route: galRoute);
      await OverlayQueuedMines.settle(first, <String, Object?>{
        'ankiConnect': false,
        'message': 'old failure',
      });
      expect(pushed, hasLength(1), reason: '旧按钮若还在也要撤「已加入」');
      expect(
        OverlayQueuedMines.queueOverwriteReply(
          expression: '猫',
          reading: '',
        ).settled,
        isNull,
        reason: '新那次还在写',
      );
    });

    test('offline-queued reply neither pushes nor settles', () async {
      final QueuedMineTicket ticket = OverlayQueuedMines.begin(
        expression: '猫',
        reading: '',
        route: galRoute,
      );
      await OverlayQueuedMines.settle(ticket, <String, Object?>{
        'ankiConnect': false,
        'queued': true,
      });
      expect(pushed, isEmpty);
    });

    test('a failing push is swallowed (the main-window toast already said '
        'it)', () async {
      OverlayQueuedMines.debugPusher = (_, _) async => throw StateError('x');
      final QueuedMineTicket ticket = OverlayQueuedMines.begin(
        expression: '猫',
        reading: '',
        route: galRoute,
      );
      await expectLater(
        OverlayQueuedMines.settle(ticket, <String, Object?>{
          'ankiConnect': true,
        }),
        completes,
      );
    });
  });

  group('deferred queueOverwrite bridge', () {
    test('is handled and always resolved with a non-null reply', () async {
      final List<(int, Object?)> resolved = <(int, Object?)>[];
      final bool handled = maybeHandleOverlayDeferredBridge(
        model: null,
        handler: 'queueOverwrite',
        message: <String, Object?>{
          'handler': 'queueOverwrite',
          '__bridgeId': 5,
          'args': <Object?>[
            <String, Object?>{'expression': '猫', 'reading': 'ねこ'},
          ],
        },
        resolveBridge: (int id, Object? value) async =>
            resolved.add((id, value)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(handled, isTrue);
      expect(resolved, hasLength(1));
      expect(resolved.single.$1, 5);
      expect(resolved.single.$2, <String, Object?>{'accepted': false});
    });

    test('blank expression → plain refusal', () {
      expect(
        queueOverwriteBridgeReply(const <Object?, Object?>{}).toJson(),
        <String, Object?>{'accepted': false},
      );
    });
  });

  group('native + host wiring (Windows)', () {
    String read(String path) => File(path).readAsStringSync();

    test('queueOverwrite is DEFERRED by the Windows bridge router', () {
      expect(
        read('windows/runner/global_lookup_window.cpp'),
        contains(r'body.find("\"queueOverwrite\"")'),
        reason: '不 defer = native 即时回 null，弹窗永远说「还在写入」',
      );
    });

    test('settleQueuedMine travels Dart → native → host → popup.js', () {
      expect(
        read('lib/src/lookup/overlay_window_channel.dart'),
        contains("'settleQueuedMine'"),
      );
      expect(
        read('windows/runner/flutter_window.cpp'),
        contains('method == "settleQueuedMine"'),
      );
      expect(
        read('windows/runner/global_lookup_window.cpp'),
        contains('window.__globalLookupHost.settleQueuedMine('),
      );
      expect(
        read('assets/popup/global_lookup_host.js'),
        contains('settleQueuedMine: settleQueuedMine,'),
      );
      expect(
        read('assets/popup/popup.js'),
        contains('window.fushiSettleQueuedMine = settleQueuedMine;'),
      );
    });

    test('the gal controller settles every background lookup mine', () {
      final String src = read(
        'lib/src/lookup/gal_hook_text_overlay_controller.dart',
      );
      expect(src, contains('OverlayQueuedMines.begin('));
      expect(src, contains('OverlayQueuedMines.settle(queued, reply)'));
    });
  });
}
