// 墨水屏「每 N 页全刷」（拍板台 oF0jVdOTIE）：计数 / 方式选择 / 黑屏闪刷画布的行为，
// 以及小说三种 view mode、漫画、根 Stack、Android 通道的接线。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/reader/eink_full_refresh.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:material_ui/material_ui.dart';

class _FakeDevice implements EinkDeviceRefresher {
  _FakeDevice({required this.supported});

  bool supported;
  int calls = 0;

  @override
  Future<bool> fullRefresh() async {
    calls++;
    return supported;
  }
}

/// 可手动放行的「等新帧画上屏」：测试逐步推进全刷流程。
class _Frames {
  final List<Completer<void>> pending = <Completer<void>>[];

  Future<void> wait() {
    final Completer<void> c = Completer<void>();
    pending.add(c);
    return c.future;
  }

  Future<void> releaseAll() async {
    while (pending.isNotEmpty) {
      pending.removeAt(0).complete();
      await pumpEventQueue();
    }
  }
}

void main() {
  late int interval;
  late EinkFullRefreshMethod method;
  late _FakeDevice device;
  late _Frames frames;
  late EinkFullRefreshController controller;

  EinkFullRefreshController build() => EinkFullRefreshController(
    settings: () => (interval: interval, method: method),
    device: device,
    flashHold: Duration.zero,
    awaitPainted: frames.wait,
  );

  setUp(() {
    interval = 3;
    method = EinkFullRefreshMethod.auto;
    device = _FakeDevice(supported: true);
    frames = _Frames();
    controller = build();
  });

  tearDown(() => controller.dispose());

  group('计数', () {
    test('每 N 次翻页触发一次，之后从头数', () async {
      final List<bool> fired = <bool>[];
      for (int i = 0; i < 7; i++) {
        fired.add(controller.notePageTurn());
        // 真实翻页之间新页早已画上屏，上一次全刷不会还在飞。
        await frames.releaseAll();
      }
      expect(fired, <bool>[false, false, true, false, false, true, false]);
      expect(device.calls, 2);
    });

    test('间隔 0（关）不触发，且清零计数：重新打开后不会立刻闪', () async {
      controller.notePageTurn();
      controller.notePageTurn();
      interval = 0;
      expect(controller.notePageTurn(), isFalse);
      interval = 3;
      expect(controller.notePageTurn(), isFalse);
      expect(controller.notePageTurn(), isFalse);
      expect(controller.notePageTurn(), isTrue);
      await frames.releaseAll();
      expect(device.calls, 1);
    });

    test('上一次全刷还没做完时到点的这一次跳过，不排队补刷', () async {
      interval = 1;
      expect(controller.notePageTurn(), isTrue);
      // 第一次还卡在「等新页画上屏」。
      expect(controller.notePageTurn(), isFalse);
      await frames.releaseAll();
      expect(device.calls, 1);
      expect(controller.notePageTurn(), isTrue);
      await frames.releaseAll();
      expect(device.calls, 2);
    });

    test('间隔存储值归一：负数 = 关，过大钳到上限', () {
      expect(normalizeEinkFullRefreshInterval(-4), 0);
      expect(normalizeEinkFullRefreshInterval(0), 0);
      expect(normalizeEinkFullRefreshInterval(5), 5);
      expect(
        normalizeEinkFullRefreshInterval(100000),
        kEinkFullRefreshIntervalMax,
      );
    });
  });

  group('方式', () {
    test('自动 + 设备支持：走厂商全刷，不闪黑', () async {
      interval = 1;
      final List<bool> flashes = <bool>[];
      controller.flashing.addListener(
        () => flashes.add(controller.flashing.value),
      );
      controller.notePageTurn();
      // 先等新页画上屏，之后才请求设备全刷。
      expect(device.calls, 0);
      await frames.releaseAll();
      expect(device.calls, 1);
      expect(flashes, isEmpty);
    });

    test('自动 + 设备不支持：退回黑屏闪刷，闪完撤掉', () async {
      interval = 1;
      device.supported = false;
      final List<bool> flashes = <bool>[];
      controller.flashing.addListener(
        () => flashes.add(controller.flashing.value),
      );
      controller.notePageTurn();
      await frames.releaseAll();
      await pumpEventQueue();
      expect(device.calls, 1);
      expect(flashes, <bool>[true, false]);
      expect(controller.flashing.value, isFalse);
    });

    test('黑屏闪刷方式：不问设备，直接闪', () async {
      interval = 1;
      method = EinkFullRefreshMethod.flash;
      final List<bool> flashes = <bool>[];
      controller.flashing.addListener(
        () => flashes.add(controller.flashing.value),
      );
      controller.notePageTurn();
      await frames.releaseAll();
      await pumpEventQueue();
      expect(device.calls, 0);
      expect(flashes, <bool>[true, false]);
    });

    test('持久化名冻结：auto / flash，未知值回落自动', () {
      expect(EinkFullRefreshMethod.auto.storageKey, 'auto');
      expect(EinkFullRefreshMethod.flash.storageKey, 'flash');
      expect(
        EinkFullRefreshMethod.fromStorageKey('flash'),
        EinkFullRefreshMethod.flash,
      );
      expect(
        EinkFullRefreshMethod.fromStorageKey('bogus'),
        EinkFullRefreshMethod.auto,
      );
      expect(
        EinkFullRefreshMethod.fromStorageKey(null),
        EinkFullRefreshMethod.auto,
      );
    });
  });

  group('黑屏闪刷画布', () {
    testWidgets('闪刷期间整屏纯黑且不吃指针，平时为空', (WidgetTester tester) async {
      interval = 1;
      method = EinkFullRefreshMethod.flash;
      final Completer<void> hold = Completer<void>();
      int painted = 0;
      final EinkFullRefreshController host = EinkFullRefreshController(
        settings: () => (interval: interval, method: method),
        device: device,
        flashHold: Duration.zero,
        awaitPainted: () {
          painted++;
          // 第二次等待 = 黑帧已上屏，停在这里检查画面。
          return painted == 2 ? hold.future : Future<void>.value();
        },
      );
      addTearDown(host.dispose);
      int taps = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox.expand(),
              ),
              EinkFullRefreshHost(controller: host),
            ],
          ),
        ),
      );
      expect(find.byType(ColoredBox), findsNothing);

      host.notePageTurn();
      // 第一帧里跑完「等新页上屏」的续体、把 flashing 置 true；第二帧画出黑帧。
      await tester.pump();
      await tester.pump();
      final Finder black = find.byWidgetPredicate(
        (Widget w) => w is ColoredBox && w.color == const Color(0xFF000000),
      );
      expect(black, findsOneWidget);
      expect(
        tester.getSize(black),
        tester.view.physicalSize / tester.view.devicePixelRatio,
      );
      await tester.tapAt(const Offset(20, 20));
      expect(taps, 1, reason: '黑帧不得拦截点击');

      hold.complete();
      await tester.pump();
      // 停留计时器（Duration.zero）要推进假时钟才会到期。
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(find.byType(ColoredBox), findsNothing);
    });
  });

  group('设置', () {
    test('间隔下拉文案：关 / 每页 / 每 N 页', () {
      expect(einkFullRefreshIntervalLabel(0), isNotEmpty);
      expect(
        einkFullRefreshIntervalLabel(1),
        isNot(einkFullRefreshIntervalLabel(0)),
      );
      expect(einkFullRefreshIntervalLabel(5), contains('5'));
      expect(kEinkFullRefreshIntervalChoices.first, 0);
      expect(kEinkFullRefreshIntervalDefault, 0);
    });

    test('间隔 / 方式是设备本地偏好，不随 Profile 快照', () {
      expect(ProfileKeys.isExcludedPref('eink_full_refresh_interval'), isTrue);
      expect(ProfileKeys.isExcludedPref('eink_full_refresh_method'), isTrue);
    });
  });

  group('接线', () {
    String read(String path) => File(path).readAsStringSync();

    test('小说：分页 / VN 章内翻页、翻页跨章落定、连续滚过一屏各计一页', () {
      final String chrome = read(
        'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
      );
      final int step = chrome.indexOf('Future<void> _paginateStep(');
      expect(step, greaterThan(0));
      final String stepBody = chrome.substring(step, step + 900);
      expect(
        stepBody,
        contains('if (_didScroll(result)) _noteEinkPageTurn();'),
      );

      final String nav = read(
        'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
      );
      expect(
        nav,
        contains('_einkTurnPendingOnContentReady = _navigationFromPageTurn;'),
      );
      final int restore = nav.indexOf('void _onRestoreComplete()');
      final String restoreBody = nav.substring(restore, restore + 1200);
      expect(restoreBody, contains('_noteEinkPageTurn();'));
      expect(nav, contains('appModel.einkFullRefresh.notePageTurn();'));

      final String webview = read(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
      );
      expect(webview, contains("handlerName: 'onEinkScrollPage'"));

      final String js = read('lib/src/reader/reader_pagination_scripts.dart');
      expect(js, contains('this._noteEinkScroll(previous, position);'));
      expect(js, contains("callHandler('onEinkScrollPage')"));
    });

    test('漫画：只在真翻页处计，开章 / 切布局写 _pageNotifier 不计', () {
      final String manga = read(
        'lib/src/media/manga/reader/manga_fushi_page.dart',
      );
      String body(String signature) {
        final int i = manga.indexOf(signature);
        expect(i, greaterThan(0), reason: signature);
        return manga.substring(i, manga.indexOf('\n  }\n', i));
      }

      // _pageNotifier 的监听不计数：开章 / 切单双页 / 切布局都会给它赋值。
      expect(
        body('void _onReaderPageChanged() {'),
        isNot(contains('notePageTurn')),
      );
      expect(
        RegExp(
          r'appModel\.einkFullRefresh\.notePageTurn\(\)',
        ).allMatches(manga).length,
        1,
        reason: '唯一计数入口是 _noteEinkPageTurn',
      );
      for (final String turn in <String>[
        'Future<void> _commitMangaSpread(int target) async {',
        'Future<void> _jumpToPageAnchor(String dir) async {',
        'Future<void> _onMangaScroll(String payloadJson) async {',
      ]) {
        expect(body(turn), contains('_noteEinkPageTurn();'), reason: turn);
      }
      // 换章：翻页撞边界置挂起，新窗口 ready 之后才计。
      expect(
        body('Future<void> _onReachedChapterEdge(int delta) async {'),
        contains('_einkTurnPendingOnWindowReady = true;'),
      );
      final int ready = manga.indexOf(
        '_windowGate.complete(ticket, MangaWindowLoadOutcome.ready);',
      );
      expect(ready, greaterThan(0));
      expect(
        manga.substring(ready, ready + 300),
        contains('_noteEinkPageTurn();'),
      );
    });

    test('根 Stack 最上层挂黑屏闪刷画布', () {
      final String main = read('lib/main.dart');
      expect(
        main,
        contains(
          'EinkFullRefreshHost(\n'
          '                                    controller: appModel.einkFullRefresh,',
        ),
      );
    });

    test('Android 厂商通道：通道名两边一致、MainActivity 已注册', () {
      final String names = read(
        'android/app/src/main/java/app/fushi/reader/constants/ChannelNames.java',
      );
      expect(names, contains('EINK_REFRESH = PREFIX + "/eink_refresh"'));
      final String dart = read('lib/src/utils/misc/channel_constants.dart');
      expect(dart, contains("'\$_prefix/eink_refresh'"));
      final String activity = read(
        'android/app/src/main/java/app/fushi/reader/MainActivity.java',
      );
      expect(
        activity,
        contains('EinkRefreshChannel.registerWith(flutterEngine, this);'),
      );
      final String channel = read(
        'android/app/src/main/java/app/fushi/reader/EinkRefreshChannel.java',
      );
      for (final String probe in <String>[
        '"android.os.EinkManager"',
        '"refreshScreen"',
        '"postInvalidateDelayed"',
        '"android.view.View\$EINK_MODE"',
      ]) {
        expect(channel, contains(probe));
      }
      expect(channel, contains('"fullRefresh"'));
    });
  });
}
