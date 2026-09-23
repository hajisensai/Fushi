import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const String _exePath = r'c:\games\sample\game.exe';
const GalLookupReferenceClientV1 _client = GalLookupReferenceClientV1(
  widthPx: 1920,
  heightPx: 1080,
  dpi: 144,
);
const GalAttachedCalibrationProbes _probes = GalAttachedCalibrationProbes(
  startIndex: 0,
  middleIndex: 3,
  endIndex: 6,
  startConfirmed: true,
  middleConfirmed: true,
  endConfirmed: true,
);

GalLookupSurfaceVariantV1 _variant({
  GalLookupReferenceClientV1 client = _client,
  GalLookupCalibrationSlotV1? slot,
}) => GalLookupSurfaceVariantV1(
  aspectRatio: client.aspectRatio,
  referenceClient: client,
  bodyRect: GalAttachedTextController.defaultBodyRect,
  layout: const GalLookupTextLayoutV1(),
  slot: slot,
);

GalLookupSurfaceProfileV1 _profile({
  String sha = _sha,
  bool accepted = true,
  GalLookupSurfaceMode mode = GalLookupSurfaceMode.attachedOnly,
}) => GalLookupSurfaceProfileV1(
  exePath: _exePath,
  exeSha256: sha,
  mode: mode,
  unsafeLeftClickAccepted: accepted,
  variants: <GalLookupSurfaceVariantV1>[_variant()],
);

class _FakeSurfacePort implements GalAttachedTextSurfacePort {
  final List<String> calls = <String>[];
  final List<({String text, int generation})> texts =
      <({String text, int generation})>[];
  GalAttachedCallResult inspection = const GalAttachedCallResult(
    exePath: r'C:\Games\Sample\game.exe',
    exeSha256: _sha,
    referenceClient: _client,
  );
  Completer<GalAttachedCallResult>? inspectionCompleter;
  GalAttachedCallResult configureResult = const GalAttachedCallResult(
    status: 'ready',
    providerKind: 4,
    providerId: 11,
    providerStatus: 1,
  );
  final List<Completer<GalAttachedCallResult>> configureCompleters =
      <Completer<GalAttachedCallResult>>[];
  final List<GalLookupCalibrationSlotV1?> configuredSlots =
      <GalLookupCalibrationSlotV1?>[];
  int nativeProbeMask = 0;
  bool calibrationActive = false;
  GalAttachedCallResult calibrationResult = const GalAttachedCallResult(
    status: 'calibrating',
    surfaceVisible: true,
  );
  Future<void> Function()? beforeCalibrationCommitReply;
  Completer<GalAttachedCallResult>? calibrationUpdateCompleter;
  bool textSurfaceVisible = true;
  String? lastInspectLaunchExePath;
  Completer<GalAttachedCallResult>? suspendCompleter;
  GalAttachedCallResult suspendResult = const GalAttachedCallResult(
    status: 'captureSuppressed',
    surfaceVisible: false,
  );
  Completer<GalAttachedCallResult>? restoreCompleter;
  Error? restoreException;
  GalAttachedCallResult restoreResult = const GalAttachedCallResult(
    status: 'visible',
    surfaceVisible: true,
  );
  GalAttachedCallResult detachResult = const GalAttachedCallResult(
    status: 'detached',
  );
  Completer<GalAttachedCallResult>? detachCompleter;

  @override
  Future<GalAttachedCallResult> inspectTarget(
    GalAttachedSurfaceTarget target, {
    String? launchExePath,
  }) async {
    lastInspectLaunchExePath = launchExePath;
    calls.add('inspect');
    final Completer<GalAttachedCallResult>? completer = inspectionCompleter;
    if (completer != null) return completer.future;
    return inspection;
  }

  @override
  Future<GalAttachedCallResult> calibrationStart({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalLookupReferenceClientV1 referenceClient,
    required GalLookupTextLayoutV1 layout,
    required bool riskAccepted,
  }) async {
    calls.add('calibrationStart:$riskAccepted');
    nativeProbeMask = 0;
    calibrationActive = calibrationResult.ok;
    return calibrationResult;
  }

  @override
  Future<GalAttachedCallResult> calibrationUpdate({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  }) async {
    calls.add('calibrationUpdate:${probes.confirmationMask}');
    if (calibrationUpdateCompleter != null) {
      return calibrationUpdateCompleter!.future;
    }
    nativeProbeMask = probes.confirmationMask;
    return GalAttachedCallResult(
      status: calibrationResult.status,
      surfaceVisible: calibrationResult.surfaceVisible,
      calibrationProbeMask: nativeProbeMask,
      probeStartObservedIndex: probes.startIndex,
      probeMiddleObservedIndex: probes.middleIndex,
      probeEndObservedIndex: probes.endIndex,
    );
  }

  @override
  Future<GalAttachedCallResult> calibrationCommit({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  }) async {
    calls.add('calibrationCommit:${probes.confirmationMask}');
    calibrationActive = false;
    await beforeCalibrationCommitReply?.call();
    return const GalAttachedCallResult(
      status: 'calibrating',
      calibrationProbeMask: 7,
    );
  }

  @override
  Future<GalAttachedCallResult> calibrationCancel(
    GalAttachedSurfaceTarget target,
  ) async {
    calls.add('calibrationCancel');
    calibrationActive = false;
    return const GalAttachedCallResult(status: 'cancelled');
  }

  @override
  Future<GalAttachedCallResult> configure({
    required GalAttachedSurfaceTarget target,
    required GalLookupSurfaceVariantV1 variant,
    required GalLookupSurfaceMode mode,
    required bool riskAccepted,
  }) async {
    calls.add('configure:${mode.wireName}:$riskAccepted');
    configuredSlots.add(variant.slot);
    if (configureCompleters.isNotEmpty) {
      return configureCompleters.removeAt(0).future;
    }
    return configureResult;
  }

  @override
  Future<GalAttachedCallResult> updateText({
    required GalAttachedSurfaceTarget target,
    required String sourceText,
    required int textGeneration,
  }) async {
    calls.add('updateText');
    texts.add((text: sourceText, generation: textGeneration));
    if (calibrationActive) return calibrationResult;
    return GalAttachedCallResult(
      status: textSurfaceVisible ? 'visible' : 'noGlyphClusters',
      surfaceVisible: textSurfaceVisible,
    );
  }

  @override
  Future<GalAttachedCallResult> updateStyle({
    required GalAttachedSurfaceTarget target,
    required GalLookupTextLayoutV1 layout,
  }) async {
    calls.add('updateStyle');
    if (calibrationActive) return calibrationResult;
    return const GalAttachedCallResult(status: 'ready');
  }

  @override
  Future<GalAttachedCallResult> suspendForCapture({
    required GalAttachedSurfaceTarget target,
    required int textGeneration,
    required int captureGeneration,
  }) async {
    calls.add('suspendForCapture:$textGeneration:$captureGeneration');
    final Completer<GalAttachedCallResult>? completer = suspendCompleter;
    if (completer != null) return completer.future;
    return suspendResult;
  }

  @override
  Future<GalAttachedCallResult> restoreAfterCapture({
    required GalAttachedSurfaceTarget target,
    required int textGeneration,
    required int captureGeneration,
  }) async {
    calls.add('restoreAfterCapture:$textGeneration:$captureGeneration');
    final Completer<GalAttachedCallResult>? completer = restoreCompleter;
    if (completer != null) return completer.future;
    final Error? exception = restoreException;
    if (exception != null) throw exception;
    return restoreResult;
  }

  @override
  Future<GalAttachedCallResult> detach(GalAttachedSurfaceTarget target) async {
    calls.add('detach');
    calibrationActive = false;
    final Completer<GalAttachedCallResult>? completer = detachCompleter;
    if (completer != null) return completer.future;
    return detachResult;
  }
}

void main() {
  late Map<String, Object?> preferences;
  late _FakeSurfacePort port;
  late GalAttachedTextController controller;
  late List<GalAttachedLookupHitV19> lookups;
  late int providerClaims;
  late List<String> calibrationLogs;
  Completer<void>? preferenceWriteGate;
  Object? preferenceWriteError;
  Completer<void>? providerClaimGate;

  setUp(() {
    preferences = <String, Object?>{};
    port = _FakeSurfacePort();
    lookups = <GalAttachedLookupHitV19>[];
    providerClaims = 0;
    calibrationLogs = <String>[];
    preferenceWriteGate = null;
    preferenceWriteError = null;
    providerClaimGate = null;
    controller = GalAttachedTextController(
      preferenceReader: (String key) => preferences[key],
      preferenceWriter: (String key, Object? value) async {
        final Completer<void>? gate = preferenceWriteGate;
        if (gate != null) await gate.future;
        final Object? error = preferenceWriteError;
        preferences[key] = value;
        if (error != null) {
          Error.throwWithStackTrace(error, StackTrace.current);
        }
      },
      surfacePort: port,
      onBeforeAttachedActivation:
          (GalLookupSurfaceMode _, {required bool forceAttached}) async {
            providerClaims++;
            final Completer<void>? gate = providerClaimGate;
            if (gate != null) await gate.future;
          },
      onLookup: lookups.add,
      calibrationLog: calibrationLogs.add,
    );
  });

  tearDown(() async {
    await controller.detach();
    controller.dispose();
  });

  Future<void> sync({
    String text = 'これは本文テストです',
    String? launchExePath,
    bool inspectOnly = false,
    int sessionEpoch = 9001,
  }) => controller.syncSession(
    active: true,
    sessionEpoch: sessionEpoch,
    targetPid: 1234,
    targetHwnd: 77,
    sourceText: text,
    launchExePath: launchExePath,
    inspectOnly: inspectOnly,
  );

  String key() => GalLookupSurfaceProfileV1.preferenceKeyForExePath(_exePath);

  GalLookupSurfaceVariantV1 measuredVariant({
    GalLookupReferenceClientV1 client = _client,
  }) => GalLookupSurfaceVariantV1(
    aspectRatio: client.aspectRatio,
    referenceClient: client,
    bodyRect: GalAttachedTextController.defaultBodyRect,
    layout: const GalLookupTextLayoutV1(
      cellGrid: GalLookupCellGridV1(
        advancePerClientHeight: 0.03,
        lineAdvancePerClientHeight: 0.04,
        cellHeightPerClientHeight: 0.035,
        columns: 24,
        continuationIndent: 0,
        quotedContinuationIndent: 0,
      ),
    ),
  );

  test('measured calibration activates without manufacturing probes', () async {
    await sync();
    await controller.setMode(GalLookupSurfaceMode.attachedOnly);
    port.calls.clear();
    expect(
      await controller.applyMeasuredCalibration(
        expectedTarget: controller.target!,
        expectedExeSha256: _sha,
        variant: measuredVariant(),
      ),
      isTrue,
    );
    expect(controller.profile!.variants.single.layout.cellGrid, isNotNull);
    expect(controller.status, GalAttachedTextStatus.activeAttached);
    expect(controller.calibrationActive, isFalse);
    expect(port.nativeProbeMask, 0);
    expect(
      port.calls.any((String call) => call.startsWith('calibration')),
      isFalse,
    );
    expect(port.calls, contains('configure:attachedOnly:true'));
    expect(jsonDecode(preferences[key()]! as String)['variants'], hasLength(1));
  });

  test(
    'measured calibration rejects legacy layout and incompatible aspect',
    () async {
      await sync();
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      final Object? previous = preferences[key()];
      for (final GalLookupSurfaceVariantV1 variant
          in <GalLookupSurfaceVariantV1>[
            _variant(),
            measuredVariant(
              client: const GalLookupReferenceClientV1(
                widthPx: 800,
                heightPx: 600,
                dpi: 96,
              ),
            ),
          ]) {
        expect(
          await controller.applyMeasuredCalibration(
            expectedTarget: controller.target!,
            expectedExeSha256: _sha,
            variant: variant,
          ),
          isFalse,
        );
      }
      expect(preferences[key()], previous);
    },
  );

  test('measured calibration waits for a transient Magpie mapping', () async {
    await sync();
    await controller.setMode(GalLookupSurfaceMode.attachedOnly);
    port.configureResult = const GalAttachedCallResult(
      status: 'targetMappingUnavailable',
      providerKind: 4,
      providerId: 11,
      providerStatus: 1,
    );
    port.textSurfaceVisible = false;
    expect(
      await controller.applyMeasuredCalibration(
        expectedTarget: controller.target!,
        expectedExeSha256: _sha,
        variant: measuredVariant(),
      ),
      isTrue,
    );
    expect(controller.profile!.variants, hasLength(1));
    expect(controller.status, GalAttachedTextStatus.suspended);
    expect(controller.statusReason, 'targetMappingUnavailable');
    expect(controller.surfaceVisible, isFalse);
    final int claims = providerClaims;
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'suspended',
        status: 'targetMappingUnavailable',
      ),
    );
    expect(providerClaims, claims);
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'active',
        status: 'visible',
        surfaceVisible: true,
        providerKind: 4,
        providerId: 11,
        providerStatus: 2,
      ),
    );
    expect(controller.status, GalAttachedTextStatus.activeAttached);
    expect(controller.surfaceVisible, isTrue);
  });

  test('measured calibration cannot cross a session change', () async {
    await sync();
    await controller.setMode(GalLookupSurfaceMode.attachedOnly);
    final GalAttachedSurfaceTarget previous = controller.target!;
    await sync(sessionEpoch: 9002);
    expect(
      await controller.applyMeasuredCalibration(
        expectedTarget: previous,
        expectedExeSha256: _sha,
        variant: measuredVariant(),
      ),
      isFalse,
    );
    expect(controller.profile!.variants, isEmpty);
  });

  test(
    'mode change during measured profile save prevents late activation',
    () async {
      await sync();
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      preferenceWriteGate = Completer<void>();
      final Future<bool> applying = controller.applyMeasuredCalibration(
        expectedTarget: controller.target!,
        expectedExeSha256: _sha,
        variant: measuredVariant(),
      );
      await Future<void>.delayed(Duration.zero);
      final Future<void> disabling = controller.setMode(
        GalLookupSurfaceMode.off,
      );
      preferenceWriteGate!.complete();
      expect(await applying, isFalse);
      await disabling;
      expect(controller.profile!.mode, GalLookupSurfaceMode.off);
      expect(controller.status, GalAttachedTextStatus.disabled);
      expect(jsonDecode(preferences[key()]! as String)['mode'], 'off');
    },
  );

  test('failed measured profile save does not activate it', () async {
    await sync();
    await controller.setMode(GalLookupSurfaceMode.attachedOnly);
    final GalLookupSurfaceProfileV1? previous = controller.profile;
    preferenceWriteError = StateError('disk failed');
    port.calls.clear();
    expect(
      await controller.applyMeasuredCalibration(
        expectedTarget: controller.target!,
        expectedExeSha256: _sha,
        variant: measuredVariant(),
      ),
      isFalse,
    );
    expect(controller.profile, same(previous));
    expect(
      port.calls.any((String call) => call.startsWith('configure:')),
      isFalse,
    );
  });

  void calibrationState(
    String status, {
    bool visible = false,
    String? reason,
    bool observed = false,
    GalAttachedShieldStatus shield = const GalAttachedShieldStatus(),
  }) {
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: visible ? 'calibrating' : 'suspended',
        status: status,
        reason: reason,
        surfaceVisible: visible,
        probeStartObservedIndex: observed ? 0 : null,
        probeMiddleObservedIndex: observed ? 3 : null,
        probeEndObservedIndex: observed ? 6 : null,
        shield: shield,
      ),
    );
  }

  test(
    'launch identity is explicit while attach identity is PID-derived',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync(launchExePath: r'C:\Games\Launcher\start.exe');
      expect(port.lastInspectLaunchExePath, r'C:\Games\Launcher\start.exe');

      final int firstSurfaceEpoch = controller.target!.surfaceEpoch;
      await sync(launchExePath: r'C:\Games\Launcher\other.exe');
      expect(controller.target!.surfaceEpoch, greaterThan(firstSurfaceEpoch));
      expect(port.lastInspectLaunchExePath, r'C:\Games\Launcher\other.exe');
    },
  );

  test(
    'risk acceptance is no longer demanded: unaccepted profile still activates',
    () async {
      // BUG-2154：通用遮罩层的结论**永远**只能是 Partial（hook 里
      // kLookupShieldStatusVerified 没有任何生产者，全仓 status_flags 只有
      // Faulted/KnownUncovered/Partial 三个赋值点），于是旧的
      // `!riskAccepted && conclusion != verified` 准入门对**每一个**游戏恒成立，把面板
      // 整个挡在门外——用户必须先去 texthooker 工具条上点一次「确认点击风险」，而游戏里
      // 没有任何提示指向它。风险现已恒定接受（_unsafeLeftClickAlwaysAccepted），这条
      // 用例钉住那道门不会回来：profile 里明确没接受过，照样直接可用。
      preferences[key()] = jsonEncode(_profile(accepted: false).toJson());
      await sync();

      expect(controller.status, GalAttachedTextStatus.activeAttached);
      expect(controller.needsUnsafeRiskAcceptance, isFalse);
      expect(controller.unsafeRiskAcceptanceRequest, isNull);
    },
  );

  test(
    'path-key profile selects variant then pushes hooked body text',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();

      expect(controller.status, GalAttachedTextStatus.activeAttached);
      expect(controller.isUnsafeInputActive, isTrue);
      expect(providerClaims, 1, reason: 'attached publish 前必须先退役 native route');
      expect(port.calls, <String>[
        'inspect',
        'configure:attachedOnly:true',
        'updateText',
      ]);
      expect(port.texts.single.text, 'これは本文テストです');
      expect(port.texts.single.generation, 1);
    },
  );

  test('BUG-2137 一字未推时的 noGlyphClusters 回到等正文而不是终态 fallback', () async {
    preferences[key()] = jsonEncode(
      _profile(mode: GalLookupSurfaceMode.auto).toJson(),
    );
    // 子面还没拿到任何正文就回 noGlyphClusters：这是必然，不是失败。
    await sync(text: '');
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'ready',
        status: 'noGlyphClusters',
      ),
    );
    await pumpEventQueue();

    expect(
      controller.status,
      GalAttachedTextStatus.waitingForBodyThread,
      reason:
          '降级成 fallback 就再也回不来：syncSession 只在 waitingForBodyThread 上'
          '因新正文重新评估，后面每一行都会停在 fallback/noGlyphClusters',
    );
    expect(
      controller.statusReason,
      'state_event_no_glyph_clusters_before_text',
    );
    expect(controller.surfaceVisible, isFalse);

    // 正文到了就能正常继续，不需要重启会话。
    await sync();
    expect(controller.status, GalAttachedTextStatus.activeAttached);
  });

  test('BUG-2139 已在等正文且正文一直都在时，同一句也要能把状态救回来', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    await sync();
    expect(controller.status, GalAttachedTextStatus.activeAttached);

    // 子面回 emptyText，把状态推回「等正文」——此时 `_latestSourceText` 早已非空。
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'ready',
        status: 'emptyText',
      ),
    );
    await pumpEventQueue();
    expect(controller.status, GalAttachedTextStatus.waitingForBodyThread);

    // 同一句再同步一轮：「正文从无到有」的边沿不会再出现，旧判据在这里永远不
    // 重新评估，状态就永久停在等正文（真机 WoH 上正是如此）。
    await sync();
    expect(
      controller.status,
      GalAttachedTextStatus.activeAttached,
      reason: 'BUG-2139：恢复不能只挂在 bodyArrived 这个一次性边沿上',
    );
  });

  test('BUG-2137 registry 交接期间的 noGlyphClusters 不降级成 fallback', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    port.configureResult = const GalAttachedCallResult(
      status: 'geometryProviderPending',
      providerKind: 2,
      providerId: 3,
      providerStatus: 2,
    );
    await sync();
    expect(controller.status, GalAttachedTextStatus.suspended);
    expect(controller.statusReason, 'geometryProviderPending');
    expect(controller.attachedProviderClaimed, isTrue);

    // 交接未完成时正文只是被 staged，子面还没渲染，这条是预期而非失败。
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'ready',
        status: 'noGlyphClusters',
      ),
    );
    await pumpEventQueue();

    expect(
      controller.status,
      GalAttachedTextStatus.suspended,
      reason: '降级成 fallback 会把子面藏掉，registry 交接从此完不成',
    );
    expect(controller.statusReason, 'geometryProviderPending');
    expect(controller.attachedProviderClaimed, isTrue);

    // 交接完成后照常收敛。
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'visible',
        status: 'visible',
        surfaceVisible: true,
        providerKind: 4,
        providerId: 11,
        providerStatus: 1,
      ),
    );
    await pumpEventQueue();
    expect(controller.status, GalAttachedTextStatus.activeAttached);
  });

  test('BUG-2137 正文推送前的 noGlyphClusters 不得撤回共享认领', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    port.configureResult = const GalAttachedCallResult(
      status: 'geometryProviderPending',
      providerKind: 2,
      providerId: 3,
      providerStatus: 2,
    );

    await sync();
    expect(controller.attachedProviderClaimed, isTrue);
    expect(port.texts, isNotEmpty);

    // 子面回一条 noGlyphClusters：本轮渲染不出内容，但 attached 通路没坏。
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'ready',
        status: 'noGlyphClusters',
      ),
    );
    await pumpEventQueue();

    expect(
      controller.attachedProviderClaimed,
      isTrue,
      reason:
          'BUG-2137：撤回共享认领会让注入侧 registry 永远不给 kind=4/id=11，'
          '与 BUG-2142 是同一个活锁',
    );
    // fail-closed 的部分保持不变：面藏起来、状态降级。
    expect(controller.surfaceVisible, isFalse);
    expect(controller.status, GalAttachedTextStatus.suspended);

    // 认领还在，注入侧一旦把 attached 判成 ready 就能正常收敛。
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'visible',
        status: 'visible',
        surfaceVisible: true,
        providerKind: 4,
        providerId: 11,
        providerStatus: 1,
      ),
    );
    await pumpEventQueue();
    expect(controller.status, GalAttachedTextStatus.activeAttached);
  });

  test(
    'registry handoff pending stores text but cannot activate before kind 4/id 11',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      port.configureResult = const GalAttachedCallResult(
        status: 'geometryProviderPending',
        providerKind: 2,
        providerId: 3,
        providerStatus: 2,
      );

      await sync();

      expect(controller.status, GalAttachedTextStatus.suspended);
      expect(controller.statusReason, 'geometryProviderPending');
      expect(controller.attachedProviderClaimed, isTrue);
      expect(port.texts.single.text, 'これは本文テストです');

      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'visible',
          status: 'visible',
          surfaceVisible: true,
          providerKind: 4,
          providerId: 11,
          providerStatus: 1,
        ),
      );
      await pumpEventQueue();

      expect(controller.status, GalAttachedTextStatus.activeAttached);
      expect(controller.surfaceVisible, isTrue);
      expect(port.texts, hasLength(1));
    },
  );

  test(
    'successful configure cannot activate without attached registry ownership',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      port.configureResult = const GalAttachedCallResult(
        status: 'ready',
        providerKind: 2,
        providerId: 3,
        providerStatus: 2,
      );

      await sync();

      expect(controller.status, GalAttachedTextStatus.suspended);
      expect(controller.statusReason, 'geometryProviderPending');
      expect(controller.surfaceVisible, isFalse);
      expect(port.texts.single.text, 'これは本文テストです');
    },
  );

  test(
    'missing profile calibrates only in manual mode after three probes',
    () async {
      await sync();
      // 自动模式不再引导校准：没有档案时安静挂起，校准入口也不给。
      expect(controller.status, GalAttachedTextStatus.suspended);
      expect(controller.canCalibrate, isFalse);
      expect(
        await controller.beginCalibration(acceptUnsafeLeftClick: true),
        isFalse,
        reason: '自动模式下即便已接受风险也不得进入校准态',
      );
      // 切进手动模式：档案由 setMode 建出，校准入口此时可用。这条以前停在
      // needsRiskAcceptance——那道门是 BUG-2154 拆掉的（风险恒定接受），拆掉后
      // 手动模式直接落到「未校准」。
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      expect(controller.status, GalAttachedTextStatus.needsCalibration);
      expect(controller.canCalibrate, isTrue);
      expect(
        await controller.beginCalibration(acceptUnsafeLeftClick: true),
        isTrue,
      );
      expect(port.texts.single.text, 'これは本文テストです');

      const GalLookupNormalizedRectV1 committed = GalLookupNormalizedRectV1(
        left: 0.12,
        top: 0.62,
        width: 0.76,
        height: 0.3,
      );
      expect(
        await controller.updateCalibration(
          bodyRect: committed,
          probes: _probes,
        ),
        isTrue,
      );
      expect(controller.calibrationProbeMask, 0);
      expect(
        await controller.updateCalibration(
          bodyRect: committed,
          probes: _probes,
        ),
        isTrue,
      );
      expect(controller.calibrationProbeMask, 7);
      expect(await controller.commitCalibration(probes: _probes), isTrue);
      await controller.handleCalibrationCommitted(
        GalAttachedCalibrationEvent(
          target: controller.target!,
          bodyRect: committed,
          referenceClient: _client,
          riskAccepted: true,
          calibrationProbeMask: 7,
        ),
      );

      expect(controller.status, GalAttachedTextStatus.activeAttached);
      expect(controller.profile?.variants.single.bodyRect, committed);
      expect(controller.profile?.mode, GalLookupSurfaceMode.attachedOnly);
      expect(
        GalLookupSurfaceProfileV1.tryFromJson(
          jsonDecode(preferences[key()]! as String),
        ),
        isNotNull,
      );
    },
  );

  test(
    'pending and background calibration keep the editable session',
    () async {
      await sync();
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      port.calibrationResult = const GalAttachedCallResult(
        status: 'shieldHandshakePending',
        reason: 'input_shield_rehandshake_pending',
      );
      expect(
        await controller.beginCalibration(acceptUnsafeLeftClick: true),
        isTrue,
      );
      expect(controller.calibrationActive, isTrue);
      expect(
        controller.calibrationStatus,
        GalAttachedCalibrationStatus.preparing,
      );
      expect(controller.status, GalAttachedTextStatus.suspended);
      expect(controller.surfaceVisible, isFalse);
      expect(controller.canCaptureCalibrationSample, isFalse);
      expect(controller.canCalibrate, isFalse);

      calibrationState('targetBackground');
      expect(controller.calibrationStatus, GalAttachedCalibrationStatus.paused);
      const GalLookupTextLayoutV1 layout = GalLookupTextLayoutV1(
        lineHeight: 1.5,
      );
      expect(await controller.updateCalibrationStyle(layout), isTrue);
      expect(controller.draftLayout, layout);
      expect(
        await controller.updateCalibration(
          bodyRect: GalAttachedTextController.defaultBodyRect,
          probes: _probes,
        ),
        isTrue,
      );
      expect(controller.attachedProviderClaimed, isTrue);

      calibrationState('calibrating', visible: true);
      expect(controller.calibrationStatus, GalAttachedCalibrationStatus.ready);
      expect(controller.status, GalAttachedTextStatus.calibrating);
      calibrationState('targetBackground');
      await controller.cancelCalibration();
      expect(
        port.calls.where((String call) => call == 'calibrationCancel'),
        hasLength(1),
      );
      expect(controller.calibrationActive, isFalse);
      expect(controller.calibrationStatus, GalAttachedCalibrationStatus.idle);
      expect(controller.draftBodyRect, isNull);
    },
  );

  test(
    'hidden calibrating token is not proof of a ready input surface',
    () async {
      await sync();
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      await controller.beginCalibration(acceptUnsafeLeftClick: true);
      calibrationState('calibrating');
      expect(
        controller.calibrationStatus,
        GalAttachedCalibrationStatus.preparing,
      );
      expect(controller.surfaceVisible, isFalse);
      calibrationState('shieldFaulted', reason: 'input_shield_faulted');
      expect(controller.calibrationStatus, GalAttachedCalibrationStatus.failed);
      expect(controller.calibrationActive, isTrue);
      expect(controller.attachedProviderClaimed, isTrue);
      await controller.cancelCalibration();
      expect(port.calls, contains('calibrationCancel'));
    },
  );

  test(
    'confirmed probes can commit after returning to the background panel',
    () async {
      await sync();
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      await controller.beginCalibration(acceptUnsafeLeftClick: true);
      calibrationState('calibrating', visible: true, observed: true);
      calibrationState('targetBackground', observed: true);
      expect(await controller.commitCalibration(probes: _probes), isTrue);
      expect(port.calls, contains('calibrationCommit:7'));
    },
  );

  test(
    'committed event before the method reply completes the same calibration',
    () async {
      await sync();
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      await controller.beginCalibration(acceptUnsafeLeftClick: true);
      calibrationState('targetBackground', observed: true);
      port.beforeCalibrationCommitReply = () =>
          controller.handleCalibrationCommitted(
            GalAttachedCalibrationEvent(
              target: controller.target!,
              bodyRect: GalAttachedTextController.defaultBodyRect,
              referenceClient: _client,
              riskAccepted: true,
              calibrationProbeMask: 7,
            ),
          );
      expect(await controller.commitCalibration(probes: _probes), isTrue);
      expect(controller.calibrationActive, isFalse);
      expect(controller.profile!.variants, hasLength(1));
    },
  );

  test(
    'cancelled or replaced session cannot masquerade as a successful commit',
    () async {
      await sync();
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      await controller.beginCalibration(acceptUnsafeLeftClick: true);
      calibrationState('targetBackground', observed: true);
      port.beforeCalibrationCommitReply = () => controller.cancelCalibration();
      expect(await controller.commitCalibration(probes: _probes), isFalse);
      expect(controller.profile!.variants, isEmpty);

      await controller.beginCalibration(acceptUnsafeLeftClick: true);
      calibrationState('targetBackground', observed: true);
      port.beforeCalibrationCommitReply = () => sync(sessionEpoch: 9002);
      expect(await controller.commitCalibration(probes: _probes), isFalse);
    },
  );

  test('late draft reply cannot reopen a cancelled calibration', () async {
    await sync();
    await controller.setMode(GalLookupSurfaceMode.attachedOnly);
    await controller.beginCalibration(acceptUnsafeLeftClick: true);
    port.calibrationUpdateCompleter = Completer<GalAttachedCallResult>();
    final Future<bool> update = controller.updateCalibration(
      bodyRect: GalAttachedTextController.defaultBodyRect,
      probes: _probes,
    );
    await controller.cancelCalibration();
    port.calibrationUpdateCompleter!.complete(
      const GalAttachedCallResult(status: 'calibrating', surfaceVisible: true),
    );
    expect(await update, isFalse);
    expect(controller.calibrationActive, isFalse);
    expect(controller.draftBodyRect, isNull);
  });

  test(
    'calibration logs scalar changes once with a per-session limit',
    () async {
      await sync();
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      expect(calibrationLogs, isEmpty);
      await controller.beginCalibration(acceptUnsafeLeftClick: true);
      const GalAttachedShieldStatus shield = GalAttachedShieldStatus(
        available: true,
        requestSeq: 12,
        appliedSeq: 11,
        ownerKind: 4,
        targetHwnd: 77,
        transactionId: 4294967297,
        activeButtons: 1,
        allowRisk: true,
        requiredMask: 127,
        readyMask: 3,
        observedMask: 1,
        statusFlags: 2,
      );
      calibrationState(
        'calibrating',
        visible: true,
        observed: true,
        shield: shield,
      );
      final int count = calibrationLogs.length;
      calibrationState(
        'calibrating',
        visible: true,
        observed: true,
        shield: shield,
      );
      expect(calibrationLogs, hasLength(count));
      expect(calibrationLogs.last, contains('probeIndices=0,3,6'));
      expect(calibrationLogs.last, contains('transaction=4294967297'));
      expect(calibrationLogs.last, contains('request=12 applied=11 owner=4'));
      for (int index = 0; index < 100; index++) {
        calibrationState('shieldHandshakePending', reason: 'pending_$index');
      }
      expect(calibrationLogs, hasLength(64));
      expect(
        calibrationLogs.join(),
        isNot(contains(controller.latestSourceText)),
      );
      await controller.cancelCalibration();
      calibrationState('targetBackground');
      expect(calibrationLogs, hasLength(64));
    },
  );

  test('incomplete or invalid probe positions cannot commit', () async {
    await sync();
    await controller.setMode(GalLookupSurfaceMode.attachedOnly);
    expect(
      await controller.beginCalibration(acceptUnsafeLeftClick: true),
      isTrue,
      reason: '手动模式下校准必须真起来，否则下面的断言全是空转',
    );
    const GalAttachedCalibrationProbes invalid = GalAttachedCalibrationProbes(
      startIndex: 0,
      middleIndex: 0,
      endIndex: 2,
      startConfirmed: true,
      middleConfirmed: true,
      endConfirmed: false,
    );
    expect(await controller.commitCalibration(probes: invalid), isFalse);
    expect(port.calls, isNot(contains('calibrationCommit:3')));
  });

  test('calibration updates accumulate partial probe confirmations', () async {
    await sync();
    await controller.setMode(GalLookupSurfaceMode.attachedOnly);
    expect(
      await controller.beginCalibration(acceptUnsafeLeftClick: true),
      isTrue,
      reason: '手动模式下校准必须真起来，否则下面的断言全是空转',
    );
    const GalAttachedCalibrationProbes startOnly = GalAttachedCalibrationProbes(
      startIndex: 0,
      middleIndex: 3,
      endIndex: 6,
      startConfirmed: true,
      middleConfirmed: false,
      endConfirmed: false,
    );
    expect(
      await controller.updateCalibration(
        bodyRect: GalAttachedTextController.defaultBodyRect,
        probes: startOnly,
      ),
      isTrue,
    );
    expect(controller.calibrationProbeMask, 0);
    expect(
      await controller.updateCalibration(
        bodyRect: GalAttachedTextController.defaultBodyRect,
        probes: startOnly,
      ),
      isTrue,
    );
    expect(controller.calibrationProbeMask, 1);
    expect(await controller.commitCalibration(probes: startOnly), isFalse);
  });

  test('empty selected thread waits and cannot start calibration', () async {
    await sync(text: '');
    // 先切到手动模式，把「模式不对」这条门排除掉，剩下的唯一拦截理由才是空正文。
    await controller.setMode(GalLookupSurfaceMode.attachedOnly);
    expect(controller.status, GalAttachedTextStatus.waitingForBodyThread);
    expect(controller.canCalibrate, isFalse);
    expect(
      await controller.beginCalibration(acceptUnsafeLeftClick: true),
      isFalse,
    );
  });

  test('one-percent miss needs a new calibration variant', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    port.inspection = const GalAttachedCallResult(
      exePath: r'C:\Games\Sample\game.exe',
      exeSha256: _sha,
      referenceClient: GalLookupReferenceClientV1(
        widthPx: 1024,
        heightPx: 768,
        dpi: 96,
      ),
    );
    await sync();
    expect(controller.status, GalAttachedTextStatus.needsCalibration);
    expect(port.calls, <String>['inspect']);
  });

  test('off disables a nativeOnly profile without a provider', () async {
    preferences[key()] = jsonEncode(
      _profile(mode: GalLookupSurfaceMode.nativeOnly).toJson(),
    );
    await sync();
    expect(controller.status, GalAttachedTextStatus.suspended);

    await controller.setMode(GalLookupSurfaceMode.off);
    expect(controller.status, GalAttachedTextStatus.disabled);
  });

  test('off remains fail closed when preference persistence fails', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    await sync(sessionEpoch: 9051);
    expect(controller.status, GalAttachedTextStatus.activeAttached);
    expect(controller.isUnsafeInputActive, isTrue);
    preferenceWriteError = StateError('mode persistence failed');

    await expectLater(
      controller.setMode(GalLookupSurfaceMode.off),
      throwsA(isA<StateError>()),
    );

    expect(controller.profile?.mode, GalLookupSurfaceMode.off);
    expect(controller.status, GalAttachedTextStatus.disabled);
    expect(controller.isUnsafeInputActive, isFalse);
    expect(controller.surfaceVisible, isFalse);
    expect(port.calls.where((String call) => call == 'detach'), isNotEmpty);
  });

  test(
    'verified native provider wins auto without profile or attached configure',
    () async {
      port.inspection = const GalAttachedCallResult(
        status: 'ready',
        exePath: r'C:\Games\Sample\game.exe',
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: 1,
        providerId: 1,
        providerStatus: 1,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x01),
      );

      await sync();

      expect(controller.status, GalAttachedTextStatus.activeNative);
      expect(controller.surfaceVisible, isFalse);
      expect(controller.profile, isNull);
      expect(port.calls, <String>['inspect']);
      expect(port.texts, isEmpty);
    },
  );

  for (final String pendingStatus in <String>[
    'shieldHandshakePending',
    'nativeProviderPendingNeutral',
    'detached',
  ]) {
    test('BUG-2154 native discovery waits for $pendingStatus', () async {
      port.inspection = GalAttachedCallResult(
        status: pendingStatus,
        exePath: _exePath,
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: 2,
        providerId: 3,
        providerStatus: 1,
        shield: const GalAttachedShieldStatus(
          available: true,
          statusFlags: 0x02,
        ),
      );
      await sync();
      expect(controller.status, GalAttachedTextStatus.suspended);
      expect(controller.statusReason, pendingStatus);
      expect(controller.needsUnsafeRiskAcceptance, isFalse);
      expect(controller.profile, isNull);
      expect(port.calls, <String>['inspect']);
      expect(port.texts, isEmpty);
    });
  }

  test(
    'BUG-2154 Partial native activates without profile and suspends on rehandshake',
    () async {
      port.inspection = const GalAttachedCallResult(
        status: 'ready',
        exePath: _exePath,
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: 2,
        providerId: 3,
        providerStatus: 1,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
      );
      await sync();
      expect(controller.status, GalAttachedTextStatus.activeNative);
      expect(controller.profile, isNull);
      expect(controller.needsUnsafeRiskAcceptance, isFalse);
      expect(port.calls, <String>['inspect']);

      for (final String status in <String>['shieldHandshakePending', 'ready']) {
        controller.handleSurfaceStateChanged(
          GalAttachedSurfaceStateEvent(
            target: controller.target!,
            state: status == 'ready' ? 'targetReady' : 'suspended',
            status: status,
            providerKind: 2,
            providerId: 3,
            providerStatus: 1,
            shield: const GalAttachedShieldStatus(
              available: true,
              statusFlags: 0x02,
            ),
          ),
        );
        expect(
          controller.status,
          status == 'ready'
              ? GalAttachedTextStatus.activeNative
              : GalAttachedTextStatus.suspended,
        );
      }
      expect(port.texts, isEmpty);
    },
  );

  test(
    'BUG-2154 configure cannot activate a ready native provider before handshake',
    () async {
      preferences[key()] = jsonEncode(
        _profile(mode: GalLookupSurfaceMode.auto).toJson(),
      );
      port.configureResult = const GalAttachedCallResult(
        status: 'shieldHandshakePending',
        providerKind: 2,
        providerId: 3,
        providerStatus: 1,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
      );
      await sync();
      expect(controller.status, GalAttachedTextStatus.suspended);
      expect(controller.statusReason, 'shieldHandshakePending');
      expect(port.texts, isEmpty);
    },
  );

  test(
    'BUG-2154 nativeOnly re-inspects after detach without attached configure',
    () async {
      port.inspection = const GalAttachedCallResult(
        status: 'ready',
        exePath: _exePath,
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: 2,
        providerId: 3,
        providerStatus: 1,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
      );
      await sync();
      expect(controller.status, GalAttachedTextStatus.activeNative);
      port.calls.clear();
      port.inspectionCompleter = Completer<GalAttachedCallResult>();
      final Future<void> changing = controller.setMode(
        GalLookupSurfaceMode.nativeOnly,
      );
      expect(controller.status, GalAttachedTextStatus.suspended);
      await pumpEventQueue();
      expect(port.calls, <String>['detach', 'inspect']);
      expect(controller.status, GalAttachedTextStatus.suspended);
      port.inspectionCompleter!.complete(port.inspection);
      await changing;
      expect(controller.status, GalAttachedTextStatus.activeNative);
      expect(port.texts, isEmpty);
    },
  );

  for (final GalLookupSurfaceMode firstMode in <GalLookupSurfaceMode>[
    GalLookupSurfaceMode.nativeOnly,
    GalLookupSurfaceMode.off,
  ]) {
    test(
      'BUG-2154 auto joins pending ${firstMode.name} detach before inspect',
      () async {
        port.inspection = const GalAttachedCallResult(
          status: 'ready',
          exePath: _exePath,
          exeSha256: _sha,
          referenceClient: _client,
          providerKind: 2,
          providerId: 3,
          providerStatus: 1,
          shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
        );
        await sync();
        port.calls.clear();
        port.detachCompleter = Completer<GalAttachedCallResult>();
        final Future<void> first = controller.setMode(firstMode);
        final Future<void> latest = controller.setMode(
          GalLookupSurfaceMode.auto,
        );
        await pumpEventQueue();
        expect(controller.status, GalAttachedTextStatus.suspended);
        expect(port.calls, <String>['detach']);
        port.detachCompleter!.complete(port.detachResult);
        await Future.wait<void>(<Future<void>>[first, latest]);
        expect(port.calls, <String>['detach', 'inspect']);
        expect(controller.profile?.mode, GalLookupSurfaceMode.auto);
        expect(controller.status, GalAttachedTextStatus.activeNative);
        expect(port.texts, isEmpty);
      },
    );
  }

  test('mismatched native provider kind/id pair cannot win auto', () async {
    port.inspection = const GalAttachedCallResult(
      status: 'activeNative',
      exePath: r'C:\Games\Sample\game.exe',
      exeSha256: _sha,
      referenceClient: _client,
      providerKind: 1,
      providerId: 3,
      providerStatus: 2,
      shield: GalAttachedShieldStatus(available: true, statusFlags: 0x01),
    );

    await sync();

    // kind/id 配对不合法 → 不得赢下 auto；自动模式没有档案时安静挂起，
    // 不再报 needsCalibration 去引导用户开校准。
    expect(controller.status, GalAttachedTextStatus.suspended);
    expect(controller.surfaceVisible, isFalse);
    expect(port.calls, <String>['inspect']);
    expect(port.texts, isEmpty);
  });

  test('clear cancels an older attached activation before configure', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    providerClaimGate = Completer<void>();

    final Future<void> syncing = sync(sessionEpoch: 9157);
    await pumpEventQueue();
    expect(providerClaims, 1);
    expect(
      port.calls.where((String call) => call.startsWith('configure:')),
      isEmpty,
    );

    await controller.clearProfile();
    providerClaimGate!.complete();
    await syncing;

    expect(controller.profile, isNull);
    expect(controller.status, GalAttachedTextStatus.needsCalibration);
    expect(
      port.calls.where((String call) => call.startsWith('configure:')),
      isEmpty,
      reason: 'clear 必须在旧 provider claim 返回前取消旧 activation op',
    );
  });

  test(
    'two-phase sync installs the selected slot before publishing text',
    () async {
      preferences[key()] = jsonEncode(
        GalLookupSurfaceProfileV1(
          exePath: _exePath,
          exeSha256: _sha,
          mode: GalLookupSurfaceMode.attachedOnly,
          unsafeLeftClickAccepted: true,
          variants: <GalLookupSurfaceVariantV1>[
            _variant(slot: GalLookupCalibrationSlotV1.dialogue),
            _variant(slot: GalLookupCalibrationSlotV1.narration),
          ],
        ).toJson(),
      );
      const String dialogue = '「会話」';
      const String narration = '地の文です';
      await sync(text: dialogue);
      expect(port.texts.last.text, dialogue);

      // Central sync inspects first, then admits/configures the chosen layout.
      await sync(text: narration, inspectOnly: true);
      expect(controller.latestSourceText, narration);
      expect(port.texts.last.text, dialogue);
      expect(
        controller.activeVariant?.slot,
        GalLookupCalibrationSlotV1.dialogue,
      );

      // A visibility event from the old native layout cannot claim that the
      // new slot has already been installed.
      void reportVisible() => controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'active',
          status: 'visible',
          surfaceVisible: true,
          providerKind: 4,
          providerId: 11,
          providerStatus: 2,
        ),
      );
      reportVisible();
      expect(
        controller.activeVariant?.slot,
        GalLookupCalibrationSlotV1.dialogue,
      );
      expect(controller.status, GalAttachedTextStatus.suspended);

      final Completer<GalAttachedCallResult> configuring =
          Completer<GalAttachedCallResult>();
      port.configureCompleters.add(configuring);
      final Future<void> secondPhase = sync(text: narration);
      await pumpEventQueue();
      expect(port.configuredSlots, <GalLookupCalibrationSlotV1?>[
        GalLookupCalibrationSlotV1.dialogue,
        GalLookupCalibrationSlotV1.narration,
      ]);
      expect(port.texts.last.text, dialogue);
      reportVisible();
      expect(
        controller.activeVariant?.slot,
        GalLookupCalibrationSlotV1.dialogue,
      );
      configuring.complete(port.configureResult);
      await secondPhase;
      expect(
        controller.activeVariant?.slot,
        GalLookupCalibrationSlotV1.narration,
      );
      expect(port.texts.last.text, narration);

      const String nextDialogue = '「次の会話」';
      await sync(text: nextDialogue, inspectOnly: true);
      expect(port.texts.last.text, narration);
      await sync(text: nextDialogue);
      expect(port.configuredSlots.last, GalLookupCalibrationSlotV1.dialogue);
      expect(
        controller.activeVariant?.slot,
        GalLookupCalibrationSlotV1.dialogue,
      );
      expect(port.texts.last.text, nextDialogue);
    },
  );

  test(
    'inspection racing Configure never publishes text under the old slot',
    () async {
      preferences[key()] = jsonEncode(
        GalLookupSurfaceProfileV1(
          exePath: _exePath,
          exeSha256: _sha,
          mode: GalLookupSurfaceMode.attachedOnly,
          unsafeLeftClickAccepted: true,
          variants: <GalLookupSurfaceVariantV1>[
            _variant(slot: GalLookupCalibrationSlotV1.dialogue),
            _variant(slot: GalLookupCalibrationSlotV1.narration),
          ],
        ).toJson(),
      );
      const String firstDialogue = '「会話」';
      const String narration = '地の文です';
      const String nextDialogue = '「次の会話」';
      await sync(text: firstDialogue);
      final Completer<GalAttachedCallResult> configuring =
          Completer<GalAttachedCallResult>();
      port.configureCompleters.add(configuring);
      final Future<void> narrationPhase = sync(text: narration);
      await pumpEventQueue();
      expect(port.configuredSlots.last, GalLookupCalibrationSlotV1.narration);

      await sync(text: nextDialogue, inspectOnly: true);
      configuring.complete(port.configureResult);
      await narrationPhase;
      expect(
        controller.activeVariant?.slot,
        GalLookupCalibrationSlotV1.narration,
      );
      expect(port.texts.last.text, firstDialogue);

      await sync(text: nextDialogue);
      expect(port.configuredSlots.last, GalLookupCalibrationSlotV1.dialogue);
      expect(port.texts.last.text, nextDialogue);
    },
  );

  test(
    'slot changes keep the latest activation and reject stale text hits',
    () async {
      final GalLookupSurfaceProfileV1 profile = GalLookupSurfaceProfileV1(
        exePath: _exePath,
        exeSha256: _sha,
        mode: GalLookupSurfaceMode.attachedOnly,
        unsafeLeftClickAccepted: true,
        variants: <GalLookupSurfaceVariantV1>[
          _variant(slot: GalLookupCalibrationSlotV1.dialogue),
          _variant(slot: GalLookupCalibrationSlotV1.narration),
        ],
      );
      preferences[key()] = jsonEncode(profile.toJson());

      final Completer<GalAttachedCallResult> firstConfigure =
          Completer<GalAttachedCallResult>();
      port.configureCompleters.add(firstConfigure);
      const String firstDialogue = '「最初の台詞」';
      final Future<void> first = sync(text: firstDialogue);
      await pumpEventQueue();
      expect(port.configuredSlots, <GalLookupCalibrationSlotV1?>[
        GalLookupCalibrationSlotV1.dialogue,
      ]);

      firstConfigure.complete(port.configureResult);
      await first;
      expect(controller.status, GalAttachedTextStatus.activeAttached);
      expect(
        controller.activeVariant?.slot,
        GalLookupCalibrationSlotV1.dialogue,
      );

      final Completer<GalAttachedCallResult> narrationConfigure =
          Completer<GalAttachedCallResult>();
      final Completer<GalAttachedCallResult> finalDialogueConfigure =
          Completer<GalAttachedCallResult>();
      port.configureCompleters.addAll(<Completer<GalAttachedCallResult>>[
        narrationConfigure,
        finalDialogueConfigure,
      ]);
      const String narration = 'これは地の文です';
      const String finalDialogue = '「戻った台詞」';
      final Future<void> second = sync(text: narration);
      await pumpEventQueue();
      await sync(text: '更新された地の文です');
      expect(
        port.texts.map((({String text, int generation}) value) => value.text),
        <String>[firstDialogue],
        reason: '同类的新句必须等对应排版生效，不能先推入旧对话字格',
      );
      final Future<void> third = sync(text: finalDialogue);
      await pumpEventQueue();

      expect(port.configuredSlots, <GalLookupCalibrationSlotV1?>[
        GalLookupCalibrationSlotV1.dialogue,
        GalLookupCalibrationSlotV1.narration,
        GalLookupCalibrationSlotV1.dialogue,
      ]);

      final GalAttachedSurfaceTarget target = controller.target!;
      await controller.handleLookupText(
        GalAttachedLookupHitV19(
          target: target,
          sourceText: firstDialogue,
          textGeneration: controller.textGeneration,
          charIndex: 0,
          sourceLength: 1,
        ),
      );
      expect(lookups, isEmpty, reason: '配置等待期间，旧正文不能绕过 latest source 校验触发查词');

      // The narration reply arrives after the third operation has taken over.
      // It must not replace the selected dialogue slot or push narration text.
      narrationConfigure.complete(port.configureResult);
      await second;
      expect(
        controller.activeVariant?.slot,
        GalLookupCalibrationSlotV1.dialogue,
      );
      expect(
        port.texts.map((({String text, int generation}) value) => value.text),
        isNot(contains(narration)),
      );

      finalDialogueConfigure.complete(port.configureResult);
      await third;
      expect(controller.status, GalAttachedTextStatus.activeAttached);
      expect(
        controller.activeVariant?.slot,
        GalLookupCalibrationSlotV1.dialogue,
      );
      expect(port.texts.last.text, finalDialogue);
      expect(controller.latestSourceText, finalDialogue);
    },
  );

  test('faulted shield cannot be bypassed by persisted risk', () async {
    preferences[key()] = jsonEncode(
      _profile(mode: GalLookupSurfaceMode.auto).toJson(),
    );
    port.inspection = const GalAttachedCallResult(
      status: 'activeNative',
      exePath: r'C:\Games\Sample\game.exe',
      exeSha256: _sha,
      referenceClient: _client,
      providerKind: 3,
      providerId: 9,
      providerStatus: 2,
      shield: GalAttachedShieldStatus(available: true, statusFlags: 0x08),
    );

    await sync();

    expect(controller.status, GalAttachedTextStatus.fallback);
    expect(controller.surfaceVisible, isFalse);
    expect(port.calls, <String>['inspect']);
  });

  test('nativeOnly without a coherent provider stays suspended', () async {
    preferences[key()] = jsonEncode(
      _profile(mode: GalLookupSurfaceMode.nativeOnly).toJson(),
    );

    await sync();

    expect(controller.status, GalAttachedTextStatus.suspended);
    expect(controller.surfaceVisible, isFalse);
    expect(port.calls, <String>['inspect']);
    expect(
      controller.needsUnsafeRiskAcceptance,
      isFalse,
      reason:
          'suspended 是注入 registry 起来前的常态：没铸过风险 token 就不能报「需要'
          '确认」。这一位恒真会让 shouldPromptGalCaptureSetup 的 '
          'lookupRiskAcceptancePending 常驻，每局一开局捕获设置弹窗就被压制。',
    );
    expect(controller.unsafeRiskAcceptanceRequest, isNull);
  });

  test(
    'pending neutral without a minted token never claims risk acceptance',
    () async {
      // needsUnsafeRiskAcceptance 的收口点是 `_unsafeRiskAcceptanceRequestToken
      // != null`。这个用例把**其余每一个合取项都摆成真**，只留 token 为空：
      //   status  = suspended（nativeProviderPendingNeutral，注入 registry 起来
      //             前的常态，_setStatus 对 suspended 刻意不清 token）
      //   target / exePath / exeSha256 = 已 attach，全非空
      //   profile = auto（≠off）且 unsafeLeftClickAccepted = false
      //   shield  = statusFlags 0x02 → partial（≠verified、≠faulted）
      // 所以这条断言只会被 token 判据救下来。它退化 = 这一位在每局开局恒真 →
      // shouldPromptGalCaptureSetup 的 lookupRiskAcceptancePending 常驻 →
      // 捕获设置弹窗每局都被压制。
      preferences[key()] = jsonEncode(
        _profile(
          mode: GalLookupSurfaceMode.nativeOnly,
          accepted: false,
        ).toJson(),
      );
      port.configureResult = const GalAttachedCallResult(
        status: 'nativeProviderPendingNeutral',
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
      );

      await sync();

      expect(controller.status, GalAttachedTextStatus.suspended);
      expect(controller.target, isNotNull);
      expect(
        controller.shieldStatus.conclusion,
        isNot(GalAttachedShieldConclusion.verified),
      );
      expect(
        controller.shieldStatus.conclusion,
        isNot(GalAttachedShieldConclusion.faulted),
      );
      expect(
        controller.needsUnsafeRiskAcceptance,
        isFalse,
        reason: 'pendingNeutral 只是等注入侧就绪，不是「需要用户确认点击风险」',
      );
      expect(controller.unsafeRiskAcceptanceRequest, isNull);
    },
  );

  test(
    'auto configure native win and pending neutral never push text',
    () async {
      preferences[key()] = jsonEncode(
        _profile(mode: GalLookupSurfaceMode.auto).toJson(),
      );
      port.configureResult = const GalAttachedCallResult(
        status: 'activeNative',
        providerKind: 1,
        providerId: 1,
        providerStatus: 2,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x01),
      );

      await sync();

      expect(controller.status, GalAttachedTextStatus.activeNative);
      expect(controller.surfaceVisible, isFalse);
      expect(port.calls, <String>['inspect', 'configure:auto:true']);
      expect(port.texts, isEmpty);

      await controller.detach();
      port.calls.clear();
      port.configureResult = const GalAttachedCallResult(
        status: 'nativeProviderPendingNeutral',
      );
      await sync();
      expect(controller.status, GalAttachedTextStatus.suspended);
      expect(controller.surfaceVisible, isFalse);
      expect(port.calls, <String>['inspect', 'configure:auto:true']);
      expect(port.texts, isEmpty);
      // 这是 attach 成功之后落到 suspended：target/exePath/sha256 都在、profile
      // 未接受、shield 未定论——needsUnsafeRiskAcceptance 的每一个合取项都成立，
      // 唯独没铸过风险 token。这就是 token 判据唯一的收口点。它一旦退化，
      // 「注入 registry 起来前的常态」会让这一位恒真，shouldPromptGalCaptureSetup
      // 的 lookupRiskAcceptancePending 常驻，每局一开局捕获设置弹窗就被压制。
      expect(controller.target, isNotNull);
      expect(
        controller.needsUnsafeRiskAcceptance,
        isFalse,
        reason: 'pendingNeutral 只是等注入侧就绪，不是「需要用户确认点击风险」',
      );
      expect(controller.unsafeRiskAcceptanceRequest, isNull);
    },
  );

  test(
    'native retire event reactivates attached fallback and pushes text',
    () async {
      preferences[key()] = jsonEncode(
        _profile(mode: GalLookupSurfaceMode.auto).toJson(),
      );
      port.inspection = const GalAttachedCallResult(
        status: 'activeNative',
        exePath: r'C:\Games\Sample\game.exe',
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: 1,
        providerId: 1,
        providerStatus: 2,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x01),
      );
      await sync();
      expect(controller.status, GalAttachedTextStatus.activeNative);
      expect(
        controller.isUnsafeInputActive,
        isFalse,
        reason:
            'verified shield must not show an old accepted profile as risky',
      );

      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'ready',
          status: 'ready',
          surfaceVisible: false,
        ),
      );
      await pumpEventQueue();

      expect(controller.status, GalAttachedTextStatus.activeAttached);
      expect(port.texts.single.text, 'これは本文テストです');
      expect(controller.surfaceVisible, isTrue);
    },
  );

  test(
    'v19 cluster range and stale generations gate lookup callback',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      final GalAttachedSurfaceTarget target = controller.target!;
      GalAttachedLookupHitV19 hit({int? generation, int sourceLength = 1}) =>
          GalAttachedLookupHitV19(
            target: target,
            sourceText: 'これは本文テストです',
            textGeneration: generation ?? controller.textGeneration,
            charIndex: 2,
            sourceLength: sourceLength,
          );

      await controller.handleLookupText(hit(generation: 0));
      await controller.handleLookupText(hit(sourceLength: 999));
      await controller.handleLookupText(hit(sourceLength: 2));
      expect(lookups, hasLength(1));
    },
  );

  test('Shift+hover hits pass the same gate and keep the hover flag', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    await sync();
    final GalAttachedSurfaceTarget target = controller.target!;
    GalAttachedLookupHitV19 hit({required bool hover, int? generation}) =>
        GalAttachedLookupHitV19(
          target: target,
          sourceText: 'これは本文テストです',
          textGeneration: generation ?? controller.textGeneration,
          charIndex: 4,
          sourceLength: 1,
          hover: hover,
        );

    await controller.handleLookupText(hit(hover: true));
    expect(lookups, hasLength(1));
    expect(lookups.single.hover, isTrue);
    expect(lookups.single.target.targetHwnd, target.targetHwnd);

    await controller.handleLookupText(hit(hover: true, generation: 0));
    expect(lookups, hasLength(1), reason: '悬浮命中同样受 generation 门控，旧句子的悬浮不得触发查词');

    await controller.handleLookupText(hit(hover: false));
    expect(lookups, hasLength(2));
    expect(lookups.last.hover, isFalse);
  });

  test(
    'lifecycle state adopts late HWND rebind and retires old hits',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      final GalAttachedSurfaceTarget oldTarget = controller.target!;
      final GalAttachedSurfaceTarget rebound = GalAttachedSurfaceTarget(
        sessionEpoch: oldTarget.sessionEpoch,
        surfaceEpoch: oldTarget.surfaceEpoch,
        targetPid: oldTarget.targetPid,
        targetHwnd: 88,
      );
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: rebound,
          state: 'visible',
          status: 'visible',
          surfaceVisible: true,
          providerKind: 4,
          providerId: 11,
          providerStatus: 1,
        ),
      );
      expect(controller.target?.targetHwnd, 88);

      GalAttachedLookupHitV19 hit(GalAttachedSurfaceTarget target) =>
          GalAttachedLookupHitV19(
            target: target,
            sourceText: 'これは本文テストです',
            textGeneration: controller.textGeneration,
            charIndex: 2,
            sourceLength: 1,
          );
      await controller.handleLookupText(hit(oldTarget));
      await controller.handleLookupText(hit(rebound));
      expect(lookups, hasLength(1));

      // The central session snapshot can lag behind native rebind; its retired
      // HWND must not start a new surface epoch or detach the adopted target.
      await sync();
      expect(controller.target?.targetHwnd, 88);
      expect(
        port.calls.where((String call) => call == 'inspect'),
        hasLength(1),
      );

      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: oldTarget,
          state: 'visible',
          status: 'visible',
          surfaceVisible: true,
        ),
      );
      expect(controller.target?.targetHwnd, 88);
    },
  );

  test('inactive session detaches and resets state', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    await sync();
    await controller.syncSession(
      active: false,
      sessionEpoch: null,
      targetPid: 0,
      targetHwnd: 0,
    );
    expect(controller.status, GalAttachedTextStatus.disabled);
    expect(controller.target, isNull);
    expect(port.calls.last, 'detach');
  });

  test(
    'dictionary hook ownership does not block the screenshot fence',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'suspended',
          status: 'mouseHookBusy',
          reason: 'low_level_mouse_arm_failed:singleton_owned_by_other_hwnd',
        ),
      );
      final GalAttachedMiningCaptureLease? lease = await controller
          .acquireMiningCaptureLease();
      expect(lease, isNotNull);
      expect(port.calls, contains('suspendForCapture:1:1'));
      expect(await controller.acquireMiningCaptureLease(), isNull);
      port.restoreResult = const GalAttachedCallResult(
        status: 'mouseHookBusy',
        reason: 'low_level_mouse_arm_failed:singleton_owned_by_other_hwnd',
        surfaceVisible: false,
      );
      await controller.releaseMiningCaptureLease(lease!);
      expect(controller.surfaceVisible, isFalse);
      expect(port.calls, contains('restoreAfterCapture:1:1'));
    },
  );

  test(
    'other hook failures and a changed line cannot use the card fence',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'suspended',
          status: 'mouseHookBusy',
          reason: 'low_level_mouse_arm_failed:worker_unavailable',
        ),
      );
      expect(await controller.acquireMiningCaptureLease(), isNull);
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'suspended',
          status: 'mouseHookBusy',
          reason: 'low_level_mouse_arm_failed:singleton_owned_by_other_hwnd',
        ),
      );
      await sync(text: 'new occurrence while the input owner is busy');
      expect(await controller.acquireMiningCaptureLease(), isNull);
      expect(
        port.calls.where(
          (String call) => call.startsWith('suspendForCapture:'),
        ),
        isEmpty,
      );
    },
  );

  test('background sample capture leases configured hidden surface', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    await sync();
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'suspended',
        status: 'targetBackground',
      ),
    );
    expect(controller.canCaptureCalibrationSample, isTrue);
    expect(controller.calibrationCaptureNeedsAttachedLease, isTrue);
    expect(
      await controller.acquireMiningCaptureLease(),
      isNull,
      reason: 'ordinary mining keeps its existing active-only contract',
    );
    final GalAttachedMiningCaptureLease? lease = await controller
        .acquireMiningCaptureLease(allowBackgroundCalibrationCapture: true);
    expect(lease, isNotNull);
    port.restoreResult = const GalAttachedCallResult(
      status: 'targetBackground',
      reason: 'targetBackground',
      surfaceVisible: false,
    );
    await controller.releaseMiningCaptureLease(lease!);
    expect(
      controller.surfaceVisible,
      isFalse,
      reason: 'release never restores a background glyph window',
    );
  });

  test('background fresh profile sample does not need a glyph lease', () async {
    preferences[key()] = jsonEncode(
      _profile()
          .copyWith(variants: const <GalLookupSurfaceVariantV1>[])
          .toJson(),
    );
    await sync();
    expect(controller.status, GalAttachedTextStatus.needsCalibration);
    controller.handleSurfaceStateChanged(
      GalAttachedSurfaceStateEvent(
        target: controller.target!,
        state: 'suspended',
        status: 'targetBackground',
      ),
    );
    expect(controller.canCaptureCalibrationSample, isTrue);
    expect(controller.calibrationCaptureNeedsAttachedLease, isFalse);
  });

  test(
    'sample capture rejects every other suspended reason and live draft',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      for (final String status in <String>[
        'targetMinimized',
        'hitSnapshotUnavailable',
        'captureSuppressed',
        'detached',
        'geometryProviderPending',
      ]) {
        controller.handleSurfaceStateChanged(
          GalAttachedSurfaceStateEvent(
            target: controller.target!,
            state: 'suspended',
            status: status,
          ),
        );
        expect(controller.canCaptureCalibrationSample, isFalse, reason: status);
      }
      await controller.beginCalibration(acceptUnsafeLeftClick: true);
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'suspended',
          status: 'targetBackground',
        ),
      );
      expect(
        controller.canCaptureCalibrationSample,
        isFalse,
        reason: 'losing focus during live probe calibration is not sample mode',
      );
    },
  );

  test(
    'capture token releases against current text but not a newer epoch',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();

      final GalAttachedMiningCaptureLease? lease = await controller
          .acquireMiningCaptureLease();
      expect(lease, isNotNull);
      expect(controller.surfaceVisible, isFalse);
      expect(
        port.calls,
        contains('suspendForCapture:1:${lease!.captureGeneration}'),
      );
      await controller.releaseMiningCaptureLease(lease);
      expect(controller.surfaceVisible, isTrue);
      expect(
        port.calls,
        contains('restoreAfterCapture:1:${lease.captureGeneration}'),
      );

      final GalAttachedMiningCaptureLease? rejected = await controller
          .acquireMiningCaptureLease();
      expect(rejected, isNotNull);
      port.restoreResult = const GalAttachedCallResult(
        error: 'capture_restore_rejected',
        status: 'visible',
        surfaceVisible: true,
        reason: 'capture_dwm_flush_failed',
      );
      await expectLater(
        controller.releaseMiningCaptureLease(rejected!),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            'capture_dwm_flush_failed',
          ),
        ),
      );
      expect(
        controller.surfaceVisible,
        isTrue,
        reason: 'restore rejection must not leave the catch surface hidden',
      );
      port.restoreResult = const GalAttachedCallResult(
        status: 'visible',
        surfaceVisible: true,
      );

      final GalAttachedMiningCaptureLease? stale = await controller
          .acquireMiningCaptureLease();
      expect(stale, isNotNull);
      await sync(text: '次の本文です');
      final int restoreCount = port.calls
          .where((String call) => call.startsWith('restoreAfterCapture:'))
          .length;
      await controller.releaseMiningCaptureLease(stale!);
      expect(
        port.calls
            .where((String call) => call.startsWith('restoreAfterCapture:'))
            .length,
        restoreCount + 1,
        reason: '换句必须解除同一 token，不能把 capture_suppressed 永久留在 native',
      );
      expect(
        port.calls,
        contains('restoreAfterCapture:2:${stale.captureGeneration}'),
        reason: '解除 token 必须让 native 同步换句后的当前 generation',
      );
      expect(controller.surfaceVisible, isTrue);

      final GalAttachedMiningCaptureLease? oldEpoch = await controller
          .acquireMiningCaptureLease();
      expect(oldEpoch, isNotNull);
      await sync(text: '新会话正文', sessionEpoch: 9002);
      final int beforeOldEpochRelease = port.calls
          .where((String call) => call.startsWith('restoreAfterCapture:'))
          .length;
      await controller.releaseMiningCaptureLease(oldEpoch!);
      expect(
        port.calls
            .where((String call) => call.startsWith('restoreAfterCapture:'))
            .length,
        beforeOldEpochRelease,
        reason: '旧 epoch/token 必须丢弃，不能触碰新 surface',
      );
    },
  );

  test(
    'background calibration stages a changed occurrence before acquiring lease',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'suspended',
          status: 'targetBackground',
        ),
      );
      port.textSurfaceVisible = false;

      await sync(text: '后台期间的新正文');

      expect(port.texts.last.text, '后台期间的新正文');
      expect(port.texts.last.generation, 2);
      expect(controller.canCaptureCalibrationSample, isTrue);
      final GalAttachedMiningCaptureLease? lease = await controller
          .acquireMiningCaptureLease(allowBackgroundCalibrationCapture: true);
      expect(lease, isNotNull);
      expect(
        port.calls,
        contains('suspendForCapture:2:${lease!.captureGeneration}'),
      );
    },
  );

  test(
    'target background state stages text retained after no-glyph suspension',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'ready',
          status: 'noGlyphClusters',
        ),
      );

      await sync(text: 'no-glyph 期间到达的三行长正文');
      expect(port.texts, hasLength(1));

      port.textSurfaceVisible = false;
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'suspended',
          status: 'targetBackground',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(port.texts.last.text, 'no-glyph 期间到达的三行长正文');
      expect(port.texts.last.generation, 2);
      final GalAttachedMiningCaptureLease? lease = await controller
          .acquireMiningCaptureLease(allowBackgroundCalibrationCapture: true);
      expect(lease, isNotNull);
      expect(
        port.calls,
        contains('suspendForCapture:2:${lease!.captureGeneration}'),
      );
    },
  );

  test(
    'non-background suspension does not stage retained calibration text',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'ready',
          status: 'noGlyphClusters',
        ),
      );

      await sync(text: '最小化期间到达的正文');
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'suspended',
          status: 'targetMinimized',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(port.texts, hasLength(1));
      expect(controller.canCaptureCalibrationSample, isFalse);
    },
  );

  test(
    'sentence race after suspend acknowledgement compensates exact token',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      final Completer<GalAttachedCallResult> suspend =
          Completer<GalAttachedCallResult>();
      port.suspendCompleter = suspend;

      final Future<GalAttachedMiningCaptureLease?> acquiring = controller
          .acquireMiningCaptureLease();
      await Future<void>.delayed(Duration.zero);
      await sync(text: '応答待ちに届いた次の本文');
      suspend.complete(
        const GalAttachedCallResult(
          status: 'captureSuppressed',
          surfaceVisible: false,
        ),
      );

      expect(await acquiring, isNull, reason: '陈旧截图事务必须中止而不是授予 lease');
      expect(
        port.calls,
        contains('restoreAfterCapture:2:1'),
        reason: '中止前必须以同一 token 解除并同步当前文本代际',
      );
      expect(controller.surfaceVisible, isTrue);
      port.suspendCompleter = null;
      expect(
        await controller.acquireMiningCaptureLease(),
        isNotNull,
        reason: '补偿解除后不能把 Dart token 永久占住',
      );
    },
  );

  test(
    'non-ok suspend reply unwinds the exact token before returning null',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      port.suspendResult = const GalAttachedCallResult(
        error: 'malformed_reply',
      );

      expect(await controller.acquireMiningCaptureLease(), isNull);
      expect(port.calls, contains('suspendForCapture:1:1'));
      expect(
        port.calls,
        contains('restoreAfterCapture:1:1'),
        reason: 'native may have hidden before the transport reply was lost',
      );
      port.suspendResult = const GalAttachedCallResult(
        status: 'captureSuppressed',
        surfaceVisible: false,
      );
      expect(
        await controller.acquireMiningCaptureLease(),
        isNotNull,
        reason: 'same-token unwind must retire the failed acquisition lease',
      );
    },
  );

  test('concurrent release callers await one exact-token operation', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    await sync();
    final GalAttachedMiningCaptureLease lease = (await controller
        .acquireMiningCaptureLease())!;
    final Completer<GalAttachedCallResult> restore =
        Completer<GalAttachedCallResult>();
    port.restoreCompleter = restore;

    bool firstCompleted = false;
    bool secondCompleted = false;
    final Future<void> first = controller
        .releaseMiningCaptureLease(lease)
        .then((_) => firstCompleted = true);
    final Future<void> second = controller
        .releaseMiningCaptureLease(lease)
        .then((_) => secondCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(firstCompleted, isFalse);
    expect(secondCompleted, isFalse, reason: '第二个 caller 不能提前假装 release 完成');
    expect(
      port.calls.where(
        (String call) => call.startsWith('restoreAfterCapture:'),
      ),
      hasLength(1),
    );

    restore.complete(
      const GalAttachedCallResult(status: 'visible', surfaceVisible: true),
    );
    await Future.wait(<Future<void>>[first, second]);
    expect(firstCompleted, isTrue);
    expect(secondCompleted, isTrue);
    expect(controller.surfaceVisible, isTrue);
  });

  test(
    'lost restore reply detaches fail closed and retires the Dart token',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      final GalAttachedMiningCaptureLease lease = (await controller
          .acquireMiningCaptureLease())!;
      port.restoreException = StateError('restore_reply_lost');

      await expectLater(
        controller.releaseMiningCaptureLease(lease),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            'restore_reply_lost',
          ),
        ),
      );
      expect(port.calls.last, 'detach');
      expect(controller.surfaceVisible, isFalse);
      expect(controller.status, GalAttachedTextStatus.suspended);

      port.restoreException = null;
      await controller.setMode(GalLookupSurfaceMode.attachedOnly);
      expect(controller.status, GalAttachedTextStatus.activeAttached);
      expect(
        await controller.acquireMiningCaptureLease(),
        isNotNull,
        reason: '回执丢失不能让旧 Dart token 永久阻塞后续 capture',
      );
    },
  );

  test(
    'same-epoch stale restore rejection detaches instead of retrying',
    () async {
      preferences[key()] = jsonEncode(_profile().toJson());
      await sync();
      final GalAttachedMiningCaptureLease lease = (await controller
          .acquireMiningCaptureLease())!;
      port.restoreResult = const GalAttachedCallResult(
        error: 'stale_capture_lease',
        status: 'captureSuppressed',
        surfaceVisible: false,
      );

      await expectLater(
        controller.releaseMiningCaptureLease(lease),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            'stale_capture_lease',
          ),
        ),
      );
      expect(port.calls.last, 'detach');
      expect(controller.surfaceVisible, isFalse);
      expect(controller.status, GalAttachedTextStatus.suspended);
    },
  );

  test('non-ok fail-closed detach keeps capture lease latched', () async {
    preferences[key()] = jsonEncode(_profile().toJson());
    await sync();
    final GalAttachedMiningCaptureLease lease = (await controller
        .acquireMiningCaptureLease())!;
    port.restoreResult = const GalAttachedCallResult(
      error: 'stale_capture_lease',
      status: 'captureSuppressed',
    );
    port.detachResult = const GalAttachedCallResult(error: 'malformed_reply');

    await expectLater(
      controller.releaseMiningCaptureLease(lease),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('fail_closed_detach_failed'),
        ),
      ),
    );
    expect(controller.status, GalAttachedTextStatus.suspended);
    expect(controller.statusReason, 'capture_fail_closed_detach_unconfirmed');
    expect(controller.surfaceVisible, isFalse);
    expect(
      controller.needsUnsafeRiskAcceptance,
      isFalse,
      reason: 'fail-closed 的 suspended 同样没有铸过风险 token',
    );
    expect(
      await controller.acquireMiningCaptureLease(),
      isNull,
      reason: 'ambiguous native token ownership must stay fail-closed',
    );
  });

  test(
    'no glyph clusters fail closed and source text cannot forge visibility',
    () async {
      preferences[key()] = jsonEncode(
        _profile(mode: GalLookupSurfaceMode.auto).toJson(),
      );
      port.textSurfaceVisible = false;
      await sync();
      expect(controller.surfaceVisible, isFalse);

      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'ready',
          status: 'noGlyphClusters',
          surfaceVisible: false,
        ),
      );
      expect(controller.status, GalAttachedTextStatus.fallback);
      expect(controller.surfaceVisible, isFalse);
    },
  );
}
