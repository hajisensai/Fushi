// KiriKiri 游戏内查词的 Dart 侧契约测试：hit 事件 → 定位计算 → present 调用。
//
// 这条链跨三个进程（游戏 hook → runner → Dart → runner → hook），中间任何一段把
// 字段名、坐标域或参数形状改掉，症状都是「游戏里点了没反应」或「卡片贴在离谱的位置」，
// 而三边都不会报错。所以这里钉的是**跨边界的形状**，不是某个类的内部实现：
//
//   1. runner→Dart 的 `onGalLookupHit` / `onGalLookupInput` 逐字段解出来是什么；
//   2. 卡片落点由既有的级联定位纯函数算，且**永远整张留在视口内**；
//   3. Dart→runner 的 `galLookupSetEnabled` / `galLookupPresent` /
//      `galLookupDismiss` 方法名与参数键；
//   4. runner 的失败是编码在应答里的 error token，不是异常——不许被吞成"成功"。
//
// 坐标域纪律（错了就是卡片乱跑）：hit 的 glyph/view 与 present 的 anchor 全在**游戏
// primaryLayer 像素**域；卡片尺寸是 WebView 的物理像素。两者同域，全程不乘 dpr；
// runner 再用 view 尺寸把它们一起映射到实际游戏客户区。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/gal_ingame_lookup_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

import '../helpers/test_platform_services.dart';

/// 卡片与被点字形之间的间距（primaryLayer px），与控制器退化分支同值。
const int _kCardGap = 4;

/// 卡片左上角落点。
///
/// **直接调生产实现**，不在测试里转写一份。
///
/// 本次改造里 replay 的判据就是「参照实现」，生产代码的收卡判据改完之后它照样绿——
/// 那种绿只证明参照实现自洽。定位算法同理：转写一份等于把 bug 复制两遍再互相验证。
({int x, int y}) resolveAnchor(GalLookupHit hit, int cardW, int cardH) =>
    GalIngameLookupController.instance.debugResolveAnchor(hit, cardW, cardH);

GalLookupHit _hit({
  int seq = 1,
  String line = 'あいうえおかきくけこ',
  int charIndex = 3,
  int? charCount,
  int glyphX = 400,
  int glyphY = 540,
  int glyphW = 24,
  int glyphH = 26,
  int viewW = 1280,
  int viewH = 720,
  bool submit = true,
}) {
  return GalLookupHit(
    seq: seq,
    line: line,
    charIndex: charIndex,
    charCount: charCount ?? line.length,
    glyphX: glyphX,
    glyphY: glyphY,
    glyphW: glyphW,
    glyphH: glyphH,
    viewW: viewW,
    viewH: viewH,
    submit: submit,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String channelName = 'app.fushi.reader/gal_hook_text';
  const MethodChannel channel = MethodChannel(channelName);
  const MethodChannel globalLookupChannel = MethodChannel(
    'app.fushi.reader/global_lookup',
  );
  const MethodCodec codec = StandardMethodCodec();

  Future<void> invokeFromNative(String method, Object? arguments) async {
    final ByteData data = codec.encodeMethodCall(MethodCall(method, arguments));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channelName, data, (_) {});
  }

  setUp(() => GalHookTextOverlayChannel.platformOverride = true);

  tearDown(() {
    GalHookTextOverlayChannel.clearEventHandlers();
    GalHookTextOverlayChannel.platformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(globalLookupChannel, null);
  });

  group('runner → Dart：命中事件', () {
    test('onGalLookupHit 逐字段解码，整行台词不截断', () async {
      GalLookupHit? received;
      GalHookTextOverlayChannel.setEventHandlers(
        onGalLookupHit: (GalLookupHit hit) => received = hit,
      );

      const String line = 'これは合成された一行のテキストです';
      await invokeFromNative('onGalLookupHit', <String, Object?>{
        'seq': 12,
        'line': line,
        'charIndex': 4,
        'charCount': line.length,
        'glyphX': 512,
        'glyphY': 604,
        'glyphW': 26,
        'glyphH': 28,
        'viewW': 1280,
        'viewH': 720,
        'submit': true,
      });

      expect(received, isNotNull);
      expect(received!.seq, 12);
      expect(received!.line, line, reason: '整行必须原样送达——制卡要整句');
      expect(received!.charIndex, 4);
      expect(received!.charCount, line.length);
      expect(received!.glyphRect, const Rect.fromLTWH(512, 604, 26, 28));
      expect(received!.viewW, 1280);
      expect(received!.viewH, 720);
      expect(received!.submit, isTrue);
      expect(received!.isAddressable, isTrue);
      expect(received!.hasConsistentCharCount, isTrue);
    });

    test('submit=false 是纯悬停，不能被当成点击提交', () async {
      GalLookupHit? received;
      GalHookTextOverlayChannel.setEventHandlers(
        onGalLookupHit: (GalLookupHit hit) => received = hit,
      );
      await invokeFromNative('onGalLookupHit', <String, Object?>{
        'seq': 3,
        'line': 'あいう',
        'charIndex': 1,
        'charCount': 3,
        'submit': false,
      });
      expect(received?.submit, isFalse);
    });

    test('空行命中直接丢弃，不进 handler', () async {
      bool called = false;
      GalHookTextOverlayChannel.setEventHandlers(
        onGalLookupHit: (GalLookupHit hit) => called = true,
      );
      await invokeFromNative('onGalLookupHit', <String, Object?>{
        'seq': 4,
        'line': '',
        'charIndex': 0,
        'charCount': 0,
      });
      expect(called, isFalse, reason: '没有台词就没有可查的东西，不该往下游传空命中');
    });

    test('下标越界是硬门（必须丢），字符数对不上是软门（只记账）', () {
      // 硬门：指不到具体某个字的命中不能往下走，猜出来的下标会让高亮/查词落到无关的字上。
      expect(_hit(line: 'あいうえお', charIndex: 5).isAddressable, isFalse);
      expect(_hit(line: 'あいうえお', charIndex: -1).isAddressable, isFalse);
      expect(_hit(line: 'あいうえお', charIndex: 4).isAddressable, isTrue);
      // 软门：两侧计数单位若哪天漂了，硬丢会让功能静默死掉；越界本身已被硬门挡住。
      expect(
        _hit(line: 'あいうえお', charCount: 99).hasConsistentCharCount,
        isFalse,
      );
      expect(
        _hit(line: 'あいうえお', charCount: 99, charIndex: 2).isAddressable,
        isTrue,
        reason: '字符数对不上不构成丢弃理由——只要下标还指得到字，就照常查',
      );
      expect(_hit(line: 'あいうえお').hasConsistentCharCount, isTrue);
    });

    test('onGalLookupInput 逐字段解码，滚轮负增量不丢符号', () async {
      GalLookupInput? received;
      GalHookTextOverlayChannel.setEventHandlers(
        onGalLookupInput: (GalLookupInput input) => received = input,
      );
      await invokeFromNative('onGalLookupInput', <String, Object?>{
        'seq': 7,
        'x': 31,
        'y': 202,
        'kind': 3,
        'wheel': -120,
        'keys': 8,
      });
      expect(received, isNotNull);
      expect(received!.seq, 7);
      expect(received!.x, 31);
      expect(received!.y, 202);
      expect(received!.kind, 3);
      expect(received!.wheel, -120);
      expect(received!.keys, 8);
    });

    test('onGalLookupInput 保留位图卡外关闭控制 kind', () async {
      GalLookupInput? received;
      GalHookTextOverlayChannel.setEventHandlers(
        onGalLookupInput: (GalLookupInput input) => received = input,
      );
      await invokeFromNative('onGalLookupInput', <String, Object?>{
        'seq': 8,
        'x': 0,
        'y': 0,
        'kind': GalLookupInput.dismissOutsideKind,
        'wheel': 0,
        'keys': 0,
      });
      expect(received, isNotNull);
      expect(received!.kind, GalLookupInput.dismissOutsideKind);
    });
  });

  group('定位：卡片必须整张留在游戏画面里', () {
    const int cardW = 480;
    const int cardH = 320;

    void expectInsideView(({int x, int y}) anchor, GalLookupHit hit) {
      expect(anchor.x, greaterThanOrEqualTo(0));
      expect(anchor.y, greaterThanOrEqualTo(0));
      expect(anchor.x + cardW, lessThanOrEqualTo(hit.viewW));
      expect(anchor.y + cardH, lessThanOrEqualTo(hit.viewH));
    }

    test('字幕在画面上半部时卡片放在字形下方', () {
      final GalLookupHit hit = _hit(glyphX: 600, glyphY: 200, viewH: 720);
      final ({int x, int y}) anchor = resolveAnchor(hit, cardW, cardH);
      expect(anchor.y, greaterThan(hit.glyphY), reason: '下方空间够就放下方，别盖住正在读的那一行');
      expectInsideView(anchor, hit);
    });

    test('字幕贴近底部时卡片翻到字形上方（避让字幕本身）', () {
      final GalLookupHit hit = _hit(glyphX: 600, glyphY: 660, viewH: 720);
      final ({int x, int y}) anchor = resolveAnchor(hit, cardW, cardH);
      expect(
        anchor.y + cardH,
        lessThanOrEqualTo(hit.glyphY + hit.glyphH),
        reason: '下方放不下就必须整张翻到字形上方，而不是压在字幕上',
      );
      expectInsideView(anchor, hit);
    });

    test('字形贴左右边缘时水平钳进视口，不出现负坐标或右溢出', () {
      final GalLookupHit left = _hit(glyphX: 0, glyphY: 300);
      final GalLookupHit right = _hit(glyphX: 1256, glyphY: 300);
      final ({int x, int y}) leftAnchor = resolveAnchor(left, cardW, cardH);
      final ({int x, int y}) rightAnchor = resolveAnchor(right, cardW, cardH);
      // computeFrameRect 自带 screenBorderPadding（默认 6px）的屏边留白，所以"贴边"
      // 是贴到留白处而不是贴到 0。这里只钉方向与不越界，不钉那 6 px 的具体数值。
      const int slack = 8;
      expect(leftAnchor.x, lessThanOrEqualTo(slack));
      expect(rightAnchor.x, greaterThanOrEqualTo(right.viewW - cardW - slack));
      expectInsideView(leftAnchor, left);
      expectInsideView(rightAnchor, right);
    });

    test('卡片比游戏画面还大时贴左上角，绝不给负坐标', () {
      final GalLookupHit hit = _hit(
        viewW: 320,
        viewH: 240,
        glyphX: 100,
        glyphY: 100,
      );
      final ({int x, int y}) anchor = resolveAnchor(hit, cardW, cardH);
      expect(anchor.x, 0);
      expect(anchor.y, 0);
    });

    test('hook 没报视口尺寸时退化成字形正下方，不猜屏幕边界', () {
      final GalLookupHit hit = _hit(
        viewW: 0,
        viewH: 0,
        glyphX: 700,
        glyphY: 640,
      );
      final ({int x, int y}) anchor = resolveAnchor(hit, cardW, cardH);
      expect(anchor.x, 700);
      expect(anchor.y, 640 + 26 + _kCardGap);
    });

    test('同一命中反复算落点结果稳定（纯函数，不许有隐藏状态）', () {
      final GalLookupHit hit = _hit(glyphX: 333, glyphY: 421);
      expect(
        resolveAnchor(hit, cardW, cardH),
        resolveAnchor(hit, cardW, cardH),
      );
    });

    test('nested union anchor = fixed root anchor + union bbox origin', () {
      const ({int x, int y}) root = (x: 1120, y: 64);
      expect(
        offsetGalLookupAnchor(root, -620, 510),
        (x: 500, y: 574),
        reason:
            'growing the union must not recompute placement from union width/height',
      );
      expect(offsetGalLookupAnchor(root, 0, 0), root);
    });
  });

  group('Dart → runner：开关 / 投帧 / 消场', () {
    late List<MethodCall> calls;

    void mockRunner(Object? Function(MethodCall call) reply) {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return reply(call);
          });
    }

    test('galLookupSetEnabled 的方法名与参数键', () async {
      mockRunner((_) => <String, Object?>{});
      final GalLookupCallResult result =
          await GalHookTextOverlayChannel.galLookupSetEnabled(true);
      expect(calls.single.method, 'galLookupSetEnabled');
      expect(calls.single.arguments, <String, Object?>{'enabled': true});
      expect(result.ok, isTrue);
    });

    test('galLookupPresent 送出 anchor / 卡片 / 游戏视口，并识别 direct surface', () async {
      mockRunner(
        (_) => <String, Object?>{
          'width': 480,
          'height': 320,
          'directSurface': true,
        },
      );
      final GalLookupHit hit = _hit(seq: 9, glyphX: 600, glyphY: 200);
      final ({int x, int y}) anchor = resolveAnchor(hit, 480, 320);
      final GalLookupCallResult result =
          await GalHookTextOverlayChannel.galLookupPresent(
            seq: hit.seq,
            anchorX: anchor.x,
            anchorY: anchor.y,
            highlightStart: hit.charIndex,
            highlightLen: 2,
            cardWidth: 480,
            cardHeight: 320,
            viewWidth: hit.viewW,
            viewHeight: hit.viewH,
          );
      expect(calls.single.method, 'galLookupPresent');
      expect(calls.single.arguments, <String, Object?>{
        'seq': 9,
        'anchorX': anchor.x,
        'anchorY': anchor.y,
        'highlightStart': hit.charIndex,
        'highlightLen': 2,
        'cardWidth': 480,
        'cardHeight': 320,
        'viewWidth': 1280,
        'viewHeight': 720,
      });
      expect(result.ok, isTrue);
      expect(result.width, 480);
      expect(result.height, 320);
      expect(result.clamped, isFalse);
      expect(result.directSurface, isTrue);
    });

    test('galLookupDismiss 带上要撤掉的那次命中序号', () async {
      mockRunner((_) => <String, Object?>{});
      await GalHookTextOverlayChannel.galLookupDismiss(9);
      expect(calls.single.method, 'galLookupDismiss');
      expect(calls.single.arguments, <String, Object?>{'seq': 9});
    });

    test('runner 的失败是应答里的 error token，绝不能被当成成功', () async {
      mockRunner((_) => <String, Object?>{'error': 'lookup_region_missing'});
      final GalLookupCallResult result =
          await GalHookTextOverlayChannel.galLookupPresent(
            seq: 1,
            anchorX: 0,
            anchorY: 0,
            highlightStart: 0,
            highlightLen: 1,
            cardWidth: 480,
            cardHeight: 320,
            viewWidth: 1280,
            viewHeight: 720,
          );
      expect(result.ok, isFalse);
      expect(result.error, 'lookup_region_missing');
    });

    test('主路复用 Fushi popup，内嵌模式只隐藏顶部整句横幅', () {
      final String source = File(
        'lib/src/lookup/gal_ingame_lookup_controller.dart',
      ).readAsStringSync();
      expect(source, contains('GlobalLookupController.instance.lookupText('));
      expect(
        source,
        contains('GlobalLookupRoute.galCard('),
        reason: '每次游戏内查词必须分配不可复用的离屏 route token',
      );
      expect(
        source,
        contains('GlobalLookupChannel.runWithRoute('),
        reason: '查词 Future/Timer 必须继承当次 galCard route，不能读进程级可变 target',
      );
      expect(
        source,
        isNot(contains('GlobalLookupChannel.setTarget(')),
        reason: '不得把迟到的旧查词改道到新 surface',
      );
      expect(
        source,
        contains('_finishDisableRouting('),
        reason: '不能在旧 galCard 渲染尚未结束时提前切回桌面，否则迟到 reveal 会形成双弹窗',
      );
      expect(
        source,
        contains('_hideThenInvalidateRoute('),
        reason: '终止必须先隐藏离屏 popup，再废止 route token',
      );
      expect(
        source,
        contains('showSentenceBanner: false'),
        reason: '内嵌模式只隐藏 popup 顶部整句横幅，不能另造一套卡片',
      );
      expect(
        source,
        contains('GalHookTextOverlayChannel.galLookupPresent('),
        reason: '渲染完成后必须请求 runner 呈现同一份 Fushi popup',
      );
      expect(
        source,
        contains('if (_directSurfaceActive) return;'),
        reason: 'composition 上屏后滚动不得再触发整帧 CapturePreview',
      );
      expect(
        source,
        contains('_directSurfaceActive = result.directSurface;'),
        reason: 'direct→bitmap 降级必须恢复 dirty 重抓，不能保留陈旧 direct 状态',
      );
      final int acquireAt = source.indexOf(
        'Future<GalHookCaptureLease> acquireMiningCaptureLease()',
      );
      final int suppressAt = source.indexOf(
        'galLookupSuspendForCapture(hit.seq)',
        acquireAt,
      );
      final int currentRouteAt = source.indexOf(
        'final GlobalLookupRoute hideRoute = _activeRoute ?? route;',
        suppressAt,
      );
      final int directHideAt = source.indexOf(
        'GlobalLookupChannel.hide(notify: false)',
        currentRouteAt,
      );
      final int leaseAt = source.indexOf(
        'return _GalIngameCaptureLease(',
        directHideAt,
      );
      expect(
        acquireAt < suppressAt &&
            suppressAt < currentRouteAt &&
            currentRouteAt < directHideAt &&
            directHideAt < leaseAt,
        isTrue,
        reason: '制卡截图 lease 只能在 hook suppress ack + 当前 direct HWND hide 后发放',
      );
      expect(source, contains('static const int _kCardBitmapBytes ='));
      expect(
        source,
        isNot(contains('galLookupPresentTextCard(')),
        reason: 'v14 主路不再下发结构化 NativeText payload',
      );
    });

    test('enable 失败可重试，迟到回执不能覆盖更新状态', () {
      final String source = File(
        'lib/src/lookup/gal_ingame_lookup_controller.dart',
      ).readAsStringSync();
      final String reader = File(
        'windows/runner/voice_hook_reader.cpp',
      ).readAsStringSync();
      expect(
        source,
        contains('final int generation = ++_enableSyncGeneration;'),
      );
      expect(
        source,
        contains('if (generation != _enableSyncGeneration) continue;'),
      );
      expect(
        source,
        contains('if (result.ok && desired == latestDesired) {'),
        reason: '失败回执不能伪装成已推送，否则同一 active phase 无法重试',
      );
      expect(
        source,
        contains('if (active && !_pushedEnabled) await _syncEnabled();'),
        reason: '成功后的重复 session 通知不得持续占用 Shift 查词热路径',
      );
      expect(
        reader,
        contains('lookup_enabled_desired = enabled;'),
        reason: 'mapping 换代重放意图由持有真实 mapping 身份的 reader 负责',
      );
      expect(reader, contains('if (st.lookup_enabled_desired &&'));
    });

    test('submit 查词是 latest-wins，hover 不作废在途 submit', () {
      final String source = File(
        'lib/src/lookup/gal_ingame_lookup_controller.dart',
      ).readAsStringSync();
      expect(source, contains('if (!hit.submit)'));
      expect(source, contains('final int generation = ++_lookupGeneration;'));
      expect(
        source,
        contains(
          '_pendingLookup = (hit: hit, generation: generation, route: route);',
        ),
      );
      expect(source, contains('generation == _lookupGeneration'));
    });

    test('同句新 lineId 保留 active route，真换句才 dismiss→hide→invalidate', () async {
      final List<String> lifecycle = <String>[];
      final List<MethodCall> globalCalls = <MethodCall>[];
      mockRunner((MethodCall call) {
        lifecycle.add('gal:${call.method}');
        return <String, Object?>{};
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(globalLookupChannel, (
            MethodCall call,
          ) async {
            globalCalls.add(call);
            lifecycle.add('global:${call.method}');
            return null;
          });

      late GlobalLookupRoute activeRoute;
      final GalIngameLookupController controller =
          GalIngameLookupController.test(
            preferenceReader:
                (String key, {required Object? defaultValue}) =>
                    key == GalIngameLookupController.enabledPreferenceKey
                    ? true
                    : defaultValue,
            lookupRunner: (String query, GalLookupHit hit) async {
              activeRoute = GlobalLookupChannel.currentRoute;
              return true;
            },
          );
      try {
        await controller.start(appModel: AppModel(testPlatformServices()));
        await controller.setSessionActive(true);
        final GalLookupHit hit = _hit(seq: 41, line: '同一句台词');
        await controller.handleHit(hit);

        calls.clear();
        globalCalls.clear();
        lifecycle.clear();
        expect(controller.debugActiveHit, same(hit));
        expect(GlobalLookupChannel.isRouteValid(activeRoute), isTrue);

        await controller.onLineChanged('同一句台词');

        expect(
          calls.where((MethodCall call) => call.method == 'galLookupDismiss'),
          isEmpty,
          reason: '人物动画只重发同句 occurrence，不得撤掉游戏内卡片',
        );
        expect(
          globalCalls.where((MethodCall call) => call.method == 'hide'),
          isEmpty,
          reason: '同句重发不得隐藏离屏 WebView，否则 DOM 选区会消失',
        );
        expect(GlobalLookupChannel.isRouteValid(activeRoute), isTrue);
        expect(controller.debugActiveHit, same(hit));

        await controller.onLineChanged('下一句台词');

        expect(lifecycle, <String>['gal:galLookupDismiss', 'global:hide']);
        expect(calls, hasLength(1));
        expect(calls.single.method, 'galLookupDismiss');
        expect(calls.single.arguments, <String, Object?>{'seq': 41});
        expect(globalCalls, hasLength(1));
        final MethodCall hide = globalCalls.single;
        expect(hide.method, 'hide');
        final Map<Object?, Object?> hideArgs =
            hide.arguments as Map<Object?, Object?>;
        expect(hideArgs['notify'], isFalse);
        expect(hideArgs['target'], 'galCard');
        expect(hideArgs['source'], 'galCard');
        expect(hideArgs['routeEpoch'], activeRoute.routeEpoch);
        expect(hideArgs['lookupEpoch'], activeRoute.lookupEpoch);
        expect(GlobalLookupChannel.isRouteValid(activeRoute), isFalse);
        expect(controller.debugActiveHit, isNull);
      } finally {
        await controller.stopForTesting();
      }
    });

    test('非 Windows 上三个调用一律不过桥，返回 unsupported', () async {
      GalHookTextOverlayChannel.platformOverride = false;
      mockRunner((_) => <String, Object?>{});
      expect(
        (await GalHookTextOverlayChannel.galLookupSetEnabled(true)).error,
        'unsupported_platform',
      );
      expect(
        (await GalHookTextOverlayChannel.galLookupPresent(
          seq: 1,
          anchorX: 0,
          anchorY: 0,
          highlightStart: 0,
          highlightLen: 1,
          cardWidth: 480,
          cardHeight: 320,
          viewWidth: 1280,
          viewHeight: 720,
        )).error,
        'unsupported_platform',
      );
      expect(
        (await GalHookTextOverlayChannel.galLookupDismiss(1)).error,
        'unsupported_platform',
      );
      expect(calls, isEmpty, reason: 'galgame hook 只做 Windows，别的平台一个调用都不该发');
    });
  });
}
