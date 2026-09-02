import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// Compact, always-present controls for the Windows no-OCR lookup surface.
///
/// The page passes its one shared [GalAttachedTextController]; this widget does
/// not subscribe to the gal session independently.
class GalAttachedLookupWorkbench extends StatelessWidget {
  const GalAttachedLookupWorkbench({
    required this.controller,
    required this.hasSelectedBodyThread,
    required this.bodyPreview,
    super.key,
  });

  final GalAttachedTextController controller;
  final bool hasSelectedBodyThread;
  final String bodyPreview;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? child) {
        final GalLookupSurfaceProfileV1? profile = controller.profile;
        final GalLookupSurfaceMode mode =
            profile?.mode ?? GalLookupSurfaceMode.auto;
        final bool riskModeActive = controller.isUnsafeInputActive;
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final bool riskPending =
            controller.status == GalAttachedTextStatus.needsRiskAcceptance;
        final bool canOpenCalibration =
            hasSelectedBodyThread && controller.canCalibrate;

        return Material(
          key: const ValueKey<String>('game-attached-lookup-workbench'),
          color: tokens.surfaces.group,
          child: SizedBox(
            height: 44,
            child: Row(
              children: <Widget>[
                const SizedBox(width: 10),
                Tooltip(
                  message: t.game_lookup_attached_no_ocr,
                  child: const Icon(Icons.touch_app_outlined, size: 18),
                ),
                const SizedBox(width: 6),
                Text(
                  t.game_lookup_attached_title,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: HorizontalDragScrollable(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: <Widget>[
                          _WorkbenchPill(
                            label: t.game_lookup_attached_mode,
                            value: _modeLabel(mode),
                          ),
                          const SizedBox(width: 6),
                          _WorkbenchPill(
                            label: t.game_lookup_attached_status,
                            value: controller.status.name,
                          ),
                          const SizedBox(width: 6),
                          _WorkbenchPill(
                            label: t.game_lookup_attached_native_status,
                            value: controller.nativeStatus ?? '—',
                          ),
                          const SizedBox(width: 6),
                          _WorkbenchPill(
                            label: t.game_lookup_attached_provider,
                            value: galAttachedProviderLabel(
                              providerKind: controller.providerKind,
                              providerId: controller.providerId,
                              providerStatus: controller.providerStatus,
                              fallbackStatus: controller.status,
                              unknownLabel:
                                  t.game_lookup_attached_provider_unknown,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _WorkbenchPill(
                            label: t.game_lookup_attached_profile,
                            value: profile == null || profile.variants.isEmpty
                                ? t.game_lookup_attached_profile_missing
                                : '${t.game_lookup_attached_profile_ready} '
                                      '(${profile.variants.length})',
                          ),
                          const SizedBox(width: 6),
                          _WorkbenchPill(
                            label: t.game_lookup_attached_shield,
                            value: _shieldLabel(
                              controller.shieldStatus.conclusion,
                            ),
                            warning:
                                controller.shieldStatus.conclusion !=
                                GalAttachedShieldConclusion.verified,
                          ),
                          const SizedBox(width: 6),
                          _WorkbenchPill(
                            key: const ValueKey<String>(
                              'game-attached-lookup-risk-status',
                            ),
                            label: t.game_lookup_attached_risk,
                            value: riskModeActive
                                ? t.game_lookup_attached_risk_active
                                : riskPending
                                ? t.game_lookup_attached_risk_pending
                                : t.game_lookup_attached_risk_safe,
                            warning: riskModeActive || riskPending,
                          ),
                          if (!hasSelectedBodyThread) ...<Widget>[
                            const SizedBox(width: 6),
                            _WorkbenchPill(
                              label: t.game_lookup_attached_calibrate,
                              value: t.game_lookup_attached_thread_required,
                              warning: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('game-attached-lookup-calibrate'),
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints.tightFor(
                    width: tokens.density.compactControlHeight,
                    height: tokens.density.compactControlHeight,
                  ),
                  tooltip: canOpenCalibration
                      ? t.game_lookup_attached_calibrate
                      : t.game_lookup_attached_thread_required,
                  onPressed: canOpenCalibration
                      ? () => _openCalibration(context)
                      : null,
                  icon: const Icon(Icons.crop_free_outlined, size: 20),
                ),
                if (riskPending)
                  TextButton.icon(
                    key: const ValueKey<String>(
                      'game-attached-lookup-accept-risk',
                    ),
                    onPressed: controller.target == null
                        ? null
                        : () => _acceptRisk(context),
                    icon: const Icon(Icons.warning_amber_rounded, size: 18),
                    label: Text(t.game_lookup_attached_risk_accept),
                  ),
                PopupMenuButton<String>(
                  key: const ValueKey<String>('game-attached-lookup-mode'),
                  tooltip: t.game_lookup_attached_mode,
                  icon: const Icon(Icons.tune_outlined, size: 20),
                  onSelected: (String action) {
                    if (action.startsWith('mode:')) {
                      final GalLookupSurfaceMode selected = GalLookupSurfaceMode
                          .values
                          .firstWhere(
                            (GalLookupSurfaceMode value) =>
                                value.wireName == action.substring(5),
                          );
                      unawaited(controller.setMode(selected));
                    } else if (action == 'clear') {
                      unawaited(_clearProfile(context));
                    }
                  },
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          enabled: false,
                          child: Text(t.game_lookup_attached_no_ocr),
                        ),
                        for (final GalLookupSurfaceMode value
                            in GalLookupSurfaceMode.values)
                          CheckedPopupMenuItem<String>(
                            value: 'mode:${value.wireName}',
                            checked: value == mode,
                            enabled: controller.target != null,
                            child: Text(_modeLabel(value)),
                          ),
                        if (profile != null)
                          PopupMenuItem<String>(
                            key: const ValueKey<String>(
                              'game-attached-lookup-clear-profile',
                            ),
                            value: 'clear',
                            child: Text(t.game_lookup_attached_profile_clear),
                          ),
                      ],
                ),
                const SizedBox(width: 2),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<bool> _confirmRisk(BuildContext context) async {
    final bool? accepted = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Row(
          children: <Widget>[
            const Icon(Icons.warning_amber_rounded),
            const SizedBox(width: 8),
            Expanded(child: Text(t.game_lookup_attached_risk_title)),
          ],
        ),
        content: Text(t.game_lookup_attached_risk_body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            key: const ValueKey<String>('game-attached-lookup-risk-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.game_lookup_attached_risk_accept),
          ),
        ],
      ),
    );
    return accepted == true;
  }

  Future<void> _acceptRisk(BuildContext context) async {
    if (!await _confirmRisk(context) || !context.mounted) return;
    await controller.acceptUnsafeRiskAndRetry();
  }

  Future<void> _openCalibration(BuildContext context) async {
    if (!hasSelectedBodyThread || !controller.canCalibrate) return;
    final GalLookupSurfaceProfileV1? profile = controller.profile;
    final bool alreadyAccepted = profile?.unsafeLeftClickAccepted ?? false;
    if (!alreadyAccepted && !await _confirmRisk(context)) return;
    if (!context.mounted) return;

    final GalAttachedProbePlan? probePlan = buildGalAttachedProbePlan(
      controller.latestSourceText.isNotEmpty
          ? controller.latestSourceText
          : bodyPreview,
    );
    if (probePlan == null) {
      _showFailure(context, t.game_lookup_attached_calibration_short_text);
      return;
    }
    final bool started = await controller.beginCalibration(
      acceptUnsafeLeftClick: true,
    );
    if (!context.mounted) return;
    if (!started || controller.draftBodyRect == null) {
      _showFailure(context, t.game_lookup_attached_calibration_failed);
      return;
    }

    final bool? committed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => GalAttachedCalibrationDialog(
        controller: controller,
        previewText: controller.latestSourceText,
        probePlan: probePlan,
        initialRect:
            controller.draftBodyRect ??
            GalAttachedTextController.defaultBodyRect,
        initialLayout: controller.draftLayout ?? const GalLookupTextLayoutV1(),
      ),
    );
    if (committed != true &&
        controller.status == GalAttachedTextStatus.calibrating) {
      await controller.cancelCalibration();
    }
  }

  Future<void> _clearProfile(BuildContext context) async {
    final bool? clear = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t.game_lookup_attached_profile_clear_title),
        content: Text(t.game_lookup_attached_profile_clear_body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            key: const ValueKey<String>('game-attached-lookup-clear-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.dialog_clear),
          ),
        ],
      ),
    );
    if (clear == true) await controller.clearProfile();
  }

  void _showFailure(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  String _modeLabel(GalLookupSurfaceMode mode) => switch (mode) {
    GalLookupSurfaceMode.auto => t.game_lookup_attached_mode_auto,
    GalLookupSurfaceMode.nativeOnly => t.game_lookup_attached_mode_native_only,
    GalLookupSurfaceMode.attachedOnly =>
      t.game_lookup_attached_mode_attached_only,
    GalLookupSurfaceMode.off => t.game_lookup_attached_mode_off,
  };

  String _shieldLabel(GalAttachedShieldConclusion conclusion) =>
      switch (conclusion) {
        GalAttachedShieldConclusion.verified =>
          t.game_lookup_attached_shield_verified,
        GalAttachedShieldConclusion.partial =>
          t.game_lookup_attached_shield_partial,
        GalAttachedShieldConclusion.knownUncovered =>
          t.game_lookup_attached_shield_known_uncovered,
        GalAttachedShieldConclusion.faulted =>
          t.game_lookup_attached_shield_faulted,
        GalAttachedShieldConclusion.unknown =>
          t.game_lookup_attached_shield_unknown,
      };
}

class _WorkbenchPill extends StatelessWidget {
  const _WorkbenchPill({
    required this.label,
    required this.value,
    this.warning = false,
    super.key,
  });

  final String label;
  final String value;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return FushiTagChip(
      label: '$label: $value',
      color: warning ? colors.tertiaryContainer : null,
    );
  }
}

/// Stable technical provider label. Unknown future ids retain their numbers so
/// field reports stay actionable without pretending they are recognized.
String galAttachedProviderLabel({
  required int? providerKind,
  required int? providerId,
  required int? providerStatus,
  required GalAttachedTextStatus fallbackStatus,
  required String unknownLabel,
}) {
  const Map<int, String> ids = <int, String>{
    1: 'KiriKiri TJS',
    2: "Ren'Py",
    3: 'Siglus',
    4: 'Leaf/AQUAPLUS',
    5: 'SGRE',
    6: 'Tyrano DOM',
    7: 'Unity TMP',
    8: 'Unity UGUI',
    9: 'GDI positioned',
    10: 'DirectWrite positioned',
    11: 'attached_calibrated',
    12: 'pixel_template_experimental',
    13: 'typewriter_diff_experimental',
  };
  const Map<int, String> kinds = <int, String>{
    1: 'runtime_layout',
    2: 'engine_exact_layout',
    3: 'positioned_text_api',
    4: 'attached_calibrated',
    5: 'pixel_template_experimental',
    6: 'typewriter_diff_experimental',
  };
  const Map<int, String> statuses = <int, String>{
    0: 'unavailable',
    1: 'ready',
    2: 'active',
    3: 'suspended',
    4: 'faulted',
  };
  String? provider = providerId == null
      ? null
      : ids[providerId] ?? 'provider#$providerId';
  provider ??= providerKind == null
      ? null
      : kinds[providerKind] ?? 'kind#$providerKind';
  provider ??= switch (fallbackStatus) {
    GalAttachedTextStatus.activeAttached ||
    GalAttachedTextStatus.calibrating => 'attached_calibrated',
    GalAttachedTextStatus.activeNative => 'native',
    _ => null,
  };
  if (provider == null) return unknownLabel;
  if (providerStatus == null) return provider;
  return '$provider · ${statuses[providerStatus] ?? 'status#$providerStatus'}';
}

class GalAttachedProbePlan {
  const GalAttachedProbePlan({
    required this.startIndex,
    required this.middleIndex,
    required this.endIndex,
    required this.startText,
    required this.middleText,
    required this.endText,
  });

  final int startIndex;
  final int middleIndex;
  final int endIndex;
  final String startText;
  final String middleText;
  final String endText;
}

/// Chooses three distinct Unicode-scalar starts while preserving UTF-16 wire
/// indices. It never selects the low half of a surrogate pair.
GalAttachedProbePlan? buildGalAttachedProbePlan(String text) {
  final List<int> starts = <int>[];
  for (int offset = 0; offset < text.length;) {
    starts.add(offset);
    final int first = text.codeUnitAt(offset);
    final bool surrogatePair =
        first >= 0xD800 &&
        first <= 0xDBFF &&
        offset + 1 < text.length &&
        text.codeUnitAt(offset + 1) >= 0xDC00 &&
        text.codeUnitAt(offset + 1) <= 0xDFFF;
    offset += surrogatePair ? 2 : 1;
  }
  if (starts.length < 3) return null;
  final int start = starts.first;
  final int middle = starts[starts.length ~/ 2];
  final int end = starts.last;
  String scalarAt(int index) {
    final int next = starts.firstWhere(
      (int value) => value > index,
      orElse: () => text.length,
    );
    return text.substring(index, next);
  }

  return GalAttachedProbePlan(
    startIndex: start,
    middleIndex: middle,
    endIndex: end,
    startText: scalarAt(start),
    middleText: scalarAt(middle),
    endText: scalarAt(end),
  );
}

class GalAttachedCalibrationDialog extends StatefulWidget {
  const GalAttachedCalibrationDialog({
    required this.controller,
    required this.previewText,
    required this.probePlan,
    required this.initialRect,
    required this.initialLayout,
    super.key,
  });

  final GalAttachedTextController controller;
  final String previewText;
  final GalAttachedProbePlan probePlan;
  final GalLookupNormalizedRectV1 initialRect;
  final GalLookupTextLayoutV1 initialLayout;

  @override
  State<GalAttachedCalibrationDialog> createState() =>
      _GalAttachedCalibrationDialogState();
}

class _GalAttachedCalibrationDialogState
    extends State<GalAttachedCalibrationDialog> {
  late GalLookupNormalizedRectV1 _rect;
  late GalLookupTextLayoutV1 _layout;
  late final TextEditingController _fontController;
  bool _startConfirmed = false;
  bool _middleConfirmed = false;
  bool _endConfirmed = false;
  bool _committing = false;
  String? _error;
  Future<void> _draftQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _rect = widget.initialRect;
    _layout = widget.initialLayout;
    _fontController = TextEditingController(text: _layout.fontFamily);
    widget.controller.addListener(_adoptNativeDraft);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_adoptNativeDraft);
    _fontController.dispose();
    super.dispose();
  }

  void _adoptNativeDraft() {
    if (!mounted) return;
    final GalLookupNormalizedRectV1 nextRect =
        widget.controller.draftBodyRect ?? _rect;
    final GalLookupTextLayoutV1 nextLayout =
        widget.controller.draftLayout ?? _layout;
    setState(() {
      _rect = nextRect;
      _layout = nextLayout;
      if (_fontController.text != nextLayout.fontFamily) {
        _fontController.value = TextEditingValue(
          text: nextLayout.fontFamily,
          selection: TextSelection.collapsed(
            offset: nextLayout.fontFamily.length,
          ),
        );
      }
    });
  }

  GalAttachedCalibrationProbes get _probes => GalAttachedCalibrationProbes(
    startIndex: widget.probePlan.startIndex,
    middleIndex: widget.probePlan.middleIndex,
    endIndex: widget.probePlan.endIndex,
    startConfirmed: _startConfirmed && _startObserved,
    middleConfirmed: _middleConfirmed && _middleObserved,
    endConfirmed: _endConfirmed && _endObserved,
  );

  bool get _startObserved =>
      widget.controller.probeStartObservedIndex == widget.probePlan.startIndex;
  bool get _middleObserved =>
      widget.controller.probeMiddleObservedIndex ==
      widget.probePlan.middleIndex;
  bool get _endObserved =>
      widget.controller.probeEndObservedIndex == widget.probePlan.endIndex;

  bool get _allConfirmed =>
      _startConfirmed &&
      _middleConfirmed &&
      _endConfirmed &&
      _startObserved &&
      _middleObserved &&
      _endObserved;

  void _queueDraftPush() {
    final GalLookupNormalizedRectV1 rect = _rect;
    final GalLookupTextLayoutV1 layout = _layout;
    final GalAttachedCalibrationProbes probes = _probes;
    _draftQueue = _draftQueue.then((_) async {
      if (!mounted) return;
      final bool styleOk = await widget.controller.updateCalibrationStyle(
        layout,
      );
      final bool rectOk = await widget.controller.updateCalibration(
        bodyRect: rect,
        probes: probes,
      );
      if (mounted && (!styleOk || !rectOk)) {
        setState(() => _error = t.game_lookup_attached_calibration_failed);
      }
    });
  }

  void _setRect(GalLookupNormalizedRectV1 value) {
    if (!value.isValid) return;
    setState(() {
      _rect = value;
      _error = null;
    });
  }

  void _setLayout(GalLookupTextLayoutV1 value) {
    if (!value.isValid) return;
    setState(() {
      _layout = value;
      _error = null;
    });
  }

  GalLookupTextLayoutV1 _copyLayout({
    String? fontFamily,
    double? fontSizePerClientHeight,
    double? letterSpacing,
    double? lineHeight,
    String? textAlign,
    String? verticalAlign,
  }) => GalLookupTextLayoutV1(
    fontFamily: fontFamily ?? _layout.fontFamily,
    fontSizePerClientHeight:
        fontSizePerClientHeight ?? _layout.fontSizePerClientHeight,
    letterSpacingPerClientHeight:
        letterSpacing ?? _layout.letterSpacingPerClientHeight,
    lineHeight: lineHeight ?? _layout.lineHeight,
    textAlign: textAlign ?? _layout.textAlign,
    verticalAlign: verticalAlign ?? _layout.verticalAlign,
    paddingPerClientHeight: _layout.paddingPerClientHeight,
  );

  void _setStartConfirmed(bool? value) {
    setState(() => _startConfirmed = value == true);
    _queueDraftPush();
  }

  void _setMiddleConfirmed(bool? value) {
    setState(() => _middleConfirmed = value == true);
    _queueDraftPush();
  }

  void _setEndConfirmed(bool? value) {
    setState(() => _endConfirmed = value == true);
    _queueDraftPush();
  }

  Future<void> _commit() async {
    if (!_allConfirmed || _committing) return;
    setState(() {
      _committing = true;
      _error = null;
    });
    _queueDraftPush();
    await _draftQueue;
    final bool committed = await widget.controller.commitCalibration(
      probes: _probes,
    );
    if (!mounted) return;
    if (committed) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _committing = false;
      _error = t.game_lookup_attached_calibration_failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return AlertDialog(
      title: Text(t.game_lookup_attached_calibration_title),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                t.game_lookup_attached_preview,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              FushiCard(
                padding: EdgeInsets.all(tokens.spacing.rowVertical),
                child: SelectableText(widget.previewText),
              ),
              const SizedBox(height: 16),
              Text(
                t.game_lookup_attached_body_rect,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              _RatioSlider(
                label: t.game_lookup_attached_left,
                value: _rect.left,
                min: 0,
                max: 1 - _rect.width,
                onChanged: (double value) => _setRect(
                  GalLookupNormalizedRectV1(
                    left: value,
                    top: _rect.top,
                    width: _rect.width,
                    height: _rect.height,
                  ),
                ),
                onChangeEnd: (_) => _queueDraftPush(),
              ),
              _RatioSlider(
                label: t.game_lookup_attached_top,
                value: _rect.top,
                min: 0,
                max: 1 - _rect.height,
                onChanged: (double value) => _setRect(
                  GalLookupNormalizedRectV1(
                    left: _rect.left,
                    top: value,
                    width: _rect.width,
                    height: _rect.height,
                  ),
                ),
                onChangeEnd: (_) => _queueDraftPush(),
              ),
              _RatioSlider(
                label: t.game_lookup_attached_width,
                value: _rect.width,
                min: 0.02,
                max: 1 - _rect.left,
                onChanged: (double value) => _setRect(
                  GalLookupNormalizedRectV1(
                    left: _rect.left,
                    top: _rect.top,
                    width: value,
                    height: _rect.height,
                  ),
                ),
                onChangeEnd: (_) => _queueDraftPush(),
              ),
              _RatioSlider(
                label: t.game_lookup_attached_height,
                value: _rect.height,
                min: 0.02,
                max: 1 - _rect.top,
                onChanged: (double value) => _setRect(
                  GalLookupNormalizedRectV1(
                    left: _rect.left,
                    top: _rect.top,
                    width: _rect.width,
                    height: value,
                  ),
                ),
                onChangeEnd: (_) => _queueDraftPush(),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey<String>(
                  'game-attached-calibration-font-family',
                ),
                controller: _fontController,
                decoration: InputDecoration(
                  labelText: t.game_lookup_attached_font_family,
                  border: const OutlineInputBorder(),
                ),
                onFieldSubmitted: (String value) {
                  _setLayout(_copyLayout(fontFamily: value.trim()));
                  _queueDraftPush();
                },
              ),
              const SizedBox(height: 8),
              _RatioSlider(
                label: t.game_lookup_attached_font_size,
                value: _layout.fontSizePerClientHeight,
                min: 0.01,
                max: 0.12,
                fractionDigits: 3,
                onChanged: (double value) =>
                    _setLayout(_copyLayout(fontSizePerClientHeight: value)),
                onChangeEnd: (_) => _queueDraftPush(),
              ),
              _RatioSlider(
                label: t.game_lookup_attached_letter_spacing,
                value: _layout.letterSpacingPerClientHeight.clamp(-0.02, 0.05),
                min: -0.02,
                max: 0.05,
                fractionDigits: 3,
                onChanged: (double value) =>
                    _setLayout(_copyLayout(letterSpacing: value)),
                onChangeEnd: (_) => _queueDraftPush(),
              ),
              _RatioSlider(
                label: t.game_lookup_attached_line_height,
                value: _layout.lineHeight.clamp(0.5, 2.5),
                min: 0.5,
                max: 2.5,
                fractionDigits: 2,
                onChanged: (double value) =>
                    _setLayout(_copyLayout(lineHeight: value)),
                onChangeEnd: (_) => _queueDraftPush(),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: <Widget>[
                  SizedBox(
                    width: 250,
                    child: DropdownButtonFormField<String>(
                      initialValue: _layout.textAlign,
                      decoration: InputDecoration(
                        labelText: t.game_lookup_attached_text_align,
                        border: const OutlineInputBorder(),
                      ),
                      items: <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                          value: 'left',
                          child: Text(t.game_lookup_attached_align_left),
                        ),
                        DropdownMenuItem<String>(
                          value: 'center',
                          child: Text(t.game_lookup_attached_align_center),
                        ),
                        DropdownMenuItem<String>(
                          value: 'right',
                          child: Text(t.game_lookup_attached_align_right),
                        ),
                      ],
                      onChanged: (String? value) {
                        if (value == null) return;
                        _setLayout(_copyLayout(textAlign: value));
                        _queueDraftPush();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 250,
                    child: DropdownButtonFormField<String>(
                      initialValue: _layout.verticalAlign,
                      decoration: InputDecoration(
                        labelText: t.game_lookup_attached_vertical_align,
                        border: const OutlineInputBorder(),
                      ),
                      items: <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                          value: 'top',
                          child: Text(t.game_lookup_attached_align_top),
                        ),
                        DropdownMenuItem<String>(
                          value: 'center',
                          child: Text(t.game_lookup_attached_align_center),
                        ),
                        DropdownMenuItem<String>(
                          value: 'bottom',
                          child: Text(t.game_lookup_attached_align_bottom),
                        ),
                      ],
                      onChanged: (String? value) {
                        if (value == null) return;
                        _setLayout(_copyLayout(verticalAlign: value));
                        _queueDraftPush();
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(t.game_lookup_attached_probes_hint),
              FushiListItem(
                key: const ValueKey<String>(
                  'game-attached-calibration-probe-start',
                ),
                density: FushiListDensity.compact,
                padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
                leading: Checkbox(
                  value: _startConfirmed,
                  onChanged: _startObserved ? _setStartConfirmed : null,
                ),
                onTap: _startObserved
                    ? () => _setStartConfirmed(!_startConfirmed)
                    : null,
                title: Text(
                  '${t.game_lookup_attached_probe_start}: '
                  '${widget.probePlan.startText}'
                  '${_startObserved ? '' : ' · ${t.game_lookup_attached_probe_waiting}'}',
                ),
              ),
              FushiListItem(
                key: const ValueKey<String>(
                  'game-attached-calibration-probe-middle',
                ),
                density: FushiListDensity.compact,
                padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
                leading: Checkbox(
                  value: _middleConfirmed,
                  onChanged: _middleObserved ? _setMiddleConfirmed : null,
                ),
                onTap: _middleObserved
                    ? () => _setMiddleConfirmed(!_middleConfirmed)
                    : null,
                title: Text(
                  '${t.game_lookup_attached_probe_middle}: '
                  '${widget.probePlan.middleText}'
                  '${_middleObserved ? '' : ' · ${t.game_lookup_attached_probe_waiting}'}',
                ),
              ),
              FushiListItem(
                key: const ValueKey<String>(
                  'game-attached-calibration-probe-end',
                ),
                density: FushiListDensity.compact,
                padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
                leading: Checkbox(
                  value: _endConfirmed,
                  onChanged: _endObserved ? _setEndConfirmed : null,
                ),
                onTap: _endObserved
                    ? () => _setEndConfirmed(!_endConfirmed)
                    : null,
                title: Text(
                  '${t.game_lookup_attached_probe_end}: '
                  '${widget.probePlan.endText}'
                  '${_endObserved ? '' : ' · ${t.game_lookup_attached_probe_waiting}'}',
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _committing
              ? null
              : () => Navigator.of(context).pop(false),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          key: const ValueKey<String>('game-attached-calibration-commit'),
          onPressed: _allConfirmed && !_committing ? _commit : null,
          child: _committing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(t.game_lookup_attached_calibration_commit),
        ),
      ],
    );
  }
}

class _RatioSlider extends StatelessWidget {
  const _RatioSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onChangeEnd,
    this.fractionDigits = 2,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final int fractionDigits;

  @override
  Widget build(BuildContext context) {
    final double safeMax = max <= min ? min + 0.001 : max;
    final double safeValue = value.clamp(min, safeMax);
    return Row(
      children: <Widget>[
        SizedBox(width: 150, child: Text(label)),
        Expanded(
          child: Slider(
            value: safeValue,
            min: min,
            max: safeMax,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            safeValue.toStringAsFixed(fractionDigits),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}
