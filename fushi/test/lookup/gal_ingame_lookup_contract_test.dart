// KiriKiri 游戏内查词的 Dart 侧契约测试：hit 事件 → 定位计算 → present 调用。
//
// 这条链跨三个进程（游戏 hook → runner → Dart → runner → hook），中间任何一段把
// 字段名、坐标域或参数形状改掉，症状都是「游戏里点了没反应」或「卡片贴在离谱的位置」，
// 而三边都不会报错。所以这里钉的是**跨边界的形状**，不是某个类的内部实现：
//
//   1. runner→Dart 的 `onGalLookupHit` / `onGalLookupInput` 逐字段解出来是什么；
//   2. 卡片落点由既有的级联定位纯函数算，且**永远整张留在视口内**；
//   3. Dart→runner 的 runtime / geometry admission / present / dismiss
//      方法名与参数键；
//   4. runner 的失败是编码在应答里的 error token，不是异常——不许被吞成"成功"。
//
// 坐标域纪律（错了就是卡片乱跑）：glyph/view/anchor 要么全在 client physical px，
// 要么全在 primaryLayer px。runner 的直连覆盖窗对两者用**同一套**映射——把 view 等比
// 缩放并居中到游戏客户区，再 ClientToScreen；前者 view 即客户区，scale 恒为 1、信箱边
// 为 0，映射退化成恒等变换，后者（目前只有 KiriKiri）才真正发生缩放。卡片本身**不随
// 画布缩放**：它保持自身物理像素，贴附以字形矩形为基准在屏幕空间重排。
// design/layout-local 没唯一 transform 时必须丢弃；新增该域的适配器会被
// native/galgame_hook/tests/adapter_structure_test.py 的坐标域守卫拦下。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
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
  int coordinateSpace = 2,
  bool submit = true,
}) {
  return GalLookupHit(
    seq: seq,
    line: line,
    providerKind: 1,
    providerId: 1,
    charIndex: charIndex,
    sourceLength: 1,
    charCount: charCount ?? line.length,
    textGeneration: 1,
    geometryGeneration: 1,
    coordinateSpace: coordinateSpace,
    writingMode: 1,
    glyphX: glyphX,
    glyphY: glyphY,
    glyphW: glyphW,
    glyphH: glyphH,
    viewW: viewW,
    viewH: viewH,
    submit: submit,
  );
}

Map<String, Object?> _wireHit({
  String line = '本文',
  int charIndex = 0,
  int sourceLength = 1,
}) => <String, Object?>{
  'seq': 1,
  'line': line,
  'providerKind': 1,
  'providerId': 1,
  'charIndex': charIndex,
  'sourceLength': sourceLength,
  'charCount': line.length,
  'textGeneration': 1,
  'geometryGeneration': 1,
  'coordinateSpace': 2,
  'writingMode': 1,
  'glyphX': 10,
  'glyphY': 10,
  'glyphW': 16,
  'glyphH': 20,
  'viewW': 1280,
  'viewH': 720,
  'submit': true,
};

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

  setUp(() {
    // 门有两半，只覆盖一半等于没覆盖：非 Windows 上 GalIngameLookupController
    // 的 isSupported 仍为 false，start 早退，行为用例全部空转。
    GalHookTextOverlayChannel.platformOverride = true;
    GlobalLookupController.platformOverride = true;
  });

  tearDown(() {
    GalHookTextOverlayChannel.clearEventHandlers();
    GalHookTextOverlayChannel.platformOverride = null;
    GlobalLookupController.platformOverride = null;
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
        'providerKind': 1,
        'providerId': 1,
        'charIndex': 4,
        'sourceLength': 1,
        'charCount': line.length,
        'textGeneration': 7,
        'geometryGeneration': 9,
        'coordinateSpace': 2,
        'writingMode': 1,
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
      expect(received!.providerKind, 1);
      expect(received!.providerId, 1);
      expect(received!.sourceLength, 1);
      expect(received!.textGeneration, 7);
      expect(received!.geometryGeneration, 9);
      expect(received!.coordinateSpace, 2);
      expect(received!.writingMode, 1);
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
        'providerKind': 1,
        'providerId': 1,
        'charIndex': 1,
        'sourceLength': 1,
        'charCount': 3,
        'textGeneration': 1,
        'geometryGeneration': 1,
        'coordinateSpace': 2,
        'writingMode': 1,
        'glyphX': 10,
        'glyphY': 10,
        'glyphW': 10,
        'glyphH': 10,
        'viewW': 100,
        'viewH': 100,
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

    test('BMP 与代理对 cluster 都按 UTF-16 sourceLength 派发', () async {
      final List<GalLookupHit> received = <GalLookupHit>[];
      GalHookTextOverlayChannel.setEventHandlers(onGalLookupHit: received.add);
      await invokeFromNative('onGalLookupHit', _wireHit());
      const String surrogateLine = 'A𠮷B';
      await invokeFromNative(
        'onGalLookupHit',
        _wireHit(line: surrogateLine, charIndex: 1, sourceLength: 2)
          ..['seq'] = 2,
      );

      expect(received, hasLength(2));
      expect(received.first.sourceLength, 1);
      expect(received.last.charIndex, 1);
      expect(received.last.sourceLength, 2);
      expect(received.last.isProductionSane, isTrue);
    });

    test('UTF-16 代理对半区间与非配对代理项 fail-closed', () async {
      int calls = 0;
      GalHookTextOverlayChannel.setEventHandlers(
        onGalLookupHit: (GalLookupHit _) {
          calls++;
        },
      );

      const String supplementary = 'A𠮷B';
      await invokeFromNative(
        'onGalLookupHit',
        _wireHit(line: supplementary, charIndex: 1, sourceLength: 1),
      );
      await invokeFromNative(
        'onGalLookupHit',
        _wireHit(line: supplementary, charIndex: 2, sourceLength: 1),
      );
      final String unpaired = String.fromCharCodes(<int>[0x41, 0xD842, 0x42]);
      expect(calls, 0);
      expect(
        GalLookupHit.fromMap(
          _wireHit(line: unpaired, charIndex: 1, sourceLength: 1),
        )?.isProductionSane,
        isFalse,
      );
    });

    test('错类型、count/range、实验 provider 与陈旧 generation fail-closed', () async {
      final List<GalLookupHit> received = <GalLookupHit>[];
      GalHookTextOverlayChannel.setEventHandlers(onGalLookupHit: received.add);
      final List<Map<String, Object?>> invalid = <Map<String, Object?>>[
        _wireHit()..['charIndex'] = '0',
        _wireHit()..['charCount'] = 99,
        _wireHit()..['sourceLength'] = 99,
        _wireHit()..['providerKind'] = 5,
        _wireHit()..['providerId'] = 12,
        _wireHit()
          ..['providerKind'] = 1
          ..['providerId'] = 3,
        _wireHit()..['textGeneration'] = 0,
        _wireHit()..['geometryGeneration'] = 0,
        _wireHit()..['writingMode'] = 2,
      ];
      for (final Map<String, Object?> payload in invalid) {
        await invokeFromNative('onGalLookupHit', payload);
      }
      expect(received, isEmpty);
    });

    test('production provider whitelist matches native kind/id pairs', () {
      expect(isGalLookupProductionProviderPair(1, 1), isTrue);
      expect(isGalLookupProductionProviderPair(2, 14), isTrue);
      expect(isGalLookupProductionProviderPair(2, 15), isTrue);
      expect(isGalLookupProductionProviderPair(3, 10), isTrue);
      expect(isGalLookupProductionProviderPair(1, 3), isFalse);
      expect(isGalLookupProductionProviderPair(2, 1), isFalse);
      expect(isGalLookupProductionProviderPair(1, 15), isFalse);
      expect(isGalLookupProductionProviderPair(3, 11), isFalse);
    });

    test('client/primaryLayer 坐标可用，design/layout-local fail-closed', () {
      expect(_hit(coordinateSpace: 1).isProductionSane, isTrue);
      expect(_hit(coordinateSpace: 2).isProductionSane, isTrue);
      expect(_hit(coordinateSpace: 3).isProductionSane, isFalse);
      expect(_hit(coordinateSpace: 4).isProductionSane, isFalse);
    });

    test('下标越界与字符数漂移都不能通过 v19 生产门', () {
      // 硬门：指不到具体某个字的命中不能往下走，猜出来的下标会让高亮/查词落到无关的字上。
      expect(_hit(line: 'あいうえお', charIndex: 5).isAddressable, isFalse);
      expect(_hit(line: 'あいうえお', charIndex: -1).isAddressable, isFalse);
      expect(_hit(line: 'あいうえお', charIndex: 4).isAddressable, isTrue);
      expect(
        _hit(line: 'あいうえお', charCount: 99).hasConsistentCharCount,
        isFalse,
      );
      expect(
        _hit(line: 'あいうえお', charCount: 99, charIndex: 2).isProductionSane,
        isFalse,
        reason: 'v19 不再把 count 漂移的 provider 数据送进查词链',
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

  // ══ v19 查词准入 ═══════════════════════════════════════════════════════════
  //
  // 这条链回答的是「本局到底能不能游戏内查词」。它在 v19 之前**在协议里根本没有
  // 位置**，症状就是查词在很多游戏上静默失效、用户与开发者都看不出卡在哪一步。
  // 钉三样东西：线上值映射、"还不知道"绝不冒充"不支持"、以及会话换代必须复位。
  group('runner → Dart：查词准入', () {
    test('onGalLookupAdmission 逐字段解码（状态 + exe 摘要）', () async {
      GalLookupAdmission? received;
      GalHookTextOverlayChannel.setEventHandlers(
        onGalLookupAdmission: (GalLookupAdmission admission) =>
            received = admission,
      );
      const String sha =
          '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
      await invokeFromNative('onGalLookupAdmission', <String, Object?>{
        'state': 2,
        'executableSha256': sha,
      });
      expect(received, isNotNull);
      expect(received!.state, GalLookupAdmissionState.identityRejected);
      expect(received!.executableSha256, sha);
    });

    test('线上值与 voice_hook_ipc.h 的 LookupAdmissionState 逐值对应', () {
      expect(GalLookupAdmissionState.unknown.wireValue, 0);
      expect(GalLookupAdmissionState.engineUnsupported.wireValue, 1);
      expect(GalLookupAdmissionState.identityRejected.wireValue, 2);
      expect(GalLookupAdmissionState.identityAccepted.wireValue, 3);
      expect(GalLookupAdmissionState.sensorInstalled.wireValue, 4);
    });

    test('本构建不认识的状态值回落 unknown，绝不猜成"不支持"', () async {
      GalLookupAdmission? received;
      GalHookTextOverlayChannel.setEventHandlers(
        onGalLookupAdmission: (GalLookupAdmission admission) =>
            received = admission,
      );
      await invokeFromNative('onGalLookupAdmission', <String, Object?>{
        'state': 99,
        'executableSha256': '',
      });
      expect(received!.state, GalLookupAdmissionState.unknown);
    });

    // 🔴 这一条是整块改造的核心不变式：把 unknown 当成"不支持"，每局游戏启动的头
    // 几百毫秒都会误报一次。判据只有 blocksLookup 一份，UI 不得另写。
    test('只有 engineUnsupported / identityRejected 挡住查词', () {
      expect(GalLookupAdmissionState.unknown.blocksLookup, isFalse);
      expect(GalLookupAdmissionState.engineUnsupported.blocksLookup, isTrue);
      expect(GalLookupAdmissionState.identityRejected.blocksLookup, isTrue);
      expect(GalLookupAdmissionState.identityAccepted.blocksLookup, isFalse);
      expect(GalLookupAdmissionState.sensorInstalled.blocksLookup, isFalse);
      // 枚举加了新状态却没在这里表态 = 默认被当成"不挡"，必须显式复核。
      expect(GalLookupAdmissionState.values.length, 5);
    });

    test('会话换代复位成 unknown：上一局的准入不许留给下一局', () async {
      // setSessionActive 会把开关意图下发给 runner；这里只关心准入复位，把 native
      // 那半边收成一个成功应答，不然 MissingPluginException 会把断言前的路径炸掉。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            return <String, Object?>{'ok': true};
          });
      final GalIngameLookupController controller =
          GalIngameLookupController.test();
      controller.handleAdmission(
        const GalLookupAdmission(
          state: GalLookupAdmissionState.sensorInstalled,
          executableSha256: '',
        ),
      );
      expect(
        controller.admission.value.state,
        GalLookupAdmissionState.sensorInstalled,
      );
      await controller.setSessionActive(true);
      expect(controller.admission.value, GalLookupAdmission.unknown);

      controller.handleAdmission(
        const GalLookupAdmission(
          state: GalLookupAdmissionState.engineUnsupported,
          executableSha256: 'abc',
        ),
      );
      await controller.setSessionActive(false);
      expect(controller.admission.value, GalLookupAdmission.unknown);
    });

    test('同内容的快照不重复通知（runner 补摘要后会再发一次同一份）', () {
      final GalIngameLookupController controller =
          GalIngameLookupController.test();
      int notifications = 0;
      void listener() => notifications++;
      controller.admission.addListener(listener);
      addTearDown(() => controller.admission.removeListener(listener));

      const GalLookupAdmission blocked = GalLookupAdmission(
        state: GalLookupAdmissionState.engineUnsupported,
        executableSha256: '',
      );
      controller.handleAdmission(blocked);
      controller.handleAdmission(blocked);
      expect(notifications, 1);

      // 摘要补上来了：内容变了，必须通知——设置页那一行要从"无法获取"换成真摘要。
      controller.handleAdmission(
        const GalLookupAdmission(
          state: GalLookupAdmissionState.engineUnsupported,
          executableSha256: 'deadbeef',
        ),
      );
      expect(notifications, 2);
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

  group('BUG-2082 根卡以贴字形的那条边为不动点，不按 cap 上限高度算左上角', () {
    GalRootPlacement resolvePlacement(GalLookupHit hit, int capW, int capH) =>
        GalIngameLookupController.instance.debugResolveRootPlacement(
          hit,
          capW,
          capH,
        );

    // SGRE 4K 全屏实测：字形 (640,1660) 80×80，视口 3840×2160，8 MB 预算把 cap
    // 收到 1933×1087；实际渲染出来的根卡只有 773 高。
    final GalLookupHit hit4k = _hit(
      glyphX: 640,
      glyphY: 1660,
      glyphW: 80,
      glyphH: 80,
      viewW: 3840,
      viewH: 2160,
    );

    test('字幕贴底：cap 卡翻到上方，不动点是 cap 卡底边 = 字形顶 - 间距', () {
      final GalRootPlacement placement = resolvePlacement(hit4k, 1933, 1087);
      expect(placement.above, isTrue);
      expect(placement.edgeY, hit4k.glyphY - _kCardGap);
      expect(placement.x, 640);
    });

    test('翻到上方时底边贴台词：实际卡比 cap 矮 314 px 也不留空隙（修前顶边停在 569）', () {
      final GalRootPlacement placement = resolvePlacement(hit4k, 1933, 1087);
      final ({int x, int y}) rendered =
          resolveGalRootTopLeft(placement, 773, hit4k.viewH);
      expect(rendered.y + 773, placement.edgeY, reason: '底边必须贴在字形顶上方');
      expect(rendered.y, 1656 - 773);
      // cap 高度本身回到旧实现的落点：布局原点与修前逐字节一致。
      expect(resolveGalRootTopLeft(placement, 1087, hit4k.viewH).y, 569);
    });

    test('字幕在上半部：cap 卡放下方，不动点是顶边，卡片变高不动顶边', () {
      final GalLookupHit hit = _hit(glyphX: 600, glyphY: 200, viewH: 720);
      final GalRootPlacement placement = resolvePlacement(hit, 480, 320);
      expect(placement.above, isFalse);
      expect(placement.edgeY, hit.glyphY + hit.glyphH + _kCardGap);
      expect(resolveGalRootTopLeft(placement, 120, 720).y, placement.edgeY);
      expect(resolveGalRootTopLeft(placement, 320, 720).y, placement.edgeY);
    });

    test('根卡比上方空间还高时钉在 0，绝不给负坐标', () {
      const GalRootPlacement placement = (x: 10, edgeY: 300, above: true);
      expect(resolveGalRootTopLeft(placement, 500, 720), (x: 10, y: 0));
    });

    test('放下方而根卡长过视口底时贴底边', () {
      const GalRootPlacement placement = (x: 10, edgeY: 600, above: false);
      expect(resolveGalRootTopLeft(placement, 300, 720), (x: 10, y: 420));
    });

    // 审查探针的镜像象限：字形在屏幕中部（不是贴底台词），cap 高度远超锚侧空间。
    // computeFrameRect 选的是**下方**（spaceBelow 376 >= 收缩后的 height 370，
    // top = 344 正贴字形底），但 `[0, viewH - capH] = [0, 160]` 这道夹子会把它拽到
    // 160。侧别若从这个被夹过的 y 反推（`y < glyphY` → above），edgeY 就变成视口
    // 底边 720、与字形完全脱钩：根卡高 200 时落到 520，离字形底边 340 空出 180 px
    // ——正是 BUG-2082 那段空隙的镜像。SGRE 台词贴底所以真机撞不到，中屏字形
    //（UI 文本查词 / 台词不贴底的引擎）必撞。
    test('中屏字形 + cap 远大于锚侧空间：侧别取 computeFrameRect 自己的判据，不从被夹过的 y 反推', () {
      final GalLookupHit hit = _hit(
        glyphX: 300,
        glyphY: 300,
        glyphW: 40,
        glyphH: 40,
        viewW: 1280,
        viewH: 720,
      );
      final GalRootPlacement placement = resolvePlacement(hit, 600, 560);
      expect(placement.above, isFalse, reason: 'computeFrameRect 选的是下方');
      expect(placement.edgeY, hit.glyphY + hit.glyphH + _kCardGap);
      expect(placement.x, 300);
      // 反推实现在这里会给 (above: true, edgeY: 720) → 根卡 200 高时落到 520。
      final ({int x, int y}) rendered =
          resolveGalRootTopLeft(placement, 200, hit.viewH);
      expect(rendered.y, 344);
      expect(rendered.y, hit.glyphY + hit.glyphH + _kCardGap);
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

    test('geometry admission 与 runtime 分离并保留 request/applied ack', () async {
      mockRunner((_) => <String, Object?>{'requestSeq': 7, 'appliedSeq': 6});
      final GalLookupCallResult result =
          await GalHookTextOverlayChannel.galLookupSetGeometryAdmission(
            mode: GalLookupGeometryAdmissionMode.attachedOnly,
            attachedReady: true,
            nativeInputAllowed: false,
          );
      expect(calls.single.method, 'galLookupSetGeometryAdmission');
      expect(calls.single.arguments, <String, Object?>{
        'mode': 3,
        'attachedReady': true,
        'nativeInputAllowed': false,
      });
      expect(result.ok, isTrue);
      expect(result.requestSeq, 7);
      expect(result.appliedSeq, 6, reason: 'down/up/tail 未排空时允许 ack 暂时落后');
    });

    test('NativeInputAllowed 复用 admission request/applied ack', () async {
      mockRunner((_) => <String, Object?>{'requestSeq': 9, 'appliedSeq': 8});
      final GalLookupCallResult result =
          await GalHookTextOverlayChannel.galLookupSetGeometryAdmission(
            mode: GalLookupGeometryAdmissionMode.nativeOnly,
            attachedReady: false,
            nativeInputAllowed: true,
          );
      expect(calls.single.method, 'galLookupSetGeometryAdmission');
      expect(calls.single.arguments, <String, Object?>{
        'mode': 2,
        'attachedReady': false,
        'nativeInputAllowed': true,
      });
      expect(result.ok, isTrue);
      expect(result.requestSeq, 9);
      expect(result.appliedSeq, 8);
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
            glyphX: hit.glyphX,
            glyphY: hit.glyphY,
            glyphW: hit.glyphW,
            glyphH: hit.glyphH,
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
        // 字形矩形必须原样过线：直连覆盖窗要靠它在屏幕空间贴附卡片，丢了就退回按
        // 画布尺寸排的 anchor，放大运行时卡片会飘离命中的字。
        'glyphX': hit.glyphX,
        'glyphY': hit.glyphY,
        'glyphW': hit.glyphW,
        'glyphH': hit.glyphH,
      });
      expect(result.ok, isTrue);
      expect(result.width, 480);
      expect(result.height, 320);
      expect(result.clamped, isFalse);
      expect(result.directSurface, isTrue);
    });

    test('galLookupPresentHighlight 只带序号/锚点/高亮区间（BUG-2087 直连路径追加帧）', () async {
      mockRunner((_) => <String, Object?>{});
      final GalLookupCallResult result =
          await GalHookTextOverlayChannel.galLookupPresentHighlight(
            seq: 9,
            anchorX: 640,
            anchorY: 570,
            highlightStart: 10,
            highlightLen: 4,
          );
      expect(calls.single.method, 'galLookupPresentHighlight');
      expect(calls.single.arguments, <String, Object?>{
        'seq': 9,
        'anchorX': 640,
        'anchorY': 570,
        'highlightStart': 10,
        'highlightLen': 4,
      });
      expect(result.ok, isTrue);
    });

    // 接线层：纯函数（_resolveRootPlacement / resolveGalRootTopLeft）单测再漂亮，
    // 也证明不了「reveal 报的根卡高度真的走到了 present 的 anchor 上」。下面三条
    // 咬的就是那几行接线：host 上报的 rootHeight 被采信、_drainRecapture 走 placement
    // 而不是按卡片union 重解 anchor、直连 present 后追发 highlight-only 帧。
    test('reveal 报的根卡高度驱动 present anchor（union 高度与 rootHeight 不同）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(globalLookupChannel, (_) async => null);
      late GlobalLookupRoute activeRoute;
      mockRunner((MethodCall call) {
        if (call.method == 'galLookupPresent') {
          return <String, Object?>{'directSurface': true};
        }
        return <String, Object?>{};
      });
      final GalIngameLookupController controller =
          GalIngameLookupController.test(
            preferenceReader: (String key, {required Object? defaultValue}) =>
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
        // route token 的失效高水位是**进程级** static，按 `galCard:<sessionEpoch>`
        // 分族。同族里作废过 lookupEpoch 1 之后，别的测试用同一 sessionEpoch 起的
        // 第一次查词就恒被判为过期路由。本组里 epoch 1 归换句生命周期那条、epoch 2
        // 归 provider 仲裁那条，所以这里推到 3。
        await controller.setSessionActive(true);
        await controller.setSessionActive(false);
        await controller.setSessionActive(true);
        await controller.setSessionActive(false);
        await controller.setSessionActive(true);
        await controller.setProviderAdmission(true);
        // 台词贴底 → cap 卡翻到字形上方，不动点 = 字形顶 - 4 = 636。
        final GalLookupHit hit = _hit(seq: 88, glyphX: 400, glyphY: 640);
        await controller.handleHit(hit);
        calls.clear();

        // union 600x400（子卡把并集撑高），但根卡只有 200 高。
        GlobalLookupController.instance.onRoutedRevealed!(
          activeRoute,
          600,
          400,
          0,
          0,
          200,
        );
        await Future<void>.delayed(Duration.zero);

        final MethodCall present = calls.firstWhere(
          (MethodCall call) => call.method == 'galLookupPresent',
        );
        final Map<Object?, Object?> args =
            present.arguments as Map<Object?, Object?>;
        // 636 - 200：根卡底边贴字形。取 union 高度 400（M2：忽略 host 的 rootHeight）
        // 或整段退回 _resolveAnchor(hit, 600, 400)（M3）都会给 236。
        expect(args['anchorY'], 436);
        expect(args['anchorX'], 400);
        expect(args['cardWidth'], 600);
        expect(args['cardHeight'], 400);

        // BUG-2087：直连 present 成功且高亮区间非空 → 追一张 highlight-only 帧。
        final MethodCall highlight = calls.firstWhere(
          (MethodCall call) => call.method == 'galLookupPresentHighlight',
        );
        expect(highlight.arguments, <String, Object?>{
          'seq': 88,
          'anchorX': 400,
          'anchorY': 436,
          'highlightStart': hit.charIndex,
          'highlightLen': 1,
        });
        expect(
          calls.indexOf(present) < calls.indexOf(highlight),
          isTrue,
          reason: 'highlight-only 帧必须跟在 present 之后，不能顶掉卡片那一帧',
        );
      } finally {
        await controller.stopForTesting();
      }
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
            glyphX: 0,
            glyphY: 0,
            glyphW: 24,
            glyphH: 24,
          );
      expect(result.ok, isFalse);
      expect(result.error, 'lookup_region_missing');
    });

    test('主路复用 Fushi popup，不另造卡片', () {
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
        isNot(contains('showSentenceBanner')),
        reason:
            'popup 顶部整句横幅已随桌面剪贴板查词移除，不再有该开关；'
            '内嵌模式复用同一份 popup，不能另造一套卡片',
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
      // 钉在 `_syncEnabled` 自己的函数体上：同文件另有三处 `result.explicitOk ||`（dismiss /
      // present 路径），在全文上做 contains 等于拿别人的代码给这条钉买单，把这里
      // 改回 result.ok 也会假绿。compactCode 同时剥掉注释并折空白，不受 dart format
      // 换行与 CRLF 影响。
      final String syncEnabledBody = compactCode(
        methodBody(source, 'Future<void> _syncEnabled()'),
      );
      expect(
        syncEnabledBody.contains('if(acknowledged&&desired==latestDesired){'),
        isTrue,
        reason: '失败回执不能伪装成已推送，否则同一 active phase 无法重试',
      );
      // 只看变量名 `acknowledged` 等于没钉——把它定义成 `result.ok` 就又回到了
      // 「空/畸形回执（error==null 但没 ok）被当成成功」，所以判据本身也要钉。
      expect(
        syncEnabledBody.contains(
          'finalboolacknowledged=result.explicitOk||'
          '(!desired&&_nativeLookupConsumerUnavailable(result.error));',
        ),
        isTrue,
        reason:
            '推送成功只能由 runner 显式 {ok:true} 定调；'
            '唯一例外是「确认没有原生消费者」的**关闭**边，'
            '开启边任何情况下都不得 fail-open',
      );
      // 同态重发的判据已由「只看开启边」（active && !_pushedEnabled）改成双向对账：
      // 一次失败的**关闭**同样不能被后续同态通知跳过，否则 native 输入盾
      // 会一直开着。两个形式在开启边上等价，所以原判据（成功后不重发）仍在。
      expect(
        source,
        contains('if (_pushedEnabled != _enabledNow) await _syncEnabled();'),
        reason:
            '成功后的重复 session 通知不得持续占用 Shift 查词热路径；'
            '失败的关闭边必须仍能重试',
      );
      expect(
        reader,
        contains('lookup_enabled_desired = enabled;'),
        reason: 'mapping 换代重放意图由持有真实 mapping 身份的 reader 负责',
      );
      expect(reader, contains('st.lookup_geometry_admission_mode_desired'));
      expect(
        reader,
        contains('lookup_native_input_allowed_desired'),
        reason: '原生点击授权必须随 mapping 身份单独保存并受成功发布约束',
      );
      expect(reader, contains('PublishLookupGeometryAdmission('));
      expect(
        reader,
        isNot(contains('PublishLookupNativeInputAllowed(')),
        reason: 'admission 字只许有一个发布入口；两个入口=两份台账，谁后写谁赢',
      );
      expect(reader, contains('if (st.lookup_enabled_desired)'));
    });

    test('controller 显式驱动 auto/attached admission，不改 lookup runtime', () async {
      mockRunner(
        (MethodCall call) => <String, Object?>{
          'requestSeq': call.arguments is Map ? 4 : 0,
          'appliedSeq': 4,
        },
      );
      final GalIngameLookupController controller =
          GalIngameLookupController.test();
      // 允许位的所有者是 setProviderAdmission；setGeometryAdmission 不再收第四参。
      await controller.setProviderAdmission(true);
      calls.clear();
      final GalLookupCallResult result = await controller.setGeometryAdmission(
        GalLookupGeometryAdmissionMode.auto,
        attachedReady: true,
      );
      expect(result.ok, isTrue);
      expect(
        controller.debugGeometryAdmissionMode,
        GalLookupGeometryAdmissionMode.auto,
      );
      expect(controller.debugGeometryAttachedReady, isTrue);
      expect(controller.debugGeometryNativeInputAllowed, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'galLookupSetGeometryAdmission');
      expect(
        calls.where((MethodCall call) => call.method == 'galLookupSetEnabled'),
        isEmpty,
        reason: 'geometry handoff 不能停掉 attached 依赖的 generic shield runtime',
      );
    });

    test('provider 仲裁关闭准入时拒绝 native hit，重开后才提交', () async {
      mockRunner((_) => <String, Object?>{});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(globalLookupChannel, (_) async => null);
      int lookupRuns = 0;
      final GalIngameLookupController controller =
          GalIngameLookupController.test(
            preferenceReader: (String key, {required Object? defaultValue}) =>
                key == GalIngameLookupController.enabledPreferenceKey
                ? true
                : defaultValue,
            lookupRunner: (String query, GalLookupHit hit) async {
              lookupRuns++;
              return true;
            },
          );
      try {
        await controller.start(appModel: AppModel(testPlatformServices()));
        await controller.setSessionActive(true);
        // Keep this test's immutable route token distinct from the following
        // lifecycle test, whose fresh test controller starts at epoch 1.
        await controller.setSessionActive(false);
        await controller.setSessionActive(true);
        await controller.setProviderAdmission(false);
        expect(controller.debugProviderAdmission, isFalse);

        await controller.handleHit(_hit(seq: 71));
        expect(lookupRuns, 0);

        await controller.setProviderAdmission(true);
        expect(
          calls.where(
            (MethodCall call) =>
                call.method == 'galLookupSetGeometryAdmission' &&
                (call.arguments
                        as Map<Object?, Object?>)['nativeInputAllowed'] ==
                    true,
          ),
          hasLength(1),
          reason: 'local admission 必须先打开，再发布 native allow request',
        );
        await controller.handleHit(_hit(seq: 72));
        expect(lookupRuns, 1);
      } finally {
        await controller.stopForTesting();
      }
    });

    test('NativeInputAllowed channel 异常保留同值重试与双向顺序', () async {
      int enableAttempts = 0;
      int disableAttempts = 0;
      late GalIngameLookupController controller;
      mockRunner((MethodCall call) {
        if (call.method != 'galLookupSetGeometryAdmission') {
          return <String, Object?>{};
        }
        final bool allowed =
            (call.arguments as Map<Object?, Object?>)['nativeInputAllowed']!
                as bool;
        expect(
          controller.debugProviderAdmission,
          isTrue,
          reason: allowed
              ? 'enable 必须先开 local receive gate 再请求 native allow'
              : 'disable 必须在 local gate 仍开着时先请求 native deny',
        );
        if (allowed) {
          enableAttempts++;
          if (enableAttempts == 1) {
            throw PlatformException(code: 'transient-enable');
          }
        } else {
          disableAttempts++;
          if (disableAttempts == 1) {
            throw PlatformException(code: 'transient-disable');
          }
        }
        return <String, Object?>{
          'requestSeq': enableAttempts + disableAttempts,
          'appliedSeq': enableAttempts + disableAttempts,
        };
      });
      controller = GalIngameLookupController.test(
        preferenceReader: (String key, {required Object? defaultValue}) =>
            key == GalIngameLookupController.enabledPreferenceKey
            ? true
            : defaultValue,
      );
      try {
        await controller.start(appModel: AppModel(testPlatformServices()));
        await controller.setSessionActive(true);

        await controller.setProviderAdmission(true);
        expect(controller.debugProviderAdmission, isTrue);
        expect(controller.debugProviderAdmissionDesired, isTrue);
        expect(controller.debugPushedProviderAdmission, isNull);
        expect(controller.debugProviderAdmissionPushPending, isTrue);

        await controller.setProviderAdmission(true);
        expect(enableAttempts, 2, reason: '同值 enable 必须重试未知 delivery');
        expect(controller.debugPushedProviderAdmission, isTrue);
        expect(controller.debugProviderAdmissionPushPending, isFalse);

        await controller.setProviderAdmission(false);
        expect(
          controller.debugProviderAdmission,
          isTrue,
          reason: 'native deny 未确认时不可让 native 吞点击、Dart 丢 hit',
        );
        expect(controller.debugProviderAdmissionDesired, isFalse);
        expect(controller.debugPushedProviderAdmission, isNull);
        expect(controller.debugProviderAdmissionPushPending, isTrue);

        await controller.setProviderAdmission(false);
        expect(disableAttempts, 2, reason: '同值 disable 必须重试未知 delivery');
        expect(controller.debugProviderAdmission, isFalse);
        expect(controller.debugPushedProviderAdmission, isFalse);
        expect(controller.debugProviderAdmissionPushPending, isFalse);
      } finally {
        await controller.stopForTesting();
      }
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
            preferenceReader: (String key, {required Object? defaultValue}) =>
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
        await controller.setProviderAdmission(true);
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
          glyphX: 0,
          glyphY: 0,
          glyphW: 24,
          glyphH: 24,
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
