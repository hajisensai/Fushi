// attached surface 的实测排版路线（TyranoScript DOM 源）在控制器层的契约：
// - 有 DOM feed 时不要校准 profile 就能激活（inspect → attachedOnly 交接 → configureMeasured）；
// - DOM 帧 → measured glyph 编码（只 complete 帧、只 shown、floor/ceil、trim 偏移）；
// - measuredLayoutStale → 用 feed.latest 同 generation 重发；
// - feed 结束 → attachedDetach；
// - 没有 feed（非 Tyrano 游戏）照旧走校准路线，从不调 configureMeasured。
//
// 文本一律是合成串，不含任何游戏台词。

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_attached_measured_frame.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_feed.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_frame.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const GalLookupReferenceClientV1 _client = GalLookupReferenceClientV1(
  widthPx: 1280,
  heightPx: 720,
  dpi: 96,
);

typedef _MeasuredCall = ({
  String text,
  int generation,
  List<GalAttachedMeasuredGlyph> glyphs,
  int width,
  int height,
});

class _MeasuredPort implements GalAttachedTextSurfacePort {
  final List<String> calls = <String>[];
  final List<_MeasuredCall> measured = <_MeasuredCall>[];
  GalAttachedCallResult configureMeasuredResult = const GalAttachedCallResult(
    status: 'ready',
    providerKind: 4,
    providerId: 11,
    providerStatus: 2,
    layoutSource: galAttachedLayoutSourceMeasured,
    measuredSource: galAttachedMeasuredSourceTyranoDom,
  );
  GalAttachedCallResult Function(_MeasuredCall call) updateMeasuredResult =
      (_MeasuredCall _) => const GalAttachedCallResult(
        status: 'visible',
        surfaceVisible: true,
        providerKind: 4,
        providerId: 11,
        providerStatus: 2,
      );

  @override
  Future<GalAttachedCallResult> inspectTarget(
    GalAttachedSurfaceTarget target, {
    String? launchExePath,
  }) async {
    calls.add('inspect');
    return const GalAttachedCallResult(
      exePath: r'C:\Games\Sample\game.exe',
      exeSha256: _sha,
      referenceClient: _client,
    );
  }

  @override
  Future<GalAttachedCallResult> configureMeasured({
    required GalAttachedSurfaceTarget target,
    required String measuredSource,
  }) async {
    calls.add('configureMeasured:$measuredSource');
    return configureMeasuredResult;
  }

  @override
  Future<GalAttachedCallResult> updateMeasuredText({
    required GalAttachedSurfaceTarget target,
    required String sourceText,
    required int textGeneration,
    required List<GalAttachedMeasuredGlyph> glyphs,
    required int clientWidth,
    required int clientHeight,
  }) async {
    calls.add('updateMeasuredText');
    final _MeasuredCall call = (
      text: sourceText,
      generation: textGeneration,
      glyphs: glyphs,
      width: clientWidth,
      height: clientHeight,
    );
    measured.add(call);
    return updateMeasuredResult(call);
  }

  @override
  Future<GalAttachedCallResult> configure({
    required GalAttachedSurfaceTarget target,
    required GalLookupSurfaceVariantV1 variant,
    required GalLookupSurfaceMode mode,
    required bool riskAccepted,
  }) async {
    calls.add('configure');
    return const GalAttachedCallResult(
      status: 'ready',
      providerKind: 4,
      providerId: 11,
      providerStatus: 2,
    );
  }

  @override
  Future<GalAttachedCallResult> updateText({
    required GalAttachedSurfaceTarget target,
    required String sourceText,
    required int textGeneration,
  }) async {
    calls.add('updateText');
    return const GalAttachedCallResult(status: 'visible');
  }

  @override
  Future<GalAttachedCallResult> detach(GalAttachedSurfaceTarget target) async {
    calls.add('detach');
    return const GalAttachedCallResult(status: 'detached');
  }

  @override
  Future<GalAttachedCallResult> calibrationStart({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalLookupReferenceClientV1 referenceClient,
    required GalLookupTextLayoutV1 layout,
    required bool riskAccepted,
  }) async => _unexpected('calibrationStart');

  @override
  Future<GalAttachedCallResult> calibrationUpdate({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  }) async => _unexpected('calibrationUpdate');

  @override
  Future<GalAttachedCallResult> calibrationCommit({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  }) async => _unexpected('calibrationCommit');

  @override
  Future<GalAttachedCallResult> calibrationCancel(
    GalAttachedSurfaceTarget target,
  ) async => _unexpected('calibrationCancel');

  @override
  Future<GalAttachedCallResult> updateStyle({
    required GalAttachedSurfaceTarget target,
    required GalLookupTextLayoutV1 layout,
  }) async => _unexpected('updateStyle');

  @override
  Future<GalAttachedCallResult> suspendForCapture({
    required GalAttachedSurfaceTarget target,
    required int textGeneration,
    required int captureGeneration,
  }) async => _unexpected('suspendForCapture');

  @override
  Future<GalAttachedCallResult> restoreAfterCapture({
    required GalAttachedSurfaceTarget target,
    required int textGeneration,
    required int captureGeneration,
  }) async => _unexpected('restoreAfterCapture');

  GalAttachedCallResult _unexpected(String name) {
    calls.add(name);
    return const GalAttachedCallResult(error: 'unexpected');
  }
}

TyranoDomGlyph _glyph(
  int start,
  double left, {
  int length = 1,
  bool shown = true,
  double top = 600.4,
}) => TyranoDomGlyph(
  textStart: start,
  textLength: length,
  rect: Rectangle<double>(left, top, 31.2, 40.5),
  shown: shown,
);

TyranoDomFrame _frame(
  String text, {
  int generation = 1,
  bool complete = true,
  List<TyranoDomGlyph>? glyphs,
  int width = 1280,
  int height = 720,
}) => TyranoDomFrame(
  text: text,
  generation: generation,
  complete: complete,
  speaker: '',
  glyphs:
      glyphs ??
      <TyranoDomGlyph>[
        for (int i = 0; i < text.length; i++) _glyph(i, 100.6 + 32 * i),
      ],
  devicePixelRatio: 1,
  clientWidth: width,
  clientHeight: height,
  vertical: false,
);

void main() {
  group('galAttachedMeasuredPayloadForFrame', () {
    test('未完成帧一律清空', () {
      final GalAttachedMeasuredPayload payload =
          galAttachedMeasuredPayloadForFrame(_frame('abc', complete: false));
      expect(payload.isClear, isTrue);
      expect(payload.glyphs, isEmpty);
    });

    test('只发 shown 字形，left/top floor、right/bottom ceil', () {
      final GalAttachedMeasuredPayload payload =
          galAttachedMeasuredPayloadForFrame(
            _frame(
              'abc',
              glyphs: <TyranoDomGlyph>[
                _glyph(0, 100.6),
                _glyph(1, 132.6, shown: false),
                _glyph(2, 164.6),
              ],
            ),
          );
      expect(payload.sourceText, 'abc');
      expect(payload.clientWidth, 1280);
      expect(payload.clientHeight, 720);
      expect(payload.glyphs, const <GalAttachedMeasuredGlyph>[
        GalAttachedMeasuredGlyph(
          start: 0,
          length: 1,
          left: 100,
          top: 600,
          right: 132,
          bottom: 641,
        ),
        GalAttachedMeasuredGlyph(
          start: 2,
          length: 1,
          left: 164,
          top: 600,
          right: 196,
          bottom: 641,
        ),
      ]);
    });

    test('文本与 texthooker 收口一致：trim 掉的前导空白让下标整体平移', () {
      final GalAttachedMeasuredPayload payload =
          galAttachedMeasuredPayloadForFrame(_frame('\u3000ab '));
      expect(payload.sourceText, 'ab');
      expect(tyranoDomTexthookerText('\u3000ab '), payload.sourceText);
      expect(payload.glyphs.map((GalAttachedMeasuredGlyph g) => g.start), <int>[
        0,
        1,
      ]);
    });

    test('越出客户区的框被夹进客户区，夹空的丢掉', () {
      final GalAttachedMeasuredPayload payload =
          galAttachedMeasuredPayloadForFrame(
            _frame(
              'ab',
              width: 120,
              glyphs: <TyranoDomGlyph>[_glyph(0, 100.6), _glyph(1, 130)],
            ),
          );
      expect(payload.glyphs.single.right, 120);
    });
  });

  group('GalAttachedTextController measured route', () {
    late _MeasuredPort port;
    late GalAttachedTextController controller;
    late Map<String, Object?> preferences;
    late List<({GalLookupSurfaceMode mode, bool forceAttached})> handoffs;
    late List<GalAttachedLookupHitV19> lookups;
    late TyranoDomFeed feed;

    setUp(() {
      port = _MeasuredPort();
      preferences = <String, Object?>{};
      handoffs = <({GalLookupSurfaceMode mode, bool forceAttached})>[];
      lookups = <GalAttachedLookupHitV19>[];
      feed = TyranoDomFeed(port: 9222, gamePid: 1234);
      controller = GalAttachedTextController(
        preferenceReader: (String key) => preferences[key],
        preferenceWriter: (String key, Object? value) async {
          preferences[key] = value;
        },
        surfacePort: port,
        onBeforeAttachedActivation:
            (GalLookupSurfaceMode mode, {required bool forceAttached}) async {
              handoffs.add((mode: mode, forceAttached: forceAttached));
            },
        onLookup: (GalAttachedLookupHitV19 hit) => lookups.add(hit),
        calibrationLog: (_) {},
      );
    });

    tearDown(() async {
      await controller.detach();
      await feed.close();
      await pumpEventQueue();
      controller.dispose();
    });

    Future<void> sync({
      TyranoDomFeed? measuredFeed,
      bool inspectOnly = false,
      String? text,
    }) => controller.syncSession(
      active: true,
      sessionEpoch: 1,
      targetPid: 1234,
      targetHwnd: 77,
      sourceText: text,
      inspectOnly: inspectOnly,
      measuredFeed: measuredFeed,
    );

    Future<void> activate() async {
      await sync(measuredFeed: feed, inspectOnly: true);
      await sync(measuredFeed: feed);
      await controller.measuredPushIdle;
    }

    Future<void> emit(TyranoDomFrame frame) async {
      feed.add(frame);
      await pumpEventQueue();
      await controller.measuredPushIdle;
    }

    test(
      '没有校准 profile 也能激活：inspect → attachedOnly 交接 → configureMeasured',
      () async {
        expect(preferences, isEmpty);
        await activate();

        expect(controller.measuredLayoutActive, isTrue);
        expect(port.calls, <String>[
          'inspect',
          'configureMeasured:$galAttachedMeasuredSourceTyranoDom',
        ]);
        expect(handoffs, hasLength(1));
        expect(handoffs.single.forceAttached, isTrue);
        expect(controller.attachedProviderClaimed, isTrue);
        expect(controller.forceAttachedProvider, isTrue);
        // 还没有完成的一句：等待而不是要求校准。
        expect(controller.status, GalAttachedTextStatus.waitingForBodyThread);
        expect(controller.canCalibrate, isFalse);
        expect(controller.sampleCalibrationEnabled, isFalse);
      },
    );

    test('complete 帧编码成 measured glyph 并激活；查词命中走 onLookup', () async {
      await activate();
      await emit(_frame('abc'));

      expect(port.measured, hasLength(1));
      final _MeasuredCall call = port.measured.single;
      expect(call.text, 'abc');
      expect(call.generation, 1);
      expect(call.width, 1280);
      expect(call.height, 720);
      expect(call.glyphs.first.left, 100);
      expect(call.glyphs.first.right, 132);
      expect(controller.status, GalAttachedTextStatus.activeAttached);
      expect(controller.latestSourceText, 'abc');
      expect(controller.textGeneration, 1);
      expect(port.calls, isNot(contains('updateText')));
      expect(port.calls, isNot(contains('configure')));

      await controller.handleLookupText(
        GalAttachedLookupHitV19(
          target: controller.target!,
          sourceText: 'abc',
          textGeneration: controller.textGeneration,
          charIndex: 1,
          sourceLength: 1,
        ),
      );
      expect(lookups, hasLength(1));
      expect(lookups.single.charIndex, 1);
    });

    test('逐字显示中的帧撤掉上一句的框，完成后才发新句', () async {
      await activate();
      await emit(_frame('abc'));
      await emit(_frame('xy', generation: 2, complete: false));
      expect(port.measured.last.text, '');
      expect(port.measured.last.glyphs, isEmpty);
      expect(port.measured.last.generation, 2);
      expect(controller.status, GalAttachedTextStatus.waitingForBodyThread);

      // 同一个未完成状态的后续帧不重复清空。
      await emit(_frame('xyz', generation: 3, complete: false));
      expect(port.measured, hasLength(2));

      await emit(_frame('xyz', generation: 3));
      expect(port.measured.last.text, 'xyz');
      expect(port.measured.last.generation, 3);
      expect(controller.status, GalAttachedTextStatus.activeAttached);
    });

    test('measuredLayoutStale → 用 feed.latest 同 generation 重发', () async {
      await activate();
      await emit(_frame('abc'));
      final GalAttachedSurfaceTarget target = controller.target!;
      // 窗口缩放：DOM 先推来新尺寸的同一句。
      feed.add(_frame('abc', width: 1600, height: 900));
      await pumpEventQueue();
      await controller.measuredPushIdle;
      expect(port.measured.last.width, 1600);
      expect(port.measured.last.generation, 1);
      final int before = port.measured.length;

      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: target,
          state: 'suspended',
          status: 'measuredLayoutStale',
          reason: 'measured_layout_refresh_required',
          providerKind: 4,
          providerId: 11,
          providerStatus: 2,
          layoutSource: galAttachedLayoutSourceMeasured,
          measuredSource: galAttachedMeasuredSourceTyranoDom,
        ),
      );
      expect(controller.status, GalAttachedTextStatus.suspended);
      await pumpEventQueue();
      await controller.measuredPushIdle;
      expect(port.measured.length, before + 1);
      expect(port.measured.last.text, 'abc');
      expect(port.measured.last.width, 1600);
      expect(port.measured.last.generation, 1);
      expect(controller.status, GalAttachedTextStatus.activeAttached);
    });

    test('视口尺寸被拒收：挂起、不重发同一份测量，新快照到达再发', () async {
      port.updateMeasuredResult = (_MeasuredCall call) => call.width == 1280
          ? const GalAttachedCallResult(error: 'measured_client_size_mismatch')
          : const GalAttachedCallResult(
              status: 'visible',
              providerKind: 4,
              providerId: 11,
              providerStatus: 2,
            );
      await activate();
      await emit(_frame('abc'));
      expect(controller.status, GalAttachedTextStatus.suspended);
      expect(controller.statusReason, 'measured_client_size_mismatch');
      expect(controller.textGeneration, 1);

      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'suspended',
          status: 'measuredLayoutStale',
          reason: 'measured_client_size_mismatch',
          providerKind: 4,
          providerId: 11,
          providerStatus: 2,
        ),
      );
      await pumpEventQueue();
      await controller.measuredPushIdle;
      expect(port.measured, hasLength(1), reason: '同一份被拒的测量不重发');

      await emit(_frame('abc', width: 1264, height: 681));
      expect(port.measured, hasLength(2));
      expect(port.measured.last.generation, 1, reason: '同句重测沿用 generation');
      expect(controller.status, GalAttachedTextStatus.activeAttached);
    });

    test('feed 结束（CDP 断开）→ attachedDetach', () async {
      await activate();
      await emit(_frame('abc'));
      await feed.close();
      await pumpEventQueue();
      expect(port.calls.last, 'detach');
      expect(controller.target, isNull);
      expect(controller.status, GalAttachedTextStatus.disabled);
    });

    test('没有 feed（非 Tyrano 游戏）照旧走校准路线', () async {
      final GalLookupSurfaceProfileV1 profile = GalLookupSurfaceProfileV1(
        exePath: GalLookupSurfaceProfileV1.normalizeExePath(
          r'C:\Games\Sample\game.exe',
        ),
        exeSha256: _sha,
        mode: GalLookupSurfaceMode.attachedOnly,
        unsafeLeftClickAccepted: true,
        variants: <GalLookupSurfaceVariantV1>[
          GalLookupSurfaceVariantV1(
            aspectRatio: _client.aspectRatio,
            referenceClient: _client,
            bodyRect: GalAttachedTextController.defaultBodyRect,
            layout: const GalLookupTextLayoutV1(),
          ),
        ],
      );
      preferences[GalLookupSurfaceProfileV1.preferenceKeyForExePath(
        profile.exePath,
      )] = jsonEncode(
        profile.toJson(),
      );
      await sync(text: 'abc', inspectOnly: true);
      await sync(text: 'abc');

      expect(controller.measuredLayoutActive, isFalse);
      expect(port.calls, contains('configure'));
      expect(port.calls, contains('updateText'));
      expect(
        port.calls.where((String c) => c.startsWith('configureMeasured')),
        isEmpty,
      );
      expect(port.measured, isEmpty);
      expect(handoffs.single.forceAttached, isFalse);
    });

    test('feed 换成 null 时整面重挂回校准路线', () async {
      await activate();
      await emit(_frame('abc'));
      await sync(text: 'abc', inspectOnly: true);
      expect(controller.measuredLayoutActive, isFalse);
      expect(port.calls, contains('detach'));
    });
  });
}
