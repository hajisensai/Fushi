import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const String _otherSha =
    'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
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
}) => GalLookupSurfaceVariantV1(
  aspectRatio: client.aspectRatio,
  referenceClient: client,
  bodyRect: GalAttachedTextController.defaultBodyRect,
  layout: const GalLookupTextLayoutV1(),
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
  GalAttachedCallResult configureResult = const GalAttachedCallResult(
    status: 'ready',
    providerKind: 4,
    providerId: 11,
    providerStatus: 1,
  );
  int nativeProbeMask = 0;
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

  @override
  Future<GalAttachedCallResult> inspectTarget(
    GalAttachedSurfaceTarget target, {
    String? launchExePath,
  }) async {
    lastInspectLaunchExePath = launchExePath;
    calls.add('inspect');
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
    return const GalAttachedCallResult(status: 'calibrating');
  }

  @override
  Future<GalAttachedCallResult> calibrationUpdate({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  }) async {
    calls.add('calibrationUpdate:${probes.confirmationMask}');
    nativeProbeMask = probes.confirmationMask;
    return GalAttachedCallResult(
      status: 'calibrating',
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
    return detachResult;
  }
}

void main() {
  late Map<String, Object?> preferences;
  late _FakeSurfacePort port;
  late GalAttachedTextController controller;
  late List<GalAttachedLookupHitV19> lookups;
  late int providerClaims;
  Completer<void>? preferenceWriteGate;
  Object? preferenceWriteError;
  Completer<void>? providerClaimGate;

  setUp(() {
    preferences = <String, Object?>{};
    port = _FakeSurfacePort();
    lookups = <GalAttachedLookupHitV19>[];
    providerClaims = 0;
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
    );
  });

  tearDown(() async {
    await controller.detach();
    controller.dispose();
  });

  Future<void> sync({
    String text = 'これは本文テストです',
    String? launchExePath,
    int sessionEpoch = 9001,
  }) => controller.syncSession(
    active: true,
    sessionEpoch: sessionEpoch,
    targetPid: 1234,
    targetHwnd: 77,
    sourceText: text,
    launchExePath: launchExePath,
  );

  String key() => GalLookupSurfaceProfileV1.preferenceKeyForExePath(_exePath);

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

  test(
    'BUG-2137 一字未推时的 noGlyphClusters 回到等正文而不是终态 fallback',
    () async {
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
        reason: '降级成 fallback 就再也回不来：syncSession 只在 waitingForBodyThread 上'
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
    },
  );

  test(
    'BUG-2138 已在等正文且正文一直都在时，同一句也要能把状态救回来',
    () async {
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
        reason: 'BUG-2138：恢复不能只挂在 bodyArrived 这个一次性边沿上',
      );
    },
  );

  test(
    'BUG-2137 registry 交接期间的 noGlyphClusters 不降级成 fallback',
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
    },
  );

  test(
    'BUG-2137 正文推送前的 noGlyphClusters 不得撤回共享认领',
    () async {
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
        reason: 'BUG-2137：撤回共享认领会让注入侧 registry 永远不给 kind=4/id=11，'
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
    },
  );

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
    'verified shield activates attached without unsafe authorization',
    () async {
      preferences[key()] = jsonEncode(_profile(accepted: false).toJson());
      port.inspection = const GalAttachedCallResult(
        status: 'inspected',
        exePath: r'C:\Games\Sample\game.exe',
        exeSha256: _sha,
        referenceClient: _client,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x01),
      );
      port.configureResult = const GalAttachedCallResult(
        status: 'ready',
        providerKind: 4,
        providerId: 11,
        providerStatus: 1,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x01),
      );

      await sync();

      expect(controller.status, GalAttachedTextStatus.activeAttached);
      expect(controller.isUnsafeInputActive, isFalse);
      expect(port.calls, <String>[
        'inspect',
        'configure:attachedOnly:false',
        'updateText',
      ]);
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
    'missing profile calibrates only after unsafe risk and three probes',
    () async {
      await sync();
      expect(controller.status, GalAttachedTextStatus.needsCalibration);
      expect(controller.canCalibrate, isTrue);
      expect(
        await controller.beginCalibration(acceptUnsafeLeftClick: false),
        isFalse,
      );
      expect(controller.status, GalAttachedTextStatus.needsRiskAcceptance);
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
      expect(controller.profile?.mode, GalLookupSurfaceMode.auto);
      expect(
        GalLookupSurfaceProfileV1.tryFromJson(
          jsonDecode(preferences[key()]! as String),
        ),
        isNotNull,
      );
    },
  );

  test('incomplete or invalid probe positions cannot commit', () async {
    await sync();
    await controller.beginCalibration(acceptUnsafeLeftClick: true);
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
    await controller.beginCalibration(acceptUnsafeLeftClick: true);
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
    expect(controller.status, GalAttachedTextStatus.waitingForBodyThread);
    expect(controller.canCalibrate, isFalse);
    expect(
      await controller.beginCalibration(acceptUnsafeLeftClick: true),
      isFalse,
    );
  });

  test(
    'exe hash change preserves variants but revokes risk until reconfirmed',
    () async {
      preferences[key()] = jsonEncode(_profile(sha: _otherSha).toJson());
      await sync();

      expect(controller.status, GalAttachedTextStatus.needsRiskAcceptance);
      expect(controller.profile?.variants, hasLength(1));
      expect(controller.profile?.exeSha256, _sha);
      expect(controller.profile?.unsafeLeftClickAccepted, isFalse);
      expect(port.calls, <String>['inspect']);

      await controller.acceptUnsafeRiskAndRetry(
        controller.unsafeRiskAcceptanceRequest!,
      );
      expect(controller.status, GalAttachedTextStatus.activeAttached);
      final GalLookupSurfaceProfileV1 persisted =
          GalLookupSurfaceProfileV1.tryFromJson(
            jsonDecode(preferences[key()]! as String),
          )!;
      expect(persisted.exeSha256, _sha);
      expect(persisted.variants, hasLength(1));
    },
  );

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

    expect(controller.status, GalAttachedTextStatus.needsCalibration);
    expect(controller.surfaceVisible, isFalse);
    expect(port.calls, <String>['inspect']);
    expect(port.texts, isEmpty);
  });

  test('adapted native providers retain and resume risk acceptance', () async {
    const List<({int kind, int id})> providers = <({int kind, int id})>[
      (kind: 1, id: 1),
      (kind: 1, id: 2),
      (kind: 2, id: 3),
      (kind: 2, id: 4),
    ];

    for (int index = 0; index < providers.length; index++) {
      final ({int kind, int id}) provider = providers[index];
      await controller.detach();
      preferences.clear();
      port.calls.clear();
      port.inspection = GalAttachedCallResult(
        status: 'activeNative',
        exePath: r'C:\Games\Sample\game.exe',
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: provider.kind,
        providerId: provider.id,
        providerStatus: 2,
        shield: const GalAttachedShieldStatus(
          available: true,
          statusFlags: 0x02,
        ),
      );

      await sync(sessionEpoch: 9100 + index);
      expect(
        controller.status,
        GalAttachedTextStatus.needsRiskAcceptance,
        reason: 'provider ${provider.kind}/${provider.id}',
      );
      final GalAttachedUnsafeRiskAcceptanceRequest request =
          controller.unsafeRiskAcceptanceRequest!;

      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'suspended',
          status: 'targetBackground',
          providerKind: provider.kind,
          providerId: provider.id,
          providerStatus: 2,
          shield: const GalAttachedShieldStatus(
            available: true,
            statusFlags: 0x02,
          ),
        ),
      );
      expect(
        controller.status,
        GalAttachedTextStatus.needsRiskAcceptance,
        reason: 'provider ${provider.kind}/${provider.id}',
      );
      expect(controller.needsUnsafeRiskAcceptance, isTrue);
      expect(controller.unsafeRiskAcceptanceRequest?.token, request.token);

      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'suspended',
          status: 'targetBackground',
          shield: const GalAttachedShieldStatus(
            available: true,
            statusFlags: 0x02,
          ),
        ),
      );

      expect(controller.status, GalAttachedTextStatus.suspended);
      expect(
        controller.needsUnsafeRiskAcceptance,
        isTrue,
        reason: 'provider ${provider.kind}/${provider.id}',
      );

      expect(await controller.acceptUnsafeRiskAndRetry(request), isTrue);
      expect(controller.profile?.unsafeLeftClickAccepted, isTrue);
      expect(controller.needsUnsafeRiskAcceptance, isFalse);

      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'ready',
          status: 'activeNative',
          providerKind: provider.kind,
          providerId: provider.id,
          providerStatus: 2,
          shield: const GalAttachedShieldStatus(
            available: true,
            statusFlags: 0x02,
          ),
        ),
      );
      expect(
        controller.status,
        GalAttachedTextStatus.activeNative,
        reason: 'provider ${provider.kind}/${provider.id}',
      );
      final GalLookupSurfaceProfileV1 persisted =
          GalLookupSurfaceProfileV1.tryFromJson(
            jsonDecode(preferences[key()]! as String),
          )!;
      expect(persisted.unsafeLeftClickAccepted, isTrue);
    }
  });

  test(
    'failed risk persistence preserves request and cannot activate',
    () async {
      port.inspection = const GalAttachedCallResult(
        status: 'activeNative',
        exePath: r'C:\Games\Sample\game.exe',
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: 1,
        providerId: 1,
        providerStatus: 2,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
      );
      await sync(sessionEpoch: 9151);
      final GalAttachedUnsafeRiskAcceptanceRequest request =
          controller.unsafeRiskAcceptanceRequest!;
      preferenceWriteError = StateError('persist failed');

      expect(await controller.acceptUnsafeRiskAndRetry(request), isFalse);

      expect(controller.profile, isNull);
      expect(controller.status, GalAttachedTextStatus.needsRiskAcceptance);
      expect(controller.needsUnsafeRiskAcceptance, isTrue);
      expect(controller.unsafeRiskAcceptanceRequest?.token, request.token);
      expect(
        preferences[key()],
        '',
        reason: 'DB 失败后的补偿写仍须撤回 eager preference cache',
      );
      expect(port.calls, <String>['inspect']);
    },
  );

  test(
    'delayed risk persistence cannot override calibration started later',
    () async {
      port.inspection = const GalAttachedCallResult(
        status: 'activeNative',
        exePath: r'C:\Games\Sample\game.exe',
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: 1,
        providerId: 1,
        providerStatus: 2,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
      );
      await sync(sessionEpoch: 9152);
      final GalAttachedUnsafeRiskAcceptanceRequest request =
          controller.unsafeRiskAcceptanceRequest!;
      preferenceWriteGate = Completer<void>();

      final Future<bool> accepting = controller.acceptUnsafeRiskAndRetry(
        request,
      );
      await pumpEventQueue();
      expect(controller.profile, isNull);
      expect(controller.needsUnsafeRiskAcceptance, isTrue);
      expect(
        controller.unsafeRiskAcceptanceRequest,
        isNull,
        reason: '同一请求持久化在途时不能重复提交',
      );

      expect(
        await controller.beginCalibration(acceptUnsafeLeftClick: true),
        isTrue,
      );
      expect(controller.status, GalAttachedTextStatus.calibrating);
      preferenceWriteGate!.complete();

      expect(await accepting, isTrue);
      expect(controller.status, GalAttachedTextStatus.calibrating);
      expect(controller.profile, isNull);
      expect(controller.needsUnsafeRiskAcceptance, isFalse);
      expect(
        port.calls.where((String call) => call.startsWith('configure:')),
        isEmpty,
      );
    },
  );

  test(
    'failed consent rolls back its cache after target replacement',
    () async {
      port.inspection = const GalAttachedCallResult(
        status: 'activeNative',
        exePath: r'C:\Games\Sample\game.exe',
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: 1,
        providerId: 1,
        providerStatus: 2,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
      );
      await sync(sessionEpoch: 9154);
      final GalAttachedUnsafeRiskAcceptanceRequest request =
          controller.unsafeRiskAcceptanceRequest!;
      preferenceWriteGate = Completer<void>();
      preferenceWriteError = StateError('persist failed after cache update');

      final Future<bool> accepting = controller.acceptUnsafeRiskAndRetry(
        request,
      );
      await pumpEventQueue();

      port.inspection = const GalAttachedCallResult(
        status: 'activeNative',
        exePath: r'C:\Games\Replacement\game.exe',
        exeSha256: _otherSha,
        referenceClient: _client,
        providerKind: 1,
        providerId: 1,
        providerStatus: 2,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
      );
      await sync(sessionEpoch: 9155);
      expect(controller.target?.sessionEpoch, 9155);
      expect(controller.needsUnsafeRiskAcceptance, isTrue);

      preferenceWriteGate!.complete();
      expect(await accepting, isFalse);
      expect(preferences[key()], '', reason: '旧目标失效也不能留下 eager accepted cache');
      expect(controller.target?.sessionEpoch, 9155);
      expect(controller.profile, isNull);
      expect(controller.needsUnsafeRiskAcceptance, isTrue);
    },
  );

  test(
    'later profile write prevents delayed consent from publishing stale state',
    () async {
      preferences[key()] = jsonEncode(
        _profile(accepted: false, mode: GalLookupSurfaceMode.auto).toJson(),
      );
      port.inspection = const GalAttachedCallResult(
        status: 'activeNative',
        exePath: r'C:\Games\Sample\game.exe',
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: 1,
        providerId: 1,
        providerStatus: 2,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
      );
      await sync(sessionEpoch: 9156);
      final GalAttachedUnsafeRiskAcceptanceRequest request =
          controller.unsafeRiskAcceptanceRequest!;
      preferenceWriteGate = Completer<void>();

      final Future<bool> accepting = controller.acceptUnsafeRiskAndRetry(
        request,
      );
      await pumpEventQueue();
      final Future<void> styling = controller.updateActiveStyle(
        const GalLookupTextLayoutV1(fontSizePerClientHeight: 0.05),
      );
      await pumpEventQueue();
      preferenceWriteGate!.complete();

      expect(await accepting, isTrue);
      await styling;
      expect(controller.profile?.unsafeLeftClickAccepted, isFalse);
      expect(controller.needsUnsafeRiskAcceptance, isTrue);
      expect(controller.unsafeRiskAcceptanceRequest?.token, request.token);
      final GalLookupSurfaceProfileV1 persisted =
          GalLookupSurfaceProfileV1.tryFromJson(
            jsonDecode(preferences[key()]! as String),
          )!;
      expect(persisted.unsafeLeftClickAccepted, isFalse);
      expect(persisted.variants.single.layout.fontSizePerClientHeight, 0.05);
    },
  );

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

  test('serialized clear cannot be overwritten by delayed consent', () async {
    port.inspection = const GalAttachedCallResult(
      status: 'activeNative',
      exePath: r'C:\Games\Sample\game.exe',
      exeSha256: _sha,
      referenceClient: _client,
      providerKind: 1,
      providerId: 1,
      providerStatus: 2,
      shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
    );
    await sync(sessionEpoch: 9153);
    final GalAttachedUnsafeRiskAcceptanceRequest request =
        controller.unsafeRiskAcceptanceRequest!;
    preferenceWriteGate = Completer<void>();

    final Future<bool> accepting = controller.acceptUnsafeRiskAndRetry(request);
    await pumpEventQueue();
    final Future<void> clearing = controller.clearProfile();
    await pumpEventQueue();
    expect(controller.profile, isNull);
    expect(controller.status, GalAttachedTextStatus.needsCalibration);
    expect(controller.needsUnsafeRiskAcceptance, isFalse);

    preferenceWriteGate!.complete();
    expect(await accepting, isTrue);
    await clearing;

    expect(preferences[key()], '');
    expect(controller.profile, isNull);
    expect(controller.status, GalAttachedTextStatus.needsCalibration);
  });

  test('stale risk request cannot authorize a replacement target', () async {
    port.inspection = const GalAttachedCallResult(
      status: 'activeNative',
      exePath: r'C:\Games\Sample\game.exe',
      exeSha256: _sha,
      referenceClient: _client,
      providerKind: 1,
      providerId: 1,
      providerStatus: 2,
      shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
    );
    await sync(sessionEpoch: 9201);
    final GalAttachedUnsafeRiskAcceptanceRequest stale =
        controller.unsafeRiskAcceptanceRequest!;

    const String replacementPath = r'c:\games\replacement\game.exe';
    port.inspection = const GalAttachedCallResult(
      status: 'activeNative',
      exePath: r'C:\Games\Replacement\game.exe',
      exeSha256: _otherSha,
      referenceClient: _client,
      providerKind: 1,
      providerId: 1,
      providerStatus: 2,
      shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
    );
    await sync(sessionEpoch: 9202);
    final GalAttachedUnsafeRiskAcceptanceRequest replacement =
        controller.unsafeRiskAcceptanceRequest!;
    expect(replacement.token, isNot(stale.token));

    expect(await controller.acceptUnsafeRiskAndRetry(stale), isFalse);
    expect(controller.profile, isNull);
    expect(
      preferences[GalLookupSurfaceProfileV1.preferenceKeyForExePath(
        replacementPath,
      )],
      isNull,
    );

    expect(await controller.acceptUnsafeRiskAndRetry(replacement), isTrue);
    expect(controller.profile?.exePath, replacementPath);
    expect(controller.profile?.unsafeLeftClickAccepted, isTrue);
  });

  test(
    'stale risk requests fail closed after ineligible state edges',
    () async {
      Future<GalAttachedUnsafeRiskAcceptanceRequest> beginRisk(
        int epoch,
      ) async {
        await controller.detach();
        preferences.clear();
        port.calls.clear();
        port.inspection = const GalAttachedCallResult(
          status: 'activeNative',
          exePath: r'C:\Games\Sample\game.exe',
          exeSha256: _sha,
          referenceClient: _client,
          providerKind: 1,
          providerId: 1,
          providerStatus: 2,
          shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
        );
        await sync(sessionEpoch: epoch);
        return controller.unsafeRiskAcceptanceRequest!;
      }

      GalAttachedUnsafeRiskAcceptanceRequest stale = await beginRisk(9301);
      await controller.setMode(GalLookupSurfaceMode.off);
      expect(controller.status, GalAttachedTextStatus.disabled);
      expect(await controller.acceptUnsafeRiskAndRetry(stale), isFalse);
      expect(controller.profile?.unsafeLeftClickAccepted, isFalse);

      stale = await beginRisk(9302);
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'ready',
          status: 'activeNative',
          providerKind: 1,
          providerId: 1,
          providerStatus: 2,
          shield: const GalAttachedShieldStatus(
            available: true,
            statusFlags: 0x01,
          ),
        ),
      );
      expect(controller.status, GalAttachedTextStatus.activeNative);
      expect(await controller.acceptUnsafeRiskAndRetry(stale), isFalse);
      expect(controller.profile, isNull);

      stale = await beginRisk(9303);
      controller.handleSurfaceStateChanged(
        GalAttachedSurfaceStateEvent(
          target: controller.target!,
          state: 'error',
          status: 'activeNative',
          providerKind: 1,
          providerId: 1,
          providerStatus: 2,
          shield: const GalAttachedShieldStatus(
            available: true,
            statusFlags: 0x08,
          ),
        ),
      );
      expect(controller.status, GalAttachedTextStatus.fallback);
      expect(await controller.acceptUnsafeRiskAndRetry(stale), isFalse);
      expect(controller.profile, isNull);

      stale = await beginRisk(9304);
      expect(
        await controller.beginCalibration(acceptUnsafeLeftClick: true),
        isTrue,
      );
      expect(controller.status, GalAttachedTextStatus.calibrating);
      expect(await controller.acceptUnsafeRiskAndRetry(stale), isFalse);
      expect(controller.profile, isNull);
    },
  );

  test(
    'detached surface with SGRE provider activates after exe acceptance',
    () async {
      port.inspection = const GalAttachedCallResult(
        // nativeOnly detaches the optional desktop surface; the independent
        // SGRE provider remains the registry's authoritative Ready owner.
        status: 'detached',
        exePath: r'C:\Games\Sample\game.exe',
        exeSha256: _sha,
        referenceClient: _client,
        providerKind: 2,
        providerId: 5,
        providerStatus: 2,
        shield: GalAttachedShieldStatus(available: true, statusFlags: 0x02),
      );

      await sync();
      expect(controller.status, GalAttachedTextStatus.needsRiskAcceptance);
      expect(controller.profile, isNull);

      await controller.acceptUnsafeRiskAndRetry(
        controller.unsafeRiskAcceptanceRequest!,
      );

      expect(controller.status, GalAttachedTextStatus.activeNative);
      expect(controller.profile?.mode, GalLookupSurfaceMode.auto);
      expect(controller.profile?.unsafeLeftClickAccepted, isTrue);
      expect(controller.profile?.variants, isEmpty);
      final GalLookupSurfaceProfileV1 persisted =
          GalLookupSurfaceProfileV1.tryFromJson(
            jsonDecode(preferences[key()]! as String),
          )!;
      expect(persisted.exeSha256, _sha);
      expect(persisted.unsafeLeftClickAccepted, isTrue);
      expect(port.calls, <String>['inspect']);
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
