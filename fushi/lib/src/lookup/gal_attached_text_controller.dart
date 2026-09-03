import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

typedef GalAttachedPreferenceReader = Object? Function(String key);
typedef GalAttachedPreferenceWriter =
    Future<void> Function(String key, Object? value);
typedef GalAttachedLayoutBuilder =
    GalLookupTextLayoutV1 Function(GalLookupReferenceClientV1 referenceClient);
typedef GalAttachedLookupCallback =
    FutureOr<void> Function(GalAttachedLookupHitV19 hit);
typedef GalAttachedBeforeActivationCallback =
    Future<void> Function(
      GalLookupSurfaceMode profileMode, {
      required bool forceAttached,
    });

/// Public plan state. The enum mirrors the user-facing decision flow rather
/// than leaking runner implementation tokens.
enum GalAttachedTextStatus {
  disabled,
  resolvingTarget,
  waitingForBodyThread,
  needsRiskAcceptance,
  needsCalibration,
  calibrating,
  activeNative,
  activeAttached,
  suspended,
  fallback,
}

/// Immutable identity for one visible unsafe-input consent request.
///
/// The dialog must return this exact request when committing. Otherwise a
/// dialog opened for one executable could authorize a different target that
/// became current while the dialog was open.
@immutable
class GalAttachedUnsafeRiskAcceptanceRequest {
  const GalAttachedUnsafeRiskAcceptanceRequest({
    required this.token,
    required this.target,
    required this.exePath,
    required this.exeSha256,
  });

  final int token;
  final GalAttachedSurfaceTarget target;
  final String exePath;
  final String exeSha256;
}

abstract interface class GalAttachedTextSurfacePort {
  Future<GalAttachedCallResult> inspectTarget(
    GalAttachedSurfaceTarget target, {
    String? launchExePath,
  });

  Future<GalAttachedCallResult> calibrationStart({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalLookupReferenceClientV1 referenceClient,
    required GalLookupTextLayoutV1 layout,
    required bool riskAccepted,
  });

  Future<GalAttachedCallResult> calibrationUpdate({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  });

  Future<GalAttachedCallResult> calibrationCommit({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  });

  Future<GalAttachedCallResult> calibrationCancel(
    GalAttachedSurfaceTarget target,
  );

  Future<GalAttachedCallResult> configure({
    required GalAttachedSurfaceTarget target,
    required GalLookupSurfaceVariantV1 variant,
    required GalLookupSurfaceMode mode,
    required bool riskAccepted,
  });

  Future<GalAttachedCallResult> updateText({
    required GalAttachedSurfaceTarget target,
    required String sourceText,
    required int textGeneration,
  });

  Future<GalAttachedCallResult> updateStyle({
    required GalAttachedSurfaceTarget target,
    required GalLookupTextLayoutV1 layout,
  });

  Future<GalAttachedCallResult> suspendForCapture({
    required GalAttachedSurfaceTarget target,
    required int textGeneration,
    required int captureGeneration,
  });

  Future<GalAttachedCallResult> restoreAfterCapture({
    required GalAttachedSurfaceTarget target,
    required int textGeneration,
    required int captureGeneration,
  });

  Future<GalAttachedCallResult> detach(GalAttachedSurfaceTarget target);
}

class GalAttachedMethodChannelSurfacePort
    implements GalAttachedTextSurfacePort {
  const GalAttachedMethodChannelSurfacePort();

  @override
  Future<GalAttachedCallResult> inspectTarget(
    GalAttachedSurfaceTarget target, {
    String? launchExePath,
  }) => GalHookTextOverlayChannel.attachedInspectTarget(
    target,
    launchExePath: launchExePath,
  );

  @override
  Future<GalAttachedCallResult> calibrationStart({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalLookupReferenceClientV1 referenceClient,
    required GalLookupTextLayoutV1 layout,
    required bool riskAccepted,
  }) => GalHookTextOverlayChannel.attachedCalibrationStart(
    target: target,
    bodyRect: bodyRect,
    referenceClient: referenceClient,
    layout: layout,
    riskAccepted: riskAccepted,
  );

  @override
  Future<GalAttachedCallResult> calibrationUpdate({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  }) => GalHookTextOverlayChannel.attachedCalibrationUpdate(
    target: target,
    bodyRect: bodyRect,
    probes: probes,
  );

  @override
  Future<GalAttachedCallResult> calibrationCommit({
    required GalAttachedSurfaceTarget target,
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  }) => GalHookTextOverlayChannel.attachedCalibrationCommit(
    target: target,
    bodyRect: bodyRect,
    probes: probes,
  );

  @override
  Future<GalAttachedCallResult> calibrationCancel(
    GalAttachedSurfaceTarget target,
  ) => GalHookTextOverlayChannel.attachedCalibrationCancel(target);

  @override
  Future<GalAttachedCallResult> configure({
    required GalAttachedSurfaceTarget target,
    required GalLookupSurfaceVariantV1 variant,
    required GalLookupSurfaceMode mode,
    required bool riskAccepted,
  }) => GalHookTextOverlayChannel.attachedConfigure(
    target: target,
    variant: variant,
    mode: mode,
    riskAccepted: riskAccepted,
  );

  @override
  Future<GalAttachedCallResult> updateText({
    required GalAttachedSurfaceTarget target,
    required String sourceText,
    required int textGeneration,
  }) => GalHookTextOverlayChannel.attachedUpdateText(
    target: target,
    sourceText: sourceText,
    textGeneration: textGeneration,
  );

  @override
  Future<GalAttachedCallResult> updateStyle({
    required GalAttachedSurfaceTarget target,
    required GalLookupTextLayoutV1 layout,
  }) => GalHookTextOverlayChannel.attachedUpdateStyle(
    target: target,
    layout: layout,
  );

  @override
  Future<GalAttachedCallResult> suspendForCapture({
    required GalAttachedSurfaceTarget target,
    required int textGeneration,
    required int captureGeneration,
  }) => GalHookTextOverlayChannel.attachedSuspendForCapture(
    target: target,
    textGeneration: textGeneration,
    captureGeneration: captureGeneration,
  );

  @override
  Future<GalAttachedCallResult> restoreAfterCapture({
    required GalAttachedSurfaceTarget target,
    required int textGeneration,
    required int captureGeneration,
  }) => GalHookTextOverlayChannel.attachedRestoreAfterCapture(
    target: target,
    textGeneration: textGeneration,
    captureGeneration: captureGeneration,
  );

  @override
  Future<GalAttachedCallResult> detach(GalAttachedSurfaceTarget target) =>
      GalHookTextOverlayChannel.attachedDetach(target);
}

/// Child state machine fed by the app's existing single gal session listener.
class GalAttachedTextController extends ChangeNotifier {
  GalAttachedTextController({
    required GalAttachedPreferenceReader preferenceReader,
    required GalAttachedPreferenceWriter preferenceWriter,
    GalAttachedTextSurfacePort surfacePort =
        const GalAttachedMethodChannelSurfacePort(),
    GalAttachedLayoutBuilder? layoutBuilder,
    GalAttachedBeforeActivationCallback? onBeforeAttachedActivation,
    GalAttachedLookupCallback? onLookup,
  }) : _preferenceReader = preferenceReader,
       _preferenceWriter = preferenceWriter,
       _surfacePort = surfacePort,
       _layoutBuilder =
           layoutBuilder ??
           ((GalLookupReferenceClientV1 _) => const GalLookupTextLayoutV1()),
       _onBeforeAttachedActivation = onBeforeAttachedActivation,
       _onLookup = onLookup;

  static const GalLookupNormalizedRectV1 defaultBodyRect =
      GalLookupNormalizedRectV1(
        left: 0.08,
        top: 0.68,
        width: 0.84,
        height: 0.24,
      );

  final GalAttachedPreferenceReader _preferenceReader;
  final GalAttachedPreferenceWriter _preferenceWriter;
  final GalAttachedTextSurfacePort _surfacePort;
  final GalAttachedLayoutBuilder _layoutBuilder;
  final GalAttachedBeforeActivationCallback? _onBeforeAttachedActivation;
  final GalAttachedLookupCallback? _onLookup;

  GalAttachedTextStatus _status = GalAttachedTextStatus.disabled;
  String? _statusReason;
  String? _nativeStatus;
  GalAttachedShieldStatus _shieldStatus = const GalAttachedShieldStatus();
  int? _providerKind;
  int? _providerId;
  int? _providerStatus;
  int? _probeStartObservedIndex;
  int? _probeMiddleObservedIndex;
  int? _probeEndObservedIndex;
  bool _surfaceVisible = false;
  GalAttachedSurfaceTarget? _target;
  GalLookupSurfaceProfileV1? _profile;
  GalLookupSurfaceVariantV1? _activeVariant;
  GalLookupReferenceClientV1? _currentClient;
  String? _exePath;
  String? _exeSha256;
  String? _launchExePath;
  String _latestSourceText = '';
  String _sentSourceText = '';
  int _textGeneration = 0;
  int _nextSurfaceEpoch = 0;
  int _nextCaptureGeneration = 0;
  GalAttachedMiningCaptureLease? _activeCaptureLease;
  Future<void>? _captureReleaseFuture;
  int? _captureReleaseGeneration;
  Future<bool>? _textPushFuture;
  GalAttachedSurfaceTarget? _textPushTarget;
  String? _textPushSource;
  bool _textPushStagesProviderPending = false;
  int _textPushOperation = 0;
  int _operationGeneration = 0;
  bool _activationDeferred = false;
  bool _attachedProviderClaimed = false;
  bool _forceAttachedProvider = false;
  int _nextUnsafeRiskAcceptanceRequestToken = 0;
  int? _unsafeRiskAcceptanceRequestToken;
  int? _unsafeRiskAcceptanceCommitToken;
  int _unsafeRiskAcceptanceLifecycleRevision = 0;
  Future<void> _preferenceWriteTail = Future<void>.value();
  int _nextPreferenceWriteSequence = 0;
  final Map<String, int> _latestPreferenceWriteSequence = <String, int>{};
  final Set<int> _retiredTargetHwnds = <int>{};
  GalLookupNormalizedRectV1? _draftBodyRect;
  GalLookupTextLayoutV1? _draftLayout;
  int _calibrationProbeMask = 0;

  GalAttachedTextStatus get status => _status;
  String? get statusReason => _statusReason;
  String? get nativeStatus => _nativeStatus;
  GalAttachedShieldStatus get shieldStatus => _shieldStatus;
  int? get providerKind => _providerKind;
  int? get providerId => _providerId;
  int? get providerStatus => _providerStatus;
  int? get probeStartObservedIndex => _probeStartObservedIndex;
  int? get probeMiddleObservedIndex => _probeMiddleObservedIndex;
  int? get probeEndObservedIndex => _probeEndObservedIndex;
  bool get surfaceVisible => _surfaceVisible;
  GalAttachedSurfaceTarget? get target => _target;
  GalLookupSurfaceProfileV1? get profile => _profile;
  GalLookupSurfaceVariantV1? get activeVariant => _activeVariant;
  GalLookupReferenceClientV1? get currentClient => _currentClient;
  String? get executablePath => _exePath;
  String? get executableSha256 => _exeSha256;
  String get latestSourceText => _latestSourceText;
  int get textGeneration => _textGeneration;
  int get calibrationProbeMask => _calibrationProbeMask;
  bool get attachedProviderClaimed => _attachedProviderClaimed;
  bool get forceAttachedProvider => _forceAttachedProvider;
  GalLookupNormalizedRectV1? get draftBodyRect => _draftBodyRect;
  GalLookupTextLayoutV1? get draftLayout => _draftLayout;
  bool get canCalibrate =>
      _target != null &&
      _currentClient != null &&
      _exePath != null &&
      _exeSha256 != null &&
      _latestSourceText.isNotEmpty;
  bool get isReady =>
      _status == GalAttachedTextStatus.activeAttached ||
      _status == GalAttachedTextStatus.activeNative;
  bool get isUnsafeInputActive =>
      (_status == GalAttachedTextStatus.activeAttached ||
          _status == GalAttachedTextStatus.activeNative) &&
      (_profile?.mode ?? GalLookupSurfaceMode.auto) !=
          GalLookupSurfaceMode.off &&
      _shieldStatus.conclusion != GalAttachedShieldConclusion.verified &&
      (_profile?.unsafeLeftClickAccepted ?? false);
  bool get needsUnsafeRiskAcceptance =>
      _unsafeRiskAcceptanceRequestToken != null &&
      (_status == GalAttachedTextStatus.needsRiskAcceptance ||
          _status == GalAttachedTextStatus.suspended) &&
      _target != null &&
      _exePath != null &&
      _exeSha256 != null &&
      (_profile?.mode ?? GalLookupSurfaceMode.auto) !=
          GalLookupSurfaceMode.off &&
      !(_profile?.unsafeLeftClickAccepted ?? false) &&
      _shieldStatus.conclusion != GalAttachedShieldConclusion.verified &&
      _shieldStatus.conclusion != GalAttachedShieldConclusion.faulted;
  GalAttachedUnsafeRiskAcceptanceRequest? get unsafeRiskAcceptanceRequest {
    final int? token = _unsafeRiskAcceptanceRequestToken;
    final GalAttachedSurfaceTarget? target = _target;
    final String? exePath = _exePath;
    final String? exeSha256 = _exeSha256;
    if (_unsafeRiskAcceptanceCommitToken != null ||
        !needsUnsafeRiskAcceptance ||
        token == null ||
        target == null ||
        exePath == null ||
        exeSha256 == null) {
      return null;
    }
    return GalAttachedUnsafeRiskAcceptanceRequest(
      token: token,
      target: target,
      exePath: exePath,
      exeSha256: exeSha256,
    );
  }

  Future<void> syncSession({
    required bool active,
    required int? sessionEpoch,
    required int targetPid,
    required int targetHwnd,
    String? sourceText,
    String? launchExePath,
    bool inspectOnly = false,
    bool Function()? stillCurrent,
  }) async {
    if (stillCurrent != null && !stillCurrent()) return;
    final bool hasTarget =
        active &&
        sessionEpoch != null &&
        sessionEpoch > 0 &&
        targetPid > 0 &&
        targetHwnd != 0;
    if (!hasTarget) {
      await detach();
      return;
    }
    final String nextText = sourceText ?? '';
    final String? nextLaunchExePath = switch (launchExePath?.trim()) {
      final String value when value.isNotEmpty => value,
      _ => null,
    };
    final GalAttachedSurfaceTarget? current = _target;
    final bool changed =
        current == null ||
        current.sessionEpoch != sessionEpoch ||
        current.targetPid != targetPid ||
        _launchExePath != nextLaunchExePath ||
        (current.targetHwnd != targetHwnd &&
            !_retiredTargetHwnds.contains(targetHwnd));
    if (changed) {
      await _attachTarget(
        sessionEpoch: sessionEpoch,
        targetPid: targetPid,
        targetHwnd: targetHwnd,
        sourceText: nextText,
        launchExePath: nextLaunchExePath,
        inspectOnly: inspectOnly,
        stillCurrent: stillCurrent,
      );
      return;
    }
    _latestSourceText = nextText;
    if (_activationDeferred) {
      if (inspectOnly) return;
      _activationDeferred = false;
      await _evaluateAndActivate(
        ++_operationGeneration,
        current,
        stillCurrent: stillCurrent,
      );
      return;
    }
    // BUG-2095：`waitingForBodyThread` 的恢复原本只挂在「正文从无到有」这一个边沿上。
    // 但该状态还有第二个来源——子面在正文真正落地前回 `noGlyphClusters`，那时
    // `_latestSourceText` 早已非空，`bodyArrived` 这个边沿**再也不会出现**，于是状态
    // 永久停在「等正文」，尽管正文每一行都在到。判据改成「还在等正文 && 手上确实有
    // 正文」：`bodyArrived` 是它的真子集，只放宽恢复时机，不放宽任何准入。
    if (nextText.isNotEmpty &&
        _status == GalAttachedTextStatus.waitingForBodyThread) {
      if (inspectOnly) {
        _activationDeferred = true;
        return;
      }
      await _evaluateAndActivate(
        ++_operationGeneration,
        current,
        stillCurrent: stillCurrent,
      );
      return;
    }
    if (nextText.isEmpty && _status == GalAttachedTextStatus.activeAttached) {
      await _pushText('');
      _setStatus(
        GalAttachedTextStatus.waitingForBodyThread,
        reason: 'target_detached_waiting_body_thread',
      );
      return;
    }
    await _pushLatestTextIfActive();
  }

  Future<void> _attachTarget({
    required int sessionEpoch,
    required int targetPid,
    required int targetHwnd,
    required String sourceText,
    required String? launchExePath,
    required bool inspectOnly,
    bool Function()? stillCurrent,
  }) async {
    await detach();
    if (stillCurrent != null && !stillCurrent()) return;
    _latestSourceText = sourceText;
    _launchExePath = launchExePath;
    final int operation = ++_operationGeneration;
    final GalAttachedSurfaceTarget target = GalAttachedSurfaceTarget(
      sessionEpoch: sessionEpoch,
      surfaceEpoch: ++_nextSurfaceEpoch,
      targetPid: targetPid,
      targetHwnd: targetHwnd,
    );
    _target = target;
    _setStatus(GalAttachedTextStatus.resolvingTarget);
    final GalAttachedCallResult inspection = await _surfacePort.inspectTarget(
      target,
      launchExePath: launchExePath,
    );
    if (!_isCurrent(operation, target) ||
        (stillCurrent != null && !stillCurrent())) {
      return;
    }
    _adoptNativeMetadata(inspection);
    final String exePath = inspection.exePath ?? '';
    final String exeSha256 = inspection.exeSha256 ?? '';
    final GalLookupReferenceClientV1? client = inspection.referenceClient;
    if (!inspection.ok ||
        exePath.trim().isEmpty ||
        !GalLookupSurfaceProfileV1.isValidSha256(exeSha256) ||
        client == null) {
      _activationFailure(inspection.error ?? 'invalid_target_inspection');
      return;
    }
    _exePath = GalLookupSurfaceProfileV1.normalizeExePath(exePath);
    _exeSha256 = GalLookupSurfaceProfileV1.normalizeSha256(exeSha256);
    _currentClient = client;
    _loadProfile();
    if (inspectOnly) {
      _activationDeferred = true;
      return;
    }
    await _evaluateAndActivate(operation, target, stillCurrent: stillCurrent);
  }

  /// 读回磁盘上这个 exe 的 profile；解析失败 / 路径不符一律当没有。
  ///
  /// `acceptUnsafeRiskAndRetry` 用它当底稿，避免用新建的空壳覆盖可解析的存量校准。
  GalLookupSurfaceProfileV1? _readPersistedProfile(
    String preferenceKey,
    String exePath,
  ) {
    final Object? stored = _preferenceReader(preferenceKey);
    if (stored == null || stored == '') return null;
    try {
      final Object? decoded = stored is String ? jsonDecode(stored) : stored;
      final GalLookupSurfaceProfileV1? loaded =
          GalLookupSurfaceProfileV1.tryFromJson(decoded);
      if (loaded == null ||
          GalLookupSurfaceProfileV1.normalizeExePath(loaded.exePath) !=
              exePath) {
        return null;
      }
      return loaded;
    } catch (_) {
      return null;
    }
  }

  void _loadProfile() {
    _profile = null;
    final String? exePath = _exePath;
    final String? exeSha256 = _exeSha256;
    if (exePath == null || exeSha256 == null) return;
    final Object? stored = _preferenceReader(
      GalLookupSurfaceProfileV1.preferenceKeyForExePath(exePath),
    );
    if (stored == null || stored == '') return;
    try {
      final Object? decoded = stored is String ? jsonDecode(stored) : stored;
      final GalLookupSurfaceProfileV1? loaded =
          GalLookupSurfaceProfileV1.tryFromJson(decoded);
      if (loaded == null ||
          GalLookupSurfaceProfileV1.normalizeExePath(loaded.exePath) !=
              exePath) {
        return;
      }
      // An updated executable keeps all calibration variants as seeds, but raw
      // left-click authorization is revoked until the user confirms again.
      _profile =
          GalLookupSurfaceProfileV1.normalizeSha256(loaded.exeSha256) ==
              exeSha256
          ? loaded
          : loaded.copyWith(
              exeSha256: exeSha256,
              unsafeLeftClickAccepted: false,
            );
    } catch (_) {
      _profile = null;
    }
  }

  Future<void> _evaluateAndActivate(
    int operation,
    GalAttachedSurfaceTarget target, {
    bool Function()? stillCurrent,
  }) async {
    if (stillCurrent != null && !stillCurrent()) return;
    final GalAttachedSurfaceTarget? callTarget = _target;
    if (callTarget == null || !_sameLogicalSurface(callTarget, target)) return;
    final GalLookupSurfaceProfileV1? profile = _profile;
    final GalLookupSurfaceMode mode =
        profile?.mode ?? GalLookupSurfaceMode.auto;
    final GalLookupReferenceClientV1? client = _currentClient;
    if (client == null) {
      _setAttachedProviderClaim(false);
      _setStatus(
        GalAttachedTextStatus.needsCalibration,
        reason: 'profile_load_failed',
      );
      return;
    }
    if (mode == GalLookupSurfaceMode.off) {
      _setAttachedProviderClaim(false);
      _setStatus(GalAttachedTextStatus.disabled);
      return;
    }
    if (_shieldStatus.conclusion == GalAttachedShieldConclusion.faulted) {
      _activationFailure('input_shield_faulted');
      return;
    }
    if (_nativeProviderReady(
      mode: mode,
      providerKind: _providerKind,
      providerId: _providerId,
      providerStatus: _providerStatus,
    )) {
      _activateNativeOrRequestRisk();
      return;
    }
    if (_nativeProviderPending(mode, _nativeStatus)) {
      _activeVariant = null;
      _surfaceVisible = false;
      _setStatus(
        GalAttachedTextStatus.suspended,
        reason: 'nativeProviderPendingNeutral',
      );
      return;
    }
    if (mode == GalLookupSurfaceMode.nativeOnly) {
      _setAttachedProviderClaim(false);
      _activeVariant = null;
      _surfaceVisible = false;
      _setStatus(
        GalAttachedTextStatus.suspended,
        reason: 'evaluate_native_only_provider_unavailable',
      );
      return;
    }
    if (_latestSourceText.isEmpty) {
      if (_sentSourceText.isEmpty) _setAttachedProviderClaim(false);
      _activeVariant = profile?.bestVariantForClient(client);
      _setStatus(
        GalAttachedTextStatus.waitingForBodyThread,
        reason: 'evaluate_no_source_text',
      );
      return;
    }
    if (profile == null) {
      _setAttachedProviderClaim(false);
      _setStatus(
        GalAttachedTextStatus.needsCalibration,
        reason: 'evaluate_profile_missing',
      );
      return;
    }
    final bool riskAccepted = profile.unsafeLeftClickAccepted;
    if (!riskAccepted &&
        _shieldStatus.conclusion != GalAttachedShieldConclusion.verified) {
      _setAttachedProviderClaim(false);
      _setStatus(
        GalAttachedTextStatus.needsRiskAcceptance,
        reason: 'evaluate_profile_risk_not_accepted',
      );
      return;
    }
    final GalLookupSurfaceVariantV1? variant = profile.bestVariantForClient(
      client,
    );
    if (variant == null) {
      _setAttachedProviderClaim(false);
      _setStatus(
        GalAttachedTextStatus.needsCalibration,
        reason: 'evaluate_no_variant_for_client',
      );
      return;
    }
    if (!await _claimAttachedProvider(
      operation,
      callTarget,
      profileMode: mode,
      stillCurrent: stillCurrent,
    )) {
      return;
    }
    final GalAttachedCallResult result = await _surfacePort.configure(
      target: callTarget,
      variant: variant,
      mode: mode,
      riskAccepted: riskAccepted,
    );
    if (!_isCurrent(operation, callTarget) ||
        (stillCurrent != null && !stillCurrent())) {
      return;
    }
    _adoptNativeMetadata(result);
    if (result.shield.conclusion == GalAttachedShieldConclusion.faulted) {
      _activationFailure('input_shield_faulted');
      return;
    }
    if (!result.ok || result.status == 'riskAcceptanceRequired') {
      if (result.status == 'riskAcceptanceRequired') {
        _setStatus(
          GalAttachedTextStatus.needsRiskAcceptance,
          reason: result.reason ?? 'configure_risk_acceptance_required',
        );
      } else {
        _activationFailure(result.reason ?? result.error);
      }
      return;
    }
    if (_nativeProviderReady(
      mode: mode,
      providerKind: result.providerKind,
      providerId: result.providerId,
      providerStatus: result.providerStatus,
    )) {
      if (!_nativeRiskGateSatisfied) {
        _activeVariant = null;
        _surfaceVisible = false;
        _setStatus(
          GalAttachedTextStatus.needsRiskAcceptance,
          reason: 'native_provider_risk_gate_unsatisfied',
        );
        return;
      }
      _activeVariant = null;
      _surfaceVisible = false;
      _setStatus(GalAttachedTextStatus.activeNative);
      return;
    }
    if (_nativeProviderPending(mode, result.status)) {
      _activeVariant = null;
      _surfaceVisible = false;
      _setStatus(
        GalAttachedTextStatus.suspended,
        reason: 'nativeProviderPendingNeutral',
      );
      return;
    }
    if (result.status == 'geometryProviderPending') {
      _activeVariant = variant;
      _nativeStatus = result.status;
      _surfaceVisible = false;
      _setStatus(
        GalAttachedTextStatus.suspended,
        reason: 'geometryProviderPending',
      );
      // Store the text while the injected registry drains the previous
      // down/up/tail. Once kind=4/id=11 becomes active the native health event
      // can build clusters immediately; waiting for activeAttached here would
      // deadlock on an emptyText state.
      if (_latestSourceText.isNotEmpty &&
          _sentSourceText != _latestSourceText) {
        await _pushText(_latestSourceText, stageWhileProviderPending: true);
      }
      return;
    }
    if (!_attachedRegistryProviderReady(
      result.providerKind,
      result.providerId,
      result.providerStatus,
    )) {
      // A successful MethodChannel reply is not an ownership lease.  Only the
      // registry's authoritative attached pair may make this controller route
      // lookups through the transparent surface.
      _activeVariant = variant;
      _surfaceVisible = false;
      _setStatus(
        GalAttachedTextStatus.suspended,
        reason: 'geometryProviderPending',
      );
      if (_latestSourceText.isNotEmpty &&
          _sentSourceText != _latestSourceText) {
        await _pushText(_latestSourceText, stageWhileProviderPending: true);
      }
      return;
    }
    _activeVariant = variant;
    _nativeStatus = result.status;
    _surfaceVisible = result.surfaceVisible;
    _setStatus(GalAttachedTextStatus.activeAttached);
    await _pushLatestTextIfActive();
  }

  /// [withdrawClaim] = false 用于「本轮渲染不出内容，但 attached 通路本身没坏」的
  /// 情形。`_attachedProviderClaimed` 是**跨轮次共享**、发布给注入侧 registry 的单一
  /// 状态，撤回它等于告诉 registry「attached 永远不 ready」，而宿主又在等 registry 把
  /// kind=4/id=11 判成 ready —— 两边互等成活锁（BUG-2091 / BUG-2094）。
  void _activationFailure(String? reason, {bool withdrawClaim = true}) {
    final GalLookupSurfaceMode mode =
        _profile?.mode ?? GalLookupSurfaceMode.auto;
    if (withdrawClaim) _setAttachedProviderClaim(false);
    _surfaceVisible = false;
    _setStatus(
      mode == GalLookupSurfaceMode.auto
          ? GalAttachedTextStatus.fallback
          : GalAttachedTextStatus.suspended,
      reason: reason ?? 'attached_surface_failed',
    );
  }

  Future<bool> beginCalibration({
    GalLookupNormalizedRectV1? initialBodyRect,
    required bool acceptUnsafeLeftClick,
  }) async {
    final GalAttachedSurfaceTarget? target = _target;
    final GalLookupReferenceClientV1? client = _currentClient;
    if (target == null || client == null || _latestSourceText.isEmpty) {
      return false;
    }
    if (!acceptUnsafeLeftClick) {
      _setStatus(
        GalAttachedTextStatus.needsRiskAcceptance,
        reason: 'calibration_risk_not_accepted',
      );
      return false;
    }
    final GalLookupSurfaceVariantV1? seed = _profile?.nearestVariantForClient(
      client,
    );
    final GalLookupNormalizedRectV1 rect =
        initialBodyRect ?? seed?.bodyRect ?? defaultBodyRect;
    final GalLookupTextLayoutV1 layout = seed?.layout ?? _layoutBuilder(client);
    if (!rect.isValid || !layout.isValid) return false;
    final int calibrationOperation = ++_operationGeneration;
    ++_unsafeRiskAcceptanceLifecycleRevision;
    _unsafeRiskAcceptanceRequestToken = null;
    _unsafeRiskAcceptanceCommitToken = null;
    _setStatus(GalAttachedTextStatus.calibrating);
    _draftBodyRect = rect;
    _draftLayout = layout;
    _calibrationProbeMask = 0;
    _probeStartObservedIndex = null;
    _probeMiddleObservedIndex = null;
    _probeEndObservedIndex = null;
    if (!await _claimAttachedProvider(
      calibrationOperation,
      target,
      profileMode: _profile?.mode ?? GalLookupSurfaceMode.auto,
      forceAttached: true,
    )) {
      return false;
    }
    final GalAttachedCallResult result = await _surfacePort.calibrationStart(
      target: target,
      bodyRect: rect,
      referenceClient: client,
      layout: layout,
      riskAccepted: true,
    );
    if (!_isCurrent(calibrationOperation, target)) return false;
    _adoptNativeMetadata(result);
    if (!result.ok) {
      _activationFailure(result.reason ?? result.error);
      return false;
    }
    if (_sentSourceText != _latestSourceText) {
      await _pushText(_latestSourceText);
    }
    return _isCurrent(calibrationOperation, target) &&
        _status == GalAttachedTextStatus.calibrating;
  }

  Future<bool> updateCalibration({
    required GalLookupNormalizedRectV1 bodyRect,
    required GalAttachedCalibrationProbes probes,
  }) async {
    final GalAttachedSurfaceTarget? target = _target;
    if (target == null ||
        _status != GalAttachedTextStatus.calibrating ||
        !bodyRect.isValid ||
        !probes.hasValidIndicesForSourceLength(_latestSourceText.length)) {
      return false;
    }
    final GalAttachedCalibrationProbes observedProbes =
        _onlyObservedConfirmations(probes);
    final GalAttachedCallResult result = await _surfacePort.calibrationUpdate(
      target: target,
      bodyRect: bodyRect,
      probes: observedProbes,
    );
    if (!_isCurrentSurface(target) || !result.ok) return false;
    _adoptNativeMetadata(result);
    _draftBodyRect = bodyRect;
    _calibrationProbeMask = result.calibrationProbeMask & 7;
    notifyListeners();
    return true;
  }

  /// Applies a DirectWrite draft style while calibration is active. The
  /// visible preview remains in the workbench; the attached surface only
  /// updates its invisible hit layout and calibration bounds.
  Future<bool> updateCalibrationStyle(GalLookupTextLayoutV1 layout) async {
    final GalAttachedSurfaceTarget? target = _target;
    if (target == null ||
        _status != GalAttachedTextStatus.calibrating ||
        !layout.isValid) {
      return false;
    }
    final GalAttachedCallResult result = await _surfacePort.updateStyle(
      target: target,
      layout: layout,
    );
    if (!_isCurrentSurface(target) || !result.ok) return false;
    _adoptNativeMetadata(result);
    _draftLayout = result.layout ?? layout;
    notifyListeners();
    return true;
  }

  Future<bool> commitCalibration({
    required GalAttachedCalibrationProbes probes,
  }) async {
    final GalAttachedSurfaceTarget? target = _target;
    final GalLookupNormalizedRectV1? bodyRect = _draftBodyRect;
    if (target == null ||
        bodyRect == null ||
        _status != GalAttachedTextStatus.calibrating ||
        !probes.isCommitReadyForSourceLength(_latestSourceText.length) ||
        !_allProbeIndicesObserved(probes)) {
      return false;
    }
    final GalAttachedCallResult result = await _surfacePort.calibrationCommit(
      target: target,
      bodyRect: bodyRect,
      probes: probes,
    );
    if (!_isCurrentSurface(target) || !result.ok) return false;
    _adoptNativeMetadata(result);
    _calibrationProbeMask = result.calibrationProbeMask & 7;
    notifyListeners();
    if (result.bodyRect != null &&
        result.referenceClient != null &&
        result.calibrationProbeMask == 7) {
      await handleCalibrationCommitted(
        GalAttachedCalibrationEvent(
          target: target,
          bodyRect: result.bodyRect!,
          referenceClient: result.referenceClient!,
          layout: result.layout,
          riskAccepted: true,
          calibrationProbeMask: result.calibrationProbeMask,
        ),
      );
    }
    return true;
  }

  Future<void> cancelCalibration() async {
    final GalAttachedSurfaceTarget? target = _target;
    if (target == null) return;
    final GalAttachedCallResult result = await _surfacePort.calibrationCancel(
      target,
    );
    if (!_isCurrentSurface(target)) return;
    _adoptNativeMetadata(result);
    _clearDraft();
    _setAttachedProviderClaim(_attachedProviderClaimed, forceAttached: false);
    if (!result.ok) {
      _activationFailure(result.reason ?? result.error);
      return;
    }
    await _evaluateAndActivate(++_operationGeneration, target);
  }

  Future<void> handleCalibrationCommitted(
    GalAttachedCalibrationEvent event,
  ) async {
    if (!_adoptLifecycleTarget(event.target) ||
        !event.riskAccepted ||
        event.calibrationProbeMask != 7) {
      return;
    }
    final String? exePath = _exePath;
    final String? exeSha256 = _exeSha256;
    if (exePath == null || exeSha256 == null) return;
    final GalLookupSurfaceVariantV1 variant = GalLookupSurfaceVariantV1(
      aspectRatio: event.referenceClient.aspectRatio,
      referenceClient: event.referenceClient,
      bodyRect: event.bodyRect,
      layout: event.layout ?? _draftLayout ?? const GalLookupTextLayoutV1(),
    );
    if (!variant.isValid) return;
    final GalLookupSurfaceProfileV1? previous = _profile;
    final List<GalLookupSurfaceVariantV1> variants =
        List<GalLookupSurfaceVariantV1>.of(previous?.variants ?? const []);
    int replacement = -1;
    double bestError = double.infinity;
    for (int i = 0; i < variants.length; i++) {
      final double error = variants[i].relativeAspectError(variant.aspectRatio);
      if (error <= GalLookupSurfaceProfileV1.maxRelativeAspectError &&
          error < bestError) {
        replacement = i;
        bestError = error;
      }
    }
    if (replacement < 0) {
      variants.add(variant);
    } else {
      variants[replacement] = variant;
    }
    final GalLookupSurfaceProfileV1 committed = GalLookupSurfaceProfileV1(
      exePath: exePath,
      exeSha256: exeSha256,
      mode: previous?.mode ?? GalLookupSurfaceMode.auto,
      unsafeLeftClickAccepted: true,
      variants: List<GalLookupSurfaceVariantV1>.unmodifiable(variants),
    );
    _profile = committed;
    _currentClient = event.referenceClient;
    _clearDraft();
    _setAttachedProviderClaim(true, forceAttached: false);
    await _persistProfile(committed);
    await _evaluateAndActivate(++_operationGeneration, event.target);
  }

  Future<void> handleCalibrationCancelled(
    GalAttachedCalibrationCancelledEvent event,
  ) async {
    if (!_adoptLifecycleTarget(event.target)) return;
    _clearDraft();
    _setAttachedProviderClaim(_attachedProviderClaimed, forceAttached: false);
    await _evaluateAndActivate(++_operationGeneration, event.target);
  }

  void handleSurfaceStateChanged(GalAttachedSurfaceStateEvent event) {
    if (!_adoptLifecycleTarget(event.target)) return;
    _nativeStatus = event.status;
    _shieldStatus = event.shield;
    _providerKind = event.providerKind;
    _providerId = event.providerId;
    _providerStatus = event.providerStatus;
    _probeStartObservedIndex = event.probeStartObservedIndex;
    _probeMiddleObservedIndex = event.probeMiddleObservedIndex;
    _probeEndObservedIndex = event.probeEndObservedIndex;
    _surfaceVisible = _activeCaptureLease == null && event.surfaceVisible;
    _calibrationProbeMask = event.calibrationProbeMask & 7;
    if (event.referenceClient != null) _currentClient = event.referenceClient;
    if (_status == GalAttachedTextStatus.calibrating) {
      if (event.bodyRect != null) _draftBodyRect = event.bodyRect;
      if (event.layout != null) _draftLayout = event.layout;
    }
    final GalLookupSurfaceMode mode =
        _profile?.mode ?? GalLookupSurfaceMode.auto;
    if (_shieldStatus.conclusion == GalAttachedShieldConclusion.faulted) {
      _activationFailure(event.reason ?? 'input_shield_faulted');
      notifyListeners();
      return;
    }
    if (_nativeProviderReady(
      mode: mode,
      providerKind: event.providerKind,
      providerId: event.providerId,
      providerStatus: event.providerStatus,
    )) {
      _activateNativeOrRequestRisk(reason: event.reason);
      notifyListeners();
      return;
    }
    if (_nativeProviderPending(mode, event.status)) {
      _activeVariant = null;
      _surfaceVisible = false;
      _setStatus(GalAttachedTextStatus.suspended, reason: event.status);
      notifyListeners();
      return;
    }
    if (event.status == 'geometryProviderPending') {
      _surfaceVisible = false;
      _setStatus(
        _forceAttachedProvider
            ? GalAttachedTextStatus.calibrating
            : GalAttachedTextStatus.suspended,
        reason: 'geometryProviderPending',
      );
      notifyListeners();
      return;
    }
    switch (event.status) {
      case 'riskAcceptanceRequired':
        _setStatus(
          GalAttachedTextStatus.needsRiskAcceptance,
          reason: event.reason,
        );
        break;
      case 'calibrating':
        _setStatus(GalAttachedTextStatus.calibrating, reason: event.reason);
        break;
      case 'ready':
      case 'visible':
      case 'visibleRisky':
        if (mode == GalLookupSurfaceMode.nativeOnly) {
          _surfaceVisible = false;
          _setStatus(
            GalAttachedTextStatus.suspended,
            reason: 'state_event_native_only_provider_unavailable',
          );
          break;
        }
        if (!_attachedProviderClaimed ||
            !_attachedRegistryProviderReady(
              event.providerKind,
              event.providerId,
              event.providerStatus,
            )) {
          _surfaceVisible = false;
          _setStatus(
            GalAttachedTextStatus.suspended,
            reason: 'geometryProviderPending',
          );
          if (!_attachedProviderClaimed) {
            // An auto-mode native provider can retire without an attached
            // Configure call having run.  Re-enter arbitration so the host
            // claims kind=4/id=11, instead of waiting forever for an event the
            // unconfigured surface cannot produce.
            unawaited(
              _evaluateAndActivate(++_operationGeneration, event.target),
            );
          }
          break;
        }
        final GalLookupSurfaceProfileV1? profile = _profile;
        final GalLookupReferenceClientV1? client = _currentClient;
        if (profile == null || client == null) {
          _surfaceVisible = false;
          _setStatus(
            GalAttachedTextStatus.needsCalibration,
            reason: 'state_event_profile_missing',
          );
          break;
        }
        final GalLookupSurfaceVariantV1? variant = profile.bestVariantForClient(
          client,
        );
        if (variant == null) {
          _surfaceVisible = false;
          _setStatus(
            GalAttachedTextStatus.needsCalibration,
            reason: 'state_event_no_variant_for_client',
          );
          break;
        }
        if (!profile.unsafeLeftClickAccepted &&
            _shieldStatus.conclusion != GalAttachedShieldConclusion.verified) {
          _surfaceVisible = false;
          _setStatus(
            GalAttachedTextStatus.needsRiskAcceptance,
            reason: 'state_event_risk_not_accepted',
          );
          break;
        }
        if (_latestSourceText.isEmpty) {
          _surfaceVisible = false;
          _activeVariant = variant;
          _setStatus(
            GalAttachedTextStatus.waitingForBodyThread,
            reason: 'state_event_no_source_text',
          );
          break;
        }
        _activeVariant = variant;
        _setStatus(GalAttachedTextStatus.activeAttached, reason: event.reason);
        unawaited(_pushLatestTextIfActive());
        break;
      case 'noGlyphClusters':
        // BUG-2094：建不出字形簇要 fail-closed 地藏面（下面照旧不可见、状态照旧
        // fallback/suspended），但**不得**撤回 `_attachedProviderClaimed`。那是跨轮次
        // 共享、发布给注入侧 registry 的单一状态；撤掉之后 registry 永远不把
        // kind=4/id=11 判成 ready，而宿主又在等这个 ready 才肯进 activeAttached ——
        // 两边互等成活锁，此后**每一行**都救不回来。与 BUG-2091 是同一个活锁，只是
        // 换了这道门进来：真机 WoH 上稳定复现为「认领 8ms 后被 noGlyphClusters 撤回，
        // 随后永久停在 suspended/geometryProviderPending」。
        // 认领的释放仍由当前轮次的 detach / 真失败分支负责。
        if (_sentSourceText.isEmpty) {
          // 还一个字都没推给子面时「建不出簇」是**必然**，不是失败。若在这里降级成
          // `fallback`，状态就再也回不来了：`syncSession` 只在 `waitingForBodyThread`
          // 上因新正文触发重新评估，`_pushLatestTextIfActive` 又只在激活态推送——
          // 于是后面每一行都停在 fallback/noGlyphClusters。真机 WoH 实测正是如此。
          _surfaceVisible = false;
          _setStatus(
            GalAttachedTextStatus.waitingForBodyThread,
            reason: 'state_event_no_glyph_clusters_before_text',
          );
          if (_latestSourceText.isNotEmpty) {
            unawaited(
              _pushText(_latestSourceText, stageWhileProviderPending: true),
            );
          }
          break;
        }
        if (_status == GalAttachedTextStatus.suspended &&
            _statusReason == 'geometryProviderPending') {
          // registry 交接还没完成时，正文只是被 staged（`stageWhileProviderPending`），
          // 子面本来就还没渲染——这条 `noGlyphClusters` 是**预期**而不是失败。旧实现
          // 在这里降级成 `fallback` 并 `HideSurface`，交接于是永远完不成，后面每一行
          // 都停在 fallback/noGlyphClusters。保持 suspended/geometryProviderPending，
          // 等注入侧把 kind=4/id=11 判成 ready 再往下走。
          _surfaceVisible = false;
          break;
        }
        _activationFailure(event.reason ?? event.status, withdrawClaim: false);
        break;
      case 'emptyText':
        _setStatus(
          GalAttachedTextStatus.waitingForBodyThread,
          reason: event.reason,
        );
        break;
      case 'targetUnavailable':
      case 'surfaceUnavailable':
      case 'invalidConfiguration':
      case 'exclusiveFullscreenUnavailable':
        _activationFailure(event.reason);
        break;
      case 'captureSuppressed':
      case 'targetMinimized':
      case 'targetBackground':
      case 'hitSnapshotUnavailable':
        _surfaceVisible = false;
        _setStatus(
          GalAttachedTextStatus.suspended,
          reason: _stateEventReason(event),
        );
        break;
      case 'detached':
        _setStatus(
          GalAttachedTextStatus.suspended,
          reason: _stateEventReason(event),
        );
        break;
      default:
        if (event.state == 'error' || event.state == 'unavailable') {
          _activationFailure(_stateEventReason(event));
        } else if (event.state == 'suspended') {
          _surfaceVisible = false;
          _setStatus(
            GalAttachedTextStatus.suspended,
            reason: _stateEventReason(event),
          );
        } else {
          notifyListeners();
        }
        break;
    }
    // State tokens often stay `calibrating` while the native drag rectangle
    // or style changes. Notify even when [_setStatus] sees no enum change so
    // the workbench adopts the newest native draft before commit.
    notifyListeners();
  }

  /// 状态事件必须留下**可读的**原因（BUG-2092）。
  ///
  /// 运行器对 `targetBackground` / `hitSnapshotUnavailable` 这一族状态并不总是填
  /// `reason`，而这些分支过去把它原样转发，于是宿主侧出现「status=suspended、
  /// reason=null」——真机上这正是 attached 兜底停住却查不出是哪条分支的原因：
  /// 状态名本身（`status`）明明带着答案，却被丢掉了。空原因一律回落到状态名。
  static String? _stateEventReason(GalAttachedSurfaceStateEvent event) {
    final String? reason = event.reason;
    if (reason != null && reason.trim().isNotEmpty) return reason;
    final String status = event.status.trim();
    return status.isEmpty ? null : status;
  }

  Future<void> handleLookupText(GalAttachedLookupHitV19 hit) async {
    if (!_matches(hit.target) ||
        _status != GalAttachedTextStatus.activeAttached ||
        !hit.hasConsistentSourceLength ||
        hit.textGeneration != _textGeneration ||
        hit.sourceText != _sentSourceText) {
      return;
    }
    await _onLookup?.call(hit);
  }

  Future<bool> acceptUnsafeRiskAndRetry(
    GalAttachedUnsafeRiskAcceptanceRequest request,
  ) async {
    if (_unsafeRiskAcceptanceCommitToken != null ||
        !_matchesUnsafeRiskAcceptanceRequest(request)) {
      return false;
    }
    final GalAttachedSurfaceTarget? target = _target;
    final String? exePath = _exePath;
    final String? exeSha256 = _exeSha256;
    if (target == null || exePath == null || exeSha256 == null) return false;
    final String preferenceKey =
        GalLookupSurfaceProfileV1.preferenceKeyForExePath(exePath);
    // 加固（非已复现 bug）：`_profile` 为 null 时旧实现直接新建一份 `variants: []` 的
    // profile 落盘。正常路径下 `_loadProfile()` 已经把磁盘那份读进来了，所以 null 通常
    // 意味着磁盘本来就空；但只要磁盘上存在一份**能解析**的 profile，就不该被这里新建的
    // 空壳覆盖。先读盘当底稿，读不到才新建。（本轮真机上看到的 `variants: []` 已查明是
    // 集成测试宿主每个 RunId 换一个隔离根导致的，与本分支无关，故不记 bug。）
    final GalLookupSurfaceProfileV1 profile =
        _profile ??
        _readPersistedProfile(preferenceKey, exePath) ??
        GalLookupSurfaceProfileV1(
          exePath: exePath,
          exeSha256: exeSha256,
          mode: GalLookupSurfaceMode.auto,
          unsafeLeftClickAccepted: false,
          variants: const <GalLookupSurfaceVariantV1>[],
        );
    final GalLookupSurfaceProfileV1 accepted = profile.copyWith(
      exeSha256: exeSha256,
      unsafeLeftClickAccepted: true,
    );
    final Object? previousPreferenceValue = _preferenceReader(preferenceKey);
    _unsafeRiskAcceptanceCommitToken = request.token;
    final int acceptanceRevision = ++_unsafeRiskAcceptanceLifecycleRevision;
    notifyListeners();
    final Future<void> persistence = _persistProfile(accepted);
    final int acceptanceWriteSequence =
        _latestPreferenceWriteSequence[preferenceKey]!;
    try {
      await persistence;
    } catch (_) {
      if (_latestPreferenceWriteSequence[preferenceKey] ==
          acceptanceWriteSequence) {
        try {
          // PreferencesRepository updates its cache before awaiting the DB.
          // Restore the previous value even when that compensating DB write
          // also fails, so a same-process reattach cannot observe consent
          // that never became durable.
          await _writePreference(preferenceKey, previousPreferenceValue ?? '');
        } catch (_) {}
      }
      if (_unsafeRiskAcceptanceCommitToken == request.token) {
        _unsafeRiskAcceptanceCommitToken = null;
        ++_unsafeRiskAcceptanceLifecycleRevision;
        notifyListeners();
      }
      return false;
    }
    if (_unsafeRiskAcceptanceCommitToken != request.token ||
        _unsafeRiskAcceptanceLifecycleRevision != acceptanceRevision ||
        _latestPreferenceWriteSequence[preferenceKey] !=
            acceptanceWriteSequence ||
        !_matchesUnsafeRiskAcceptanceRequest(request)) {
      if (_unsafeRiskAcceptanceCommitToken == request.token) {
        _unsafeRiskAcceptanceCommitToken = null;
        ++_unsafeRiskAcceptanceLifecycleRevision;
        notifyListeners();
      }
      return true;
    }
    _profile = accepted;
    _unsafeRiskAcceptanceRequestToken = null;
    _unsafeRiskAcceptanceCommitToken = null;
    ++_unsafeRiskAcceptanceLifecycleRevision;
    notifyListeners();
    final GalAttachedSurfaceTarget? currentTarget = _target;
    if (currentTarget != null &&
        _sameLogicalSurface(currentTarget, target) &&
        _exePath == exePath &&
        _exeSha256 == exeSha256) {
      await _evaluateAndActivate(++_operationGeneration, currentTarget);
    }
    return true;
  }

  Future<void> setMode(GalLookupSurfaceMode mode) async {
    GalLookupSurfaceProfileV1? profile = _profile;
    final GalAttachedSurfaceTarget? target = _target;
    if (profile == null) {
      final String? exePath = _exePath;
      final String? exeSha256 = _exeSha256;
      if (exePath == null || exeSha256 == null) return;
      profile = GalLookupSurfaceProfileV1(
        exePath: exePath,
        exeSha256: exeSha256,
        mode: GalLookupSurfaceMode.auto,
        unsafeLeftClickAccepted: false,
        variants: const <GalLookupSurfaceVariantV1>[],
      );
    }
    final int modeRevision = ++_unsafeRiskAcceptanceLifecycleRevision;
    final int modeOperation = ++_operationGeneration;
    final GalLookupSurfaceProfileV1 updated = profile.copyWith(mode: mode);
    _profile = updated;
    if (mode == GalLookupSurfaceMode.off) {
      _unsafeRiskAcceptanceRequestToken = null;
      _unsafeRiskAcceptanceCommitToken = null;
      _surfaceVisible = false;
      _setAttachedProviderClaim(false);
      _setStatus(GalAttachedTextStatus.disabled);
    }
    notifyListeners();
    final Future<void> persistence = _persistProfile(updated);
    try {
      if (target != null) {
        if (mode == GalLookupSurfaceMode.off ||
            mode == GalLookupSurfaceMode.nativeOnly) {
          _setAttachedProviderClaim(false);
          await _surfacePort.detach(target);
          _surfaceVisible = false;
        }
        if (_unsafeRiskAcceptanceLifecycleRevision == modeRevision &&
            _isCurrent(modeOperation, target)) {
          await _evaluateAndActivate(modeOperation, target);
        }
      }
    } finally {
      await persistence;
    }
  }

  Future<void> clearProfile() async {
    final String? exePath = _exePath;
    if (exePath == null) return;
    final GalAttachedSurfaceTarget? target = _target;
    ++_operationGeneration;
    ++_unsafeRiskAcceptanceLifecycleRevision;
    _unsafeRiskAcceptanceRequestToken = null;
    _unsafeRiskAcceptanceCommitToken = null;
    _profile = null;
    _activeVariant = null;
    _setAttachedProviderClaim(false);
    _surfaceVisible = false;
    _setStatus(
      GalAttachedTextStatus.needsCalibration,
      reason: 'profile_cleared',
    );
    final Future<void> persistence = _writePreference(
      GalLookupSurfaceProfileV1.preferenceKeyForExePath(exePath),
      '',
    );
    try {
      if (target != null) await _surfacePort.detach(target);
    } finally {
      await persistence;
    }
  }

  Future<void> updateActiveStyle(GalLookupTextLayoutV1 layout) async {
    final GalLookupSurfaceProfileV1? profile = _profile;
    final GalLookupReferenceClientV1? client = _currentClient;
    final GalAttachedSurfaceTarget? target = _target;
    if (profile == null ||
        client == null ||
        target == null ||
        !layout.isValid) {
      return;
    }
    final GalLookupSurfaceVariantV1? selected = profile.bestVariantForClient(
      client,
    );
    if (selected == null) return;
    final GalLookupSurfaceVariantV1 updatedVariant = GalLookupSurfaceVariantV1(
      aspectRatio: selected.aspectRatio,
      referenceClient: selected.referenceClient,
      bodyRect: selected.bodyRect,
      layout: layout,
    );
    final List<GalLookupSurfaceVariantV1> variants = profile.variants
        .map(
          (GalLookupSurfaceVariantV1 variant) =>
              identical(variant, selected) ? updatedVariant : variant,
        )
        .toList(growable: false);
    final GalLookupSurfaceProfileV1 updated = profile.copyWith(
      variants: variants,
    );
    _profile = updated;
    _activeVariant = updatedVariant;
    await _persistProfile(updated);
    if (_status == GalAttachedTextStatus.activeAttached) {
      final GalAttachedCallResult result = await _surfacePort.updateStyle(
        target: target,
        layout: layout,
      );
      _adoptNativeMetadata(result);
      if (!result.ok && _isCurrentSurface(target)) {
        _activationFailure(result.reason ?? result.error);
      }
    }
  }

  /// Hides the attached catch surface for one mining screenshot transaction.
  ///
  /// Acquisition is fenced by the current text generation. Release is fenced
  /// by the exact surface epoch and capture token: text may advance while the
  /// surface is hidden, in which case release stages/synchronizes the current
  /// generation instead of ever reviving the acquisition-time geometry.
  Future<GalAttachedMiningCaptureLease?> acquireMiningCaptureLease() async {
    final GalAttachedSurfaceTarget? target = _target;
    final int generation = _textGeneration;
    if (target == null ||
        _activeCaptureLease != null ||
        _status != GalAttachedTextStatus.activeAttached ||
        generation <= 0 ||
        _sentSourceText != _latestSourceText) {
      return null;
    }
    final GalAttachedMiningCaptureLease lease = GalAttachedMiningCaptureLease(
      target: target,
      textGeneration: generation,
      captureGeneration: ++_nextCaptureGeneration,
    );
    _activeCaptureLease = lease;
    final GalAttachedCallResult result;
    try {
      result = await _surfacePort.suspendForCapture(
        target: target,
        textGeneration: generation,
        captureGeneration: lease.captureGeneration,
      );
    } catch (_) {
      // The local channel may lose a reply after native has already hidden the
      // HWND. Always attempt the same-token unwind before propagating.
      await releaseMiningCaptureLease(lease);
      rethrow;
    }
    if (!result.ok) {
      // Production MethodChannel failures are returned as a non-ok result,
      // including a malformed/lost reply after native may already have
      // consumed this exact token and hidden the catch surface.  Treat those
      // exactly like a thrown transport error: release the same token.  A
      // native rejection during that unwind detaches fail-closed, so neither
      // side can retain an orphaned capture_suppressed state.
      await releaseMiningCaptureLease(lease);
      return null;
    }
    if (!_matches(target) || generation != _textGeneration) {
      // A sentence/HWND race after the native acknowledgement must not strand
      // capture_suppressed_. Same epoch/token release synchronizes the newer
      // text; an epoch transition has already reset native state and is a no-op.
      await releaseMiningCaptureLease(lease);
      return null;
    }
    _adoptNativeMetadata(result);
    _surfaceVisible = false;
    notifyListeners();
    return lease;
  }

  Future<void> releaseMiningCaptureLease(GalAttachedMiningCaptureLease lease) {
    if (_activeCaptureLease?.captureGeneration != lease.captureGeneration) {
      return Future<void>.value();
    }
    final Future<void>? pending = _captureReleaseFuture;
    if (pending != null &&
        _captureReleaseGeneration == lease.captureGeneration) {
      return pending;
    }
    final Future<void> operation = _releaseMiningCaptureLeaseOnce(lease);
    _captureReleaseGeneration = lease.captureGeneration;
    _captureReleaseFuture = operation;
    return operation;
  }

  Future<void> _releaseMiningCaptureLeaseOnce(
    GalAttachedMiningCaptureLease lease,
  ) async {
    try {
      GalAttachedSurfaceTarget? current = _target;
      if (current == null || !_sameLogicalSurface(current, lease.target)) {
        // Detach/adopt-new-epoch clears native suppression as part of the same
        // lifecycle transition. Never send an old epoch/token into the new one.
        if (_activeCaptureLease?.captureGeneration == lease.captureGeneration) {
          _activeCaptureLease = null;
        }
        return;
      }

      // captureSuppressed is a public suspended state, so ordinary active-only
      // pushing may not have staged a sentence that arrived during capture.
      // Do it while the HWND is still hidden; native release then lays out only
      // its internally current generation.
      while (_sentSourceText != _latestSourceText) {
        final String textAtRelease = _latestSourceText;
        final bool staged;
        try {
          staged = await _pushText(textAtRelease);
        } catch (error) {
          current = _target;
          final Object? detachError = current == null
              ? null
              : await _detachCaptureFailClosed(
                  current,
                  lease,
                  reason: 'capture_restore_text_push_threw',
                );
          throw StateError(
            'capture_restore_text_push_threw: $error'
            '${detachError == null ? '' : '; fail_closed_detach_failed: $detachError'}',
          );
        }
        if (!staged && _latestSourceText != textAtRelease) {
          // A newer source superseded this push. Converge to that generation
          // while the exact capture token still keeps all geometry hidden.
          continue;
        }
        if (!staged && _sentSourceText != _latestSourceText) {
          // A response-level layout rejection means releasing would expose the
          // acquisition sentence. Detach is the only fail-closed unwind: it
          // clears native suppression and all hit geometry together.
          current = _target;
          final Object? detachError = current == null
              ? null
              : await _detachCaptureFailClosed(
                  current,
                  lease,
                  reason: 'capture_restore_text_layout_rejected',
                );
          throw StateError(
            'capture_restore_text_layout_rejected'
            '${detachError == null ? '' : '; fail_closed_detach_failed: $detachError'}',
          );
        }
      }

      current = _target;
      if (current == null || !_sameLogicalSurface(current, lease.target)) {
        if (_activeCaptureLease?.captureGeneration == lease.captureGeneration) {
          _activeCaptureLease = null;
        }
        return;
      }
      final int currentTextGeneration = _textGeneration;
      final GalAttachedCallResult result;
      try {
        result = await _surfacePort.restoreAfterCapture(
          target: current,
          textGeneration: currentTextGeneration,
          captureGeneration: lease.captureGeneration,
        );
      } catch (error, stackTrace) {
        // The reply can be lost after native has consumed the token. Retrying
        // would only produce stale_capture_lease and leave Dart permanently
        // busy. Detach is the fail-closed reconciliation: whether restore ran
        // or not, it clears suppression and geometry without reviving the old
        // sentence, then the next explicit activation starts a fresh lease.
        final Object? detachError = await _detachCaptureFailClosed(
          current,
          lease,
          reason: 'capture_restore_reply_lost',
        );
        if (detachError != null) {
          throw StateError(
            'capture_restore_reply_lost; fail_closed_detach_failed: '
            '$detachError; original: $error',
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (_activeCaptureLease?.captureGeneration != lease.captureGeneration ||
          _target == null ||
          !_sameLogicalSurface(_target!, lease.target)) {
        return;
      }
      _adoptNativeMetadata(result);
      _surfaceVisible = result.surfaceVisible;
      final bool barrierFailedAfterTokenConsumed =
          result.reason == 'capture_dwm_flush_failed' ||
          result.error == 'capture_dwm_flush_failed';
      if (result.ok || barrierFailedAfterTokenConsumed) {
        // Native consumes the exact token before its restore barrier. A failed
        // DwmFlush is reported, but must not keep Dart believing the HWND is
        // suppressed and block every later mining transaction.
        _activeCaptureLease = null;
      }
      notifyListeners();
      if (!result.ok) {
        if (!barrierFailedAfterTokenConsumed) {
          final Object? detachError = await _detachCaptureFailClosed(
            current,
            lease,
            reason: result.reason ?? result.error ?? 'capture_restore_rejected',
          );
          if (detachError != null) {
            throw StateError(
              '${result.reason ?? result.error ?? 'capture_restore_rejected'}; '
              'fail_closed_detach_failed: $detachError',
            );
          }
        }
        throw StateError(
          result.reason ?? result.error ?? 'attached_capture_restore_rejected',
        );
      }
    } finally {
      if (_captureReleaseGeneration == lease.captureGeneration) {
        _captureReleaseGeneration = null;
        _captureReleaseFuture = null;
      }
    }
  }

  Future<Object?> _detachCaptureFailClosed(
    GalAttachedSurfaceTarget target,
    GalAttachedMiningCaptureLease lease, {
    required String reason,
  }) async {
    Object? detachError;
    try {
      final GalAttachedCallResult result = await _surfacePort.detach(target);
      if (!result.ok) {
        detachError = StateError(
          result.reason ??
              result.error ??
              'capture_fail_closed_detach_rejected',
        );
      }
    } catch (error) {
      detachError = error;
    }
    if (_activeCaptureLease?.captureGeneration == lease.captureGeneration &&
        _target != null &&
        _sameLogicalSurface(_target!, lease.target)) {
      _surfaceVisible = false;
      if (detachError == null) {
        _activeCaptureLease = null;
        // Native Detach clears its source/layout. Force the next explicit
        // activation to republish the current hooked sentence even if the
        // Dart source string itself did not change.
        _sentSourceText = '';
        _activationFailure(reason);
      } else {
        // A non-ok MethodChannel result is transport-ambiguous: native may
        // still own the capture token. Keep the Dart lease latched and the
        // surface unusable instead of claiming that fail-closed detach ran.
        // A later session/surface epoch reset is the only safe reconciliation.
        _activationFailure('capture_fail_closed_detach_unconfirmed');
      }
      notifyListeners();
    }
    return detachError;
  }

  Future<void> _persistProfile(GalLookupSurfaceProfileV1 profile) =>
      _writePreference(
        GalLookupSurfaceProfileV1.preferenceKeyForExePath(profile.exePath),
        jsonEncode(profile.toJson()),
      );

  Future<void> _writePreference(String key, Object? value) {
    // Every mutation writes the complete profile object. Preserve invocation
    // order so a slower stale consent write cannot resurrect authorization
    // after a later mode change or clear.
    final int sequence = ++_nextPreferenceWriteSequence;
    _latestPreferenceWriteSequence[key] = sequence;
    final Future<void> operation = _preferenceWriteTail.then(
      (_) => _preferenceWriter(key, value),
    );
    _preferenceWriteTail = operation.catchError((Object _, StackTrace __) {});
    return operation;
  }

  Future<void> _pushLatestTextIfActive() async {
    if ((_status != GalAttachedTextStatus.activeAttached &&
            _activeCaptureLease == null) ||
        _latestSourceText == _sentSourceText) {
      return;
    }
    await _pushText(_latestSourceText);
  }

  Future<bool> _pushText(
    String sourceText, {
    bool stageWhileProviderPending = false,
  }) {
    final GalAttachedSurfaceTarget? target = _target;
    if (target == null) return Future<bool>.value(false);
    final Future<bool>? pending = _textPushFuture;
    if (pending != null &&
        _textPushTarget?.matches(target) == true &&
        _textPushSource == sourceText &&
        _textPushStagesProviderPending == stageWhileProviderPending) {
      return pending;
    }
    final int operation = ++_textPushOperation;
    final Future<bool> future = _runPushText(
      operation: operation,
      target: target,
      sourceText: sourceText,
      stageWhileProviderPending: stageWhileProviderPending,
    );
    _textPushTarget = target;
    _textPushSource = sourceText;
    _textPushStagesProviderPending = stageWhileProviderPending;
    _textPushFuture = future;
    return future;
  }

  Future<bool> _runPushText({
    required int operation,
    required GalAttachedSurfaceTarget target,
    required String sourceText,
    required bool stageWhileProviderPending,
  }) async {
    final String? providerPendingStatus = _nativeStatus;
    final int? providerPendingKind = _providerKind;
    final int? providerPendingId = _providerId;
    final int? providerPendingState = _providerStatus;
    final int generation = ++_textGeneration;
    try {
      final GalAttachedCallResult result = await _surfacePort.updateText(
        target: target,
        sourceText: sourceText,
        textGeneration: generation,
      );
      if (!_isCurrentSurface(target) || generation != _textGeneration) {
        return false;
      }
      _adoptNativeMetadata(result);
      if (!result.ok) {
        _activationFailure(result.reason ?? result.error);
        return false;
      }
      _sentSourceText = sourceText;
      if (stageWhileProviderPending) {
        // updateText may stage clusters while the registry drains the previous
        // mouse transaction, but its reply is not a provider-ownership lease.
        // Keep the configure result authoritative until a health event reports
        // kind=4/id=11 as ready/active.
        _nativeStatus = providerPendingStatus ?? 'geometryProviderPending';
        _providerKind = providerPendingKind;
        _providerId = providerPendingId;
        _providerStatus = providerPendingState;
        _surfaceVisible = false;
      } else {
        _surfaceVisible = _activeCaptureLease == null && result.surfaceVisible;
      }
      notifyListeners();
      return true;
    } finally {
      if (_textPushOperation == operation) {
        _textPushFuture = null;
        _textPushTarget = null;
        _textPushSource = null;
        _textPushStagesProviderPending = false;
      }
    }
  }

  Future<void> detach() async {
    ++_unsafeRiskAcceptanceLifecycleRevision;
    final bool riskRequestRetired =
        _unsafeRiskAcceptanceRequestToken != null ||
        _unsafeRiskAcceptanceCommitToken != null;
    _unsafeRiskAcceptanceRequestToken = null;
    _unsafeRiskAcceptanceCommitToken = null;
    if (riskRequestRetired) notifyListeners();
    final GalAttachedSurfaceTarget? target = _target;
    if (target == null) {
      if (_status != GalAttachedTextStatus.disabled) {
        _resetLocalState();
        notifyListeners();
      }
      return;
    }
    ++_operationGeneration;
    await _surfacePort.detach(target);
    if (_isCurrentSurface(target)) {
      _resetLocalState();
      notifyListeners();
    }
  }

  void _clearDraft() {
    _draftBodyRect = null;
    _draftLayout = null;
    _calibrationProbeMask = 0;
  }

  void _resetLocalState() {
    _target = null;
    _profile = null;
    _activeVariant = null;
    _currentClient = null;
    _exePath = null;
    _exeSha256 = null;
    _launchExePath = null;
    _latestSourceText = '';
    _sentSourceText = '';
    _textGeneration = 0;
    _activeCaptureLease = null;
    _captureReleaseFuture = null;
    _captureReleaseGeneration = null;
    ++_textPushOperation;
    _textPushFuture = null;
    _textPushTarget = null;
    _textPushSource = null;
    _textPushStagesProviderPending = false;
    _retiredTargetHwnds.clear();
    _activationDeferred = false;
    _clearDraft();
    _surfaceVisible = false;
    _nativeStatus = null;
    _shieldStatus = const GalAttachedShieldStatus();
    _providerKind = null;
    _providerId = null;
    _providerStatus = null;
    _attachedProviderClaimed = false;
    _forceAttachedProvider = false;
    _unsafeRiskAcceptanceRequestToken = null;
    _unsafeRiskAcceptanceCommitToken = null;
    _probeStartObservedIndex = null;
    _probeMiddleObservedIndex = null;
    _probeEndObservedIndex = null;
    _statusReason = null;
    _status = GalAttachedTextStatus.disabled;
  }

  Future<bool> _claimAttachedProvider(
    int operation,
    GalAttachedSurfaceTarget target, {
    required GalLookupSurfaceMode profileMode,
    bool forceAttached = false,
    bool Function()? stillCurrent,
  }) async {
    if (stillCurrent != null && !stillCurrent()) return false;
    _setAttachedProviderClaim(true, forceAttached: forceAttached);
    final GalAttachedBeforeActivationCallback? callback =
        _onBeforeAttachedActivation;
    if (callback != null) {
      try {
        await callback(profileMode, forceAttached: forceAttached);
      } catch (_) {
        // BUG-2091：只有仍然当前的这一轮才有权撤回认领。被抢占的旧轮次去撤，撤掉的是
        // **新轮次刚发出的**那份认领。
        if (_isCurrent(operation, target)) {
          _setAttachedProviderClaim(false);
          _activationFailure('provider_handoff_failed');
        }
        return false;
      }
    }
    if (stillCurrent != null && !stillCurrent()) {
      // BUG-2091：被抢占时**不得**撤回认领。`_attachedProviderClaimed` 是跨轮次共享的
      // 单一状态，新一轮已经（或即将）自己认领；旧轮次在这里撤一次，注入侧 registry
      // 下一拍看到的就是 attachedReady=false，于是永远不会把 kind=4/id=11 判成 ready，
      // 而宿主又在等这个 ready 才进 activeAttached —— 两边互等成活锁，状态永久停在
      // geometryProviderPending。真机 WoH 上复现为「认领 40ms 后被撤回」。
      // 认领的释放由当前轮次的 detach / 失败分支负责，不由旧轮次代劳。
      return false;
    }
    return _isCurrent(operation, target);
  }

  void _setAttachedProviderClaim(bool claimed, {bool forceAttached = false}) {
    final bool normalizedForce = claimed && forceAttached;
    if (_attachedProviderClaimed == claimed &&
        _forceAttachedProvider == normalizedForce) {
      return;
    }
    _attachedProviderClaimed = claimed;
    _forceAttachedProvider = normalizedForce;
    notifyListeners();
  }

  bool _isCurrent(int operation, GalAttachedSurfaceTarget target) =>
      operation == _operationGeneration &&
      _target != null &&
      _sameLogicalSurface(_target!, target);

  bool _matches(GalAttachedSurfaceTarget target) =>
      _target?.matches(target) ?? false;

  bool _isCurrentSurface(GalAttachedSurfaceTarget target) =>
      _target != null && _sameLogicalSurface(_target!, target);

  bool _matchesUnsafeRiskAcceptanceRequest(
    GalAttachedUnsafeRiskAcceptanceRequest request,
  ) =>
      needsUnsafeRiskAcceptance &&
      _unsafeRiskAcceptanceRequestToken == request.token &&
      _target != null &&
      _sameLogicalSurface(_target!, request.target) &&
      _exePath == request.exePath &&
      _exeSha256 == request.exeSha256;

  bool _adoptLifecycleTarget(GalAttachedSurfaceTarget incoming) {
    final GalAttachedSurfaceTarget? current = _target;
    if (current == null || !_sameLogicalSurface(current, incoming)) {
      return false;
    }
    if (current.targetHwnd == incoming.targetHwnd) return true;
    if (_retiredTargetHwnds.contains(incoming.targetHwnd)) return false;
    _retiredTargetHwnds.add(current.targetHwnd);
    _target = incoming;
    return true;
  }

  static bool _sameLogicalSurface(
    GalAttachedSurfaceTarget left,
    GalAttachedSurfaceTarget right,
  ) =>
      left.sessionEpoch == right.sessionEpoch &&
      left.surfaceEpoch == right.surfaceEpoch &&
      left.targetPid == right.targetPid;

  void _setStatus(GalAttachedTextStatus value, {String? reason}) {
    final int? previousRiskRequestToken = _unsafeRiskAcceptanceRequestToken;
    final int? previousRiskCommitToken = _unsafeRiskAcceptanceCommitToken;
    if (value == GalAttachedTextStatus.needsRiskAcceptance) {
      _unsafeRiskAcceptanceRequestToken ??=
          ++_nextUnsafeRiskAcceptanceRequestToken;
    } else if (value != GalAttachedTextStatus.suspended) {
      _unsafeRiskAcceptanceRequestToken = null;
      _unsafeRiskAcceptanceCommitToken = null;
    }
    final bool riskRequestChanged =
        previousRiskRequestToken != _unsafeRiskAcceptanceRequestToken ||
        previousRiskCommitToken != _unsafeRiskAcceptanceCommitToken;
    final bool changed =
        _status != value || _statusReason != reason || riskRequestChanged;
    _status = value;
    _statusReason = reason;
    if (changed) {
      if (riskRequestChanged) ++_unsafeRiskAcceptanceLifecycleRevision;
      notifyListeners();
    }
  }

  void _adoptNativeMetadata(GalAttachedCallResult result) {
    if (result.status != null) _nativeStatus = result.status;
    _shieldStatus = result.shield;
    if (result.providerKind != null) _providerKind = result.providerKind;
    if (result.providerId != null) _providerId = result.providerId;
    if (result.providerStatus != null) {
      _providerStatus = result.providerStatus;
    }
    if (result.probeStartObservedIndex != null) {
      _probeStartObservedIndex = result.probeStartObservedIndex;
    }
    if (result.probeMiddleObservedIndex != null) {
      _probeMiddleObservedIndex = result.probeMiddleObservedIndex;
    }
    if (result.probeEndObservedIndex != null) {
      _probeEndObservedIndex = result.probeEndObservedIndex;
    }
    if (_status == GalAttachedTextStatus.calibrating) {
      if (result.bodyRect != null) _draftBodyRect = result.bodyRect;
      if (result.layout != null) _draftLayout = result.layout;
    }
  }

  GalAttachedCalibrationProbes _onlyObservedConfirmations(
    GalAttachedCalibrationProbes probes,
  ) => GalAttachedCalibrationProbes(
    startIndex: probes.startIndex,
    middleIndex: probes.middleIndex,
    endIndex: probes.endIndex,
    startConfirmed:
        probes.startConfirmed && _probeStartObservedIndex == probes.startIndex,
    middleConfirmed:
        probes.middleConfirmed &&
        _probeMiddleObservedIndex == probes.middleIndex,
    endConfirmed:
        probes.endConfirmed && _probeEndObservedIndex == probes.endIndex,
  );

  bool _allProbeIndicesObserved(GalAttachedCalibrationProbes probes) =>
      _probeStartObservedIndex == probes.startIndex &&
      _probeMiddleObservedIndex == probes.middleIndex &&
      _probeEndObservedIndex == probes.endIndex;

  bool get _nativeRiskGateSatisfied =>
      _shieldStatus.conclusion == GalAttachedShieldConclusion.verified ||
      (_profile?.unsafeLeftClickAccepted ?? false);

  void _activateNativeOrRequestRisk({String? reason}) {
    _activeVariant = null;
    _surfaceVisible = false;
    if (!_nativeRiskGateSatisfied) {
      // BUG-2092：这里的 reason 是可选入参，之前调用方不传就报 null。
      _setStatus(
        GalAttachedTextStatus.needsRiskAcceptance,
        reason: reason ?? 'native_activation_risk_gate_unsatisfied',
      );
      return;
    }
    _setStatus(GalAttachedTextStatus.activeNative, reason: reason);
  }

  static bool _nativeProviderPending(
    GalLookupSurfaceMode mode,
    String? status,
  ) =>
      (mode == GalLookupSurfaceMode.auto ||
          mode == GalLookupSurfaceMode.nativeOnly) &&
      status == 'nativeProviderPendingNeutral';

  static bool _attachedRegistryProviderReady(
    int? providerKind,
    int? providerId,
    int? providerStatus,
  ) =>
      providerKind == 4 &&
      providerId == 11 &&
      (providerStatus == 1 || providerStatus == 2);

  static bool _nativeProviderReady({
    required GalLookupSurfaceMode mode,
    required int? providerKind,
    required int? providerId,
    required int? providerStatus,
  }) {
    if (mode != GalLookupSurfaceMode.auto &&
        mode != GalLookupSurfaceMode.nativeOnly) {
      return false;
    }
    final bool productionPair =
        providerKind != null &&
        providerId != null &&
        isGalLookupProductionProviderPair(providerKind, providerId);
    final bool readyOrActive = providerStatus == 1 || providerStatus == 2;
    // `status` belongs to the optional desktop attached surface, not to the
    // in-process geometry provider. In particular, switching to nativeOnly
    // deliberately detaches that surface while SGRE/Siglus/Leaf remains the
    // registry's Ready/Active owner. Requiring an attached-surface token here
    // leaves a coherent native provider permanently suspended after that
    // handoff. The production kind/id pair and provider lifecycle are the
    // authoritative native readiness proof. Callers still pass the shield
    // fault gate and [_activateNativeOrRequestRisk], so this does not weaken
    // per-executable risk acceptance.
    return productionPair && readyOrActive;
  }
}

@immutable
class GalAttachedMiningCaptureLease {
  const GalAttachedMiningCaptureLease({
    required this.target,
    required this.textGeneration,
    required this.captureGeneration,
  });

  final GalAttachedSurfaceTarget target;
  final int textGeneration;
  final int captureGeneration;
}
