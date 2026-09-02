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

  setUp(() {
    preferences = <String, Object?>{};
    port = _FakeSurfacePort();
    lookups = <GalAttachedLookupHitV19>[];
    providerClaims = 0;
    controller = GalAttachedTextController(
      preferenceReader: (String key) => preferences[key],
      preferenceWriter: (String key, Object? value) async {
        preferences[key] = value;
      },
      surfacePort: port,
      onBeforeAttachedActivation:
          (GalLookupSurfaceMode _, {required bool forceAttached}) async {
            providerClaims++;
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

      await controller.acceptUnsafeRiskAndRetry();
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

      await controller.acceptUnsafeRiskAndRetry();

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
  });

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
