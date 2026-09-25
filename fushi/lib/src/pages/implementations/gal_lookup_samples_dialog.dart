import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_draft.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_image_fit.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/pages/implementations/gal_lookup_calibration_canvas.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

bool _sameSourceViewport(WindowCaptureMetadata? a, WindowCaptureMetadata? b) {
  List<double>? normalizedViewport(WindowCaptureMetadata? value) {
    if (value == null || !value.usedPresentationCapture) {
      return <double>[0, 0, 1, 1];
    }
    if (!value.hasSourceClientMapping) return null;
    return <double>[
      (value.sourceViewportLeftPx - value.sourceClientLeftPx) /
          value.sourceClientWidthPx,
      (value.sourceViewportTopPx - value.sourceClientTopPx) /
          value.sourceClientHeightPx,
      value.sourceViewportWidthPx / value.sourceClientWidthPx,
      value.sourceViewportHeightPx / value.sourceClientHeightPx,
    ];
  }

  final List<double>? left = normalizedViewport(a);
  final List<double>? right = normalizedViewport(b);
  if (left == null || right == null) return false;
  for (int i = 0; i < left.length; i++) {
    if ((left[i] - right[i]).abs() > 0.000001) return false;
  }
  return true;
}

/// Screenshot notebook. It does not claim a geometry provider or arm game input.
/// Applying a draft returns it to the existing live calibration/commit flow.
class GalLookupSamplesDialog extends StatefulWidget {
  const GalLookupSamplesDialog({
    required this.exeSha256,
    required this.initialRect,
    required this.initialLayout,
    required this.capture,
    this.slot,
    this.onOpenNarrationCalibration,
    this.onOpenDialogueCalibration,
    this.nativeGeometryActive = false,
    this.store = const GalLookupCalibrationStore(),
    this.previewBuilder = GalLookupCalibrationPreviewChannel.build,
    this.imageFitter = fitGalCalibrationImages,
    super.key,
  });

  final String exeSha256;
  final GalLookupNormalizedRectV1 initialRect;
  final GalLookupTextLayoutV1 initialLayout;
  final Future<GalLookupCalibrationCapture> Function() capture;
  final GalLookupCalibrationSlotV1? slot;
  final Future<void> Function()? onOpenNarrationCalibration;
  final Future<void> Function()? onOpenDialogueCalibration;

  /// The engine currently supplies glyph positions, so this calibration is
  /// only a fallback for when that provider is unavailable.
  final bool nativeGeometryActive;
  final GalLookupCalibrationStore store;
  final GalCalibrationPreviewBuilder previewBuilder;
  final Future<GalCalibrationImageFit> Function(
    GalLookupCalibrationDraft draft, {
    GalCalibrationPreviewBuilder build,
  })
  imageFitter;

  @override
  State<GalLookupSamplesDialog> createState() => _GalLookupSamplesDialogState();
}

class _GalLookupSamplesDialogState extends State<GalLookupSamplesDialog> {
  late GalLookupNormalizedRectV1 _rect;
  late GalLookupNormalizedRectV1 _layoutRect;
  late GalLookupTextLayoutV1 _layout;
  GalLookupReferenceClientV1? _layoutReferenceClient;
  WindowCaptureMetadata? _layoutCaptureMetadata;
  List<GalCalibrationSample> _samples = [];
  List<GalCalibrationPreview> _previews = [];
  int _selected = 0;
  int? _hoverIndex;
  bool _busy = true;
  bool _dirty = false;
  bool _previewRunning = false;
  int _previewRevision = 0;
  bool _showAdvanced = false;
  bool _fitAllSamples = false;
  bool _manualGridEdit = false;
  bool _specialCharacterAdvancesEnabled = false;

  /// Grid advance and blue-box width when the current grid-width adjustment
  /// began. The slider derives the box from it; any other grid or box edit
  /// (canvas drag, auto-align, new selection) clears it.
  ({double advance, double width})? _advanceBaseline;
  late final TextEditingController _specialCharacterController;
  Timer? _autoSaveTimer;
  Future<bool>? _saveInFlight;
  int _changeRevision = 0;
  String? _message;
  bool _failed = false;
  String? _diagnosticDetail;
  GalCalibrationOcrModelInfo? _ocrModel;
  bool _ocrDownloadBusy = false;
  String _ocrDownloadFileName = '';
  int _ocrDownloadReceived = 0;
  int _ocrDownloadTotal = 0;

  bool get _canPreview => _layout.cellGrid != null;

  String get _title => switch (widget.slot) {
    GalLookupCalibrationSlotV1.dialogue => t.game_lookup_samples_dialogue,
    GalLookupCalibrationSlotV1.narration => t.game_lookup_samples_narration,
    null => t.game_lookup_samples_title,
  };

  String get _captureTooltip => widget.slot == null
      ? t.game_lookup_samples_capture
      : t.game_lookup_samples_capture_replace;

  GalLookupCalibrationDraft get _draft => GalLookupCalibrationDraft(
    rect: _layoutRect,
    searchRect: _rect,
    layout: _layout,
    samples: _samples,
    layoutReferenceClient: _layoutReferenceClient,
    layoutCaptureMetadata: _layoutCaptureMetadata,
    slot: widget.slot,
  );
  GalCalibrationSample? get _sample =>
      _samples.isEmpty ? null : _samples[_selected];
  GalCalibrationPreview? get _preview =>
      _previews.length == _samples.length && _previews.isNotEmpty
      ? _previews[_selected]
      : null;
  bool get _applyPreviewsAccepted {
    if (!_fitAllSamples) return _preview?.accepted == true;
    return _previews.length == _samples.length &&
        _previews.isNotEmpty &&
        _previews.every((GalCalibrationPreview preview) => preview.accepted);
  }

  @override
  void initState() {
    super.initState();
    _rect = widget.initialRect;
    _layoutRect = widget.initialRect;
    _layout = _withoutQuotedFilter(widget.initialLayout);
    _specialCharacterController = TextEditingController();
    _specialCharacterAdvancesEnabled = _layout.characterAdvances.isNotEmpty;
    unawaited(_load());
    unawaited(_refreshOcrModel());
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _specialCharacterController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final GalLookupCalibrationDraft? draft = await widget.store.load(
        widget.exeSha256,
        slot: widget.slot,
      );
      if (!mounted) return;
      if (draft != null) {
        _rect = draft.searchRect;
        _layoutRect = draft.rect;
        _layout = _withoutQuotedFilter(draft.layout);
        _advanceBaseline = null;
        _specialCharacterAdvancesEnabled = _layout.characterAdvances.isNotEmpty;
        _layoutReferenceClient = draft.layoutReferenceClient;
        _layoutCaptureMetadata = draft.layoutCaptureMetadata;
        _samples =
            (widget.slot == null
                    ? draft.samples
                    : draft.samples.take(
                        GalLookupCalibrationDraft.maxSamplesPerSlot,
                      ))
                .toList();
      }
    } catch (_) {
      _message = t.game_lookup_samples_load_failed;
      _failed = true;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    unawaited(_refresh());
  }

  Future<void> _refreshOcrModel() async {
    final GalCalibrationOcrModelStatusReader? reader =
        galCalibrationOcrModelStatus;
    if (reader == null) return;
    try {
      final GalCalibrationOcrModelInfo info = await reader();
      if (!mounted) return;
      setState(() => _ocrModel = info);
    } catch (_) {
      // The screenshot fitter remains available when the local OCR runtime is
      // unavailable; keep this optional status quiet rather than blocking it.
    }
  }

  Future<void> _downloadOcrModel() async {
    if (_busy || _ocrDownloadBusy) return;
    final GalCalibrationOcrModelDownloader? downloader =
        galCalibrationOcrModelDownloader;
    if (downloader == null) return;
    setState(() {
      _ocrDownloadBusy = true;
      _ocrDownloadFileName = '';
      _ocrDownloadReceived = 0;
      _ocrDownloadTotal = 0;
      _message = null;
      _diagnosticDetail = null;
      _failed = false;
    });
    try {
      await for (final GalCalibrationOcrDownloadProgress event
          in downloader()) {
        if (!mounted) return;
        setState(() {
          _ocrDownloadFileName = event.fileName;
          _ocrDownloadReceived = event.receivedBytes;
          _ocrDownloadTotal = event.totalBytes;
        });
      }
      await _refreshOcrModel();
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = t.manga_ocr_download_failed;
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _ocrDownloadBusy = false);
    }
  }

  Future<void> _refresh() async {
    ++_previewRevision;
    _previews = [];
    if (_previewRunning || !mounted) return;
    _previewRunning = true;
    try {
      while (mounted) {
        // A legacy draft is only a rough region until automatic measurement.
        // Its font preview says nothing about whether the screenshot fits.
        if (!_canPreview) break;
        final int revision = _previewRevision;
        final GalLookupCalibrationDraft draft = _draft;
        final List<GalCalibrationPreview> previews;
        try {
          previews = await Future.wait(
            draft.samples.map(
              (GalCalibrationSample sample) =>
                  !_sameSourceViewport(
                    _layoutCaptureMetadata,
                    sample.capture.captureMetadata,
                  )
                  ? Future<GalCalibrationPreview>.value(
                      const GalCalibrationPreview(
                        boxes: [],
                        reason: 'source_viewport_changed',
                      ),
                    )
                  : widget.previewBuilder(
                      text: sample.capture.sourceText,
                      client: sample.capture.referenceClient,
                      rect: draft.rect,
                      layout: draft.layout,
                    ),
            ),
          );
        } catch (_) {
          if (mounted && revision != _previewRevision) continue;
          rethrow;
        }
        if (!mounted) return;
        if (revision != _previewRevision) continue;
        setState(() => _previews = previews);
        break;
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = _manualGridEdit
              ? t.game_lookup_samples_unavailable
              : t.game_lookup_samples_auto_preview_failed;
          _failed = true;
        });
      }
    } finally {
      _previewRunning = false;
      if (mounted) setState(() {});
    }
  }

  void _changed() {
    ++_changeRevision;
    _dirty = true;
    _hoverIndex = null;
    _message = null;
    _diagnosticDetail = null;
    _failed = false;
    setState(() {});
    _scheduleAutoSave();
    unawaited(_refresh());
  }

  void _scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 350), () {
      _autoSaveTimer = null;
      unawaited(_save());
    });
  }

  Future<void> _capture() async {
    if (_busy) return;
    if (widget.slot == null &&
        _samples.length >= GalLookupCalibrationDraft.maxSamples) {
      setState(() => _message = t.game_lookup_samples_limit);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _diagnosticDetail = null;
      _failed = false;
    });
    try {
      final GalLookupCalibrationCapture capture = await widget.capture();
      if (!mounted) return;
      if (capture.exeSha256 != widget.exeSha256) {
        throw const GalLookupCalibrationCaptureException(
          GalLookupCalibrationCaptureFailure.sceneChanged,
        );
      }
      final GalCalibrationSample sample = GalCalibrationSample(
        capture: capture,
      );
      final List<GalCalibrationSample> samples = widget.slot == null
          ? <GalCalibrationSample>[..._samples, sample]
          : <GalCalibrationSample>[sample];
      final GalLookupCalibrationDraft next = GalLookupCalibrationDraft(
        rect: _layoutRect,
        searchRect: _rect,
        layout: _layout,
        samples: samples,
        slot: widget.slot,
      );
      if (!next.validFor(widget.exeSha256)) throw StateError('sample_limit');
      _samples = samples;
      _selected = _samples.length - 1;
      _changed();
      // New captures are persisted immediately so returning to the game never
      // risks losing the user's collected samples when the window is closed.
      await _save();
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = _captureFailureMessage(error);
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _captureFailureMessage(Object error) {
    if (error is! GalLookupCalibrationCaptureException) {
      return t.game_lookup_samples_capture_failed;
    }
    return switch (error.failure) {
      GalLookupCalibrationCaptureFailure.sceneChanged =>
        t.game_lookup_samples_capture_changed,
      GalLookupCalibrationCaptureFailure.surfaceMappingUnavailable =>
        t.game_lookup_samples_capture_surface_mapping,
      GalLookupCalibrationCaptureFailure.sourceNotReady ||
      GalLookupCalibrationCaptureFailure.invalidSource =>
        t.game_lookup_samples_capture_source,
      GalLookupCalibrationCaptureFailure.surfaceNotReady =>
        t.game_lookup_samples_capture_surface_not_ready,
      GalLookupCalibrationCaptureFailure.rubyUnsupported =>
        t.game_lookup_samples_capture_unsupported,
      GalLookupCalibrationCaptureFailure.overlayHideFailed ||
      GalLookupCalibrationCaptureFailure.suppressionUnavailable ||
      GalLookupCalibrationCaptureFailure.restoreFailed =>
        t.game_lookup_samples_capture_overlay,
      GalLookupCalibrationCaptureFailure.windowCaptureFailed =>
        t.game_lookup_samples_capture_unavailable,
      GalLookupCalibrationCaptureFailure.clientMappingUnavailable ||
      GalLookupCalibrationCaptureFailure.imageTooLarge ||
      GalLookupCalibrationCaptureFailure.imageDimensionsInvalid =>
        t.game_lookup_samples_capture_window,
      _ => t.game_lookup_samples_capture_failed,
    };
  }

  Future<bool> _save({bool announce = false}) {
    final Future<bool>? inFlight = _saveInFlight;
    if (inFlight != null) return inFlight;
    final Future<bool> saving = _saveNow(announce: announce);
    late final Future<bool> tracked;
    tracked = saving.whenComplete(() {
      if (identical(_saveInFlight, tracked)) _saveInFlight = null;
    });
    _saveInFlight = tracked;
    return tracked;
  }

  Future<bool> _saveNow({required bool announce}) async {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    final int revision = _changeRevision;
    final GalLookupCalibrationDraft draft = _draft;
    try {
      await widget.store.save(widget.exeSha256, draft, slot: widget.slot);
      if (mounted && revision == _changeRevision) {
        setState(() {
          _dirty = false;
          if (announce) _message = t.game_lookup_samples_saved;
          _failed = false;
        });
      }
      return true;
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = t.game_lookup_samples_save_failed;
          _failed = true;
        });
      }
      return false;
    }
  }

  Future<void> _switchCalibrationSlot(Future<void> Function()? onSwitch) async {
    if (_busy || onSwitch == null) return;
    setState(() => _busy = true);
    bool saved = true;
    while (saved && _dirty) {
      saved = await _save();
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved && !_dirty) await onSwitch();
  }

  Future<void> _finish({bool apply = false}) async {
    if (_busy || (apply && (!_canPreview || _samples.isEmpty))) return;
    setState(() => _busy = true);
    if (apply) {
      bool valid = false;
      try {
        final List<GalCalibrationSample> samplesToValidate = _fitAllSamples
            ? _samples
            : <GalCalibrationSample>[_samples[_selected]];
        final List<GalCalibrationPreview> previews = await Future.wait(
          samplesToValidate.map(
            (GalCalibrationSample sample) => widget.previewBuilder(
              text: sample.capture.sourceText,
              client: sample.capture.referenceClient,
              rect: _layoutRect,
              layout: _layout,
            ),
          ),
        );
        valid =
            samplesToValidate.every(
              (GalCalibrationSample sample) => _sameSourceViewport(
                _layoutCaptureMetadata,
                sample.capture.captureMetadata,
              ),
            ) &&
            previews.isNotEmpty &&
            previews.every((GalCalibrationPreview p) => p.accepted);
      } catch (_) {
        valid = false;
      }
      if (!mounted) return;
      if (!valid) {
        setState(() {
          _busy = false;
          _message = _manualGridEdit
              ? t.game_lookup_samples_unavailable
              : t.game_lookup_samples_auto_preview_failed;
          _failed = true;
        });
        return;
      }
    }
    final bool saved = !_dirty || await _save();
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved) Navigator.of(context).pop(apply ? _draft : null);
  }

  Future<void> _fitImage() async {
    if (_busy || _samples.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
      _diagnosticDetail = null;
      _failed = false;
    });
    try {
      // The simple path measures the selected complete screenshot. Advanced
      // mode can opt back into the original joint fit across all samples.
      final GalCalibrationSample selected = _samples[_selected];
      final List<GalCalibrationSample> fittingSamples = _fitAllSamples
          ? _samples
          : <GalCalibrationSample>[
              selected.validation
                  ? selected.copyWith(validation: false)
                  : selected,
            ];
      final GalLookupCalibrationDraft input = GalLookupCalibrationDraft(
        rect: _layoutRect,
        searchRect: _rect,
        layout: _layout,
        samples: fittingSamples,
        slot: widget.slot,
      );
      // Cropped screenshots have different normalized origins. Joint fitting
      // is meaningful only when every image has the same source viewport.
      final WindowCaptureMetadata? fittingMetadata =
          fittingSamples.first.capture.captureMetadata;
      if (_fitAllSamples &&
          fittingSamples.any(
            (GalCalibrationSample sample) => !_sameSourceViewport(
              fittingMetadata,
              sample.capture.captureMetadata,
            ),
          )) {
        setState(() {
          _message = t.game_lookup_samples_auto_inconsistent;
          _failed = true;
        });
        return;
      }
      final GalCalibrationImageFit result = await widget.imageFitter(
        input,
        build: widget.previewBuilder,
      );
      if (!mounted) return;
      if (result.draft == null) {
        setState(() {
          _failed = true;
          final String rawReason = result.reason ?? 'unknown';
          final String detail = result.detail?.trim() ?? '';
          _diagnosticDetail = detail.isEmpty
              ? rawReason
              : '$rawReason: $detail';
          final int? failedSampleIndex = result.sampleIndex == null
              ? null
              : _fitAllSamples
              ? result.sampleIndex
              : _selected;
          if (failedSampleIndex != null &&
              failedSampleIndex >= 0 &&
              failedSampleIndex < _samples.length) {
            _selected = failedSampleIndex;
            _hoverIndex = null;
          }
          final String reason = switch (result.reason) {
            'multiline_required' => t.game_lookup_samples_auto_multiline,
            'ocr_line_spacing_missing' || 'line_spacing_insufficient' =>
              t.game_lookup_samples_auto_line_spacing_missing,
            'ocr_text_alignment_failed' || 'text_correspondence_insufficient' =>
              t.game_lookup_samples_auto_text_alignment_failed,
            'ocr_text_alignment_weak' || 'ocr_anchor_insufficient' =>
              t.game_lookup_samples_auto_text_alignment_weak,
            'ocr_geometry_weak' || 'geometry_evidence_insufficient' =>
              t.game_lookup_samples_auto_geometry_weak,
            'ocr_indent_ambiguous' =>
              t.game_lookup_samples_auto_indent_ambiguous,
            'ocr_line_wrap_inconsistent' =>
              t.game_lookup_samples_auto_line_wrap_inconsistent,
            'ocr_character_positions_inconsistent' || 'ocr_geometry_conflict' =>
              t.game_lookup_samples_auto_character_positions_inconsistent,
            'ocr_geometry_out_of_bounds' || 'selection_out_of_bounds' =>
              t.game_lookup_samples_auto_geometry_out_of_bounds,
            'ocr_preview_unavailable' =>
              t.game_lookup_samples_auto_preview_unavailable,
            'ocr_preview_text_overflow' =>
              t.game_lookup_samples_auto_preview_text_overflow,
            'unsupported_text' => t.game_lookup_samples_auto_unsupported,
            'text_rows_not_found' ||
            'ocr_lines_not_found' => t.game_lookup_samples_auto_rows_missing,
            'inconsistent_samples' ||
            'ocr_geometry_inconsistent' ||
            'ocr_confidence_low' => t.game_lookup_samples_auto_inconsistent,
            'preview_rejected' => t.game_lookup_samples_auto_preview_failed,
            _ => t.game_lookup_samples_auto_failed,
          };
          _message = failedSampleIndex == null
              ? reason
              : t.game_lookup_samples_auto_sample_failed(
                  sample: '${failedSampleIndex + 1}',
                  reason: reason,
                );
        });
      } else {
        _layoutRect = result.draft!.rect;
        _layout = result.draft!.layout;
        _advanceBaseline = null;
        _layoutReferenceClient =
            result.draft!.layoutReferenceClient ??
            fittingSamples.first.capture.referenceClient;
        _layoutCaptureMetadata =
            result.draft!.layoutCaptureMetadata ?? fittingMetadata;
        _diagnosticDetail = null;
        _manualGridEdit = false;
        _changed();
        setState(() => _message = t.game_lookup_samples_auto_success);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = t.game_lookup_samples_auto_failed;
          _diagnosticDetail = 'unknown';
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setLayoutRect(GalLookupNormalizedRectV1 rect) {
    if (!rect.isValid) return;
    _advanceBaseline = null;
    _layoutRect = rect;
    _changed();
  }

  void _setGrid(GalLookupCellGridV1 grid) {
    _advanceBaseline = null;
    _applyGrid(grid);
  }

  void _applyGrid(GalLookupCellGridV1 grid) {
    if (!grid.isValid) return;
    _layout = GalLookupTextLayoutV1(
      fontFamily: _layout.fontFamily,
      fontSizePerClientHeight: _layout.fontSizePerClientHeight,
      letterSpacingPerClientHeight: _layout.letterSpacingPerClientHeight,
      lineHeight: _layout.lineHeight,
      textAlign: _layout.textAlign,
      verticalAlign: _layout.verticalAlign,
      paddingPerClientHeight: _layout.paddingPerClientHeight,
      cellGrid: grid,
      quotedTextOnly: _layout.quotedTextOnly,
      punctuationVisualBounds: _layout.punctuationVisualBounds,
      characterAdvances: _layout.characterAdvances,
    );
    _changed();
  }

  // The calibration-only 「」 filter is superseded by the Hook text processing
  // rules (keep 「」 text, regex replace), which already shape the text the
  // attached surface receives. A saved profile keeps its stored value until it
  // is recalibrated here.
  static GalLookupTextLayoutV1 _withoutQuotedFilter(
    GalLookupTextLayoutV1 layout,
  ) => layout.quotedTextOnly
      ? copyGalCalibrationLayout(layout, quotedTextOnly: false)
      : layout;

  void _setContinuationIndent(double value) {
    final GalLookupCellGridV1? grid = _layout.cellGrid;
    if (grid == null || !value.isFinite) return;
    final double maximumIndent = math.min(grid.columns - 1, 8).toDouble();
    final double indent = value.clamp(-1.0, maximumIndent).toDouble();
    final GalLookupCellGridV1 next = grid.copyWith(
      // Keep the legacy second field synchronized so old profile files and
      // native payloads still round-trip while one UI value controls all text.
      continuationIndent: indent,
      quotedContinuationIndent: indent,
    );
    _setGrid(next);
  }

  /// Half-width of the grid-width slider around its baseline, as a fraction of
  /// the cell height. The full 15%-200% range made one pixel of travel worth
  /// several tenths of a percent.
  static const double _advanceSliderSpan = 0.15;

  /// One button/keyboard step of the grid-width control (0.1 %).
  static const double _advanceStep = 0.001;

  GalLookupReferenceClientV1? get _gridClient =>
      _layoutReferenceClient ?? _sample?.capture.referenceClient;

  /// Normalized blue-box width gained per unit of grid advance.
  double _boxWidthPerAdvance(
    GalLookupCellGridV1 grid,
    GalLookupReferenceClientV1 client,
  ) =>
      (grid.effectiveLineWidthInCells + (grid.hangingPunctuation ? 1 : 0)) *
      client.heightPx /
      client.widthPx;

  ({double advance, double width}) _advanceBaselineFor(
    GalLookupCellGridV1 grid,
  ) =>
      _advanceBaseline ??
      (advance: grid.advancePerClientHeight, width: _layoutRect.width);

  /// Slider bounds as advance/cell-height ratios: a narrow span around the
  /// baseline, never letting the box leave the screenshot or collapse.
  ({double min, double max}) _gridAdvanceRange(GalLookupCellGridV1 grid) {
    final double cell = grid.cellHeightPerClientHeight;
    final ({double advance, double width}) base = _advanceBaselineFor(grid);
    final double baseRatio = base.advance / cell;
    double minimum = math.max(0.001 / cell, baseRatio - _advanceSliderSpan);
    double maximum = math.min(0.25 / cell, baseRatio + _advanceSliderSpan);
    final GalLookupReferenceClientV1? client = _gridClient;
    if (client != null) {
      final double perAdvance = _boxWidthPerAdvance(grid, client);
      final double minimumWidth = math.min(
        base.width,
        math.max(0.001, 8 / client.widthPx),
      );
      maximum = math.min(
        maximum,
        (base.advance + (1 - _layoutRect.left - base.width) / perAdvance) /
            cell,
      );
      minimum = math.max(
        minimum,
        (base.advance - (base.width - minimumWidth) / perAdvance) / cell,
      );
    }
    final double current = grid.advancePerClientHeight / cell;
    return (min: math.min(minimum, current), max: math.max(maximum, current));
  }

  void _setGridAdvanceRatio(double ratio) {
    final GalLookupCellGridV1? grid = _layout.cellGrid;
    if (grid == null || !ratio.isFinite) return;
    final ({double min, double max}) range = _gridAdvanceRange(grid);
    final double nextAdvance =
        (grid.cellHeightPerClientHeight * ratio.clamp(range.min, range.max))
            .clamp(0.001, 0.25)
            .toDouble();
    if ((nextAdvance - grid.advancePerClientHeight).abs() < 0.0000001) {
      return;
    }
    // Derive the box from the baseline instead of accumulating deltas, so a
    // value that returns to where it started restores the exact same box.
    final ({double advance, double width}) base = _advanceBaseline ??=
        _advanceBaselineFor(grid);
    final GalLookupReferenceClientV1? client = _gridClient;
    if (client != null) {
      final double width =
          base.width +
          (nextAdvance - base.advance) * _boxWidthPerAdvance(grid, client);
      _layoutRect = GalLookupNormalizedRectV1(
        left: _layoutRect.left,
        top: _layoutRect.top,
        width: width,
        height: _layoutRect.height,
      );
    }
    _applyGrid(grid.copyWith(advancePerClientHeight: nextAdvance));
  }

  void _setCharacterAdvances(List<GalLookupCharacterAdvanceV1> advances) {
    if (advances.length > GalLookupCharacterAdvanceV1.maxEntriesPerLayout) {
      return;
    }
    final List<GalLookupCharacterAdvanceV1> next =
        List<GalLookupCharacterAdvanceV1>.unmodifiable(advances);
    _layout = GalLookupTextLayoutV1(
      fontFamily: _layout.fontFamily,
      fontSizePerClientHeight: _layout.fontSizePerClientHeight,
      letterSpacingPerClientHeight: _layout.letterSpacingPerClientHeight,
      lineHeight: _layout.lineHeight,
      textAlign: _layout.textAlign,
      verticalAlign: _layout.verticalAlign,
      paddingPerClientHeight: _layout.paddingPerClientHeight,
      cellGrid: _layout.cellGrid,
      quotedTextOnly: _layout.quotedTextOnly,
      punctuationVisualBounds: _layout.punctuationVisualBounds,
      characterAdvances: next,
    );
    _changed();
  }

  void _setCharacterAdvance(int codePoint, double advanceRatio) {
    final List<GalLookupCharacterAdvanceV1> next = _layout.characterAdvances
        .map(
          (GalLookupCharacterAdvanceV1 value) => value.codePoint == codePoint
              ? GalLookupCharacterAdvanceV1(
                  codePoint: codePoint,
                  advanceRatio: advanceRatio,
                )
              : value,
        )
        .toList();
    _setCharacterAdvances(next);
  }

  void _addSpecialCharacters() {
    if (_busy) return;
    final Set<int> existing = _layout.characterAdvances
        .map((GalLookupCharacterAdvanceV1 value) => value.codePoint)
        .toSet();
    final List<GalLookupCharacterAdvanceV1> next =
        List<GalLookupCharacterAdvanceV1>.of(_layout.characterAdvances);
    for (final int codePoint in _specialCharacterController.text.runes) {
      if (existing.contains(codePoint) ||
          next.length >= GalLookupCharacterAdvanceV1.maxEntriesPerLayout) {
        continue;
      }
      final GalLookupCharacterAdvanceV1 value = GalLookupCharacterAdvanceV1(
        codePoint: codePoint,
        // Punctuation is commonly narrower than a normal full-width cell;
        // the slider remains available for games with a different ratio.
        advanceRatio: 0.75,
      );
      if (!value.isValid) continue;
      existing.add(codePoint);
      next.add(value);
    }
    if (next.length == _layout.characterAdvances.length) return;
    _specialCharacterAdvancesEnabled = true;
    _specialCharacterController.clear();
    _setCharacterAdvances(next);
  }

  void _updateSpecialCharacterAdvance(int codePoint, double ratio) {
    final List<GalLookupCharacterAdvanceV1> next = _layout.characterAdvances
        .map(
          (GalLookupCharacterAdvanceV1 value) => value.codePoint == codePoint
              ? GalLookupCharacterAdvanceV1(
                  codePoint: codePoint,
                  advanceRatio: ratio,
                )
              : value,
        )
        .toList();
    _setCharacterAdvances(next);
  }

  void _removeSpecialCharacter(int codePoint) {
    final List<GalLookupCharacterAdvanceV1> next = _layout.characterAdvances
        .where(
          (GalLookupCharacterAdvanceV1 value) => value.codePoint != codePoint,
        )
        .toList();
    _specialCharacterAdvancesEnabled = next.isNotEmpty;
    _setCharacterAdvances(next);
  }

  void _toggleSpecialCharacterAdvances(bool enabled) {
    if (!enabled) {
      _specialCharacterAdvancesEnabled = false;
      if (_layout.characterAdvances.isNotEmpty) {
        _setCharacterAdvances(const <GalLookupCharacterAdvanceV1>[]);
      } else {
        setState(() {});
      }
      return;
    }
    setState(() => _specialCharacterAdvancesEnabled = true);
  }

  void _removeSample() {
    if (_busy || _samples.isEmpty) return;
    _samples.removeAt(_selected);
    _selected = _samples.isEmpty
        ? 0
        : math.min(_selected, _samples.length - 1).toInt();
    _hoverIndex = null;
    _manualGridEdit = false;
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy && !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop && !_busy) unawaited(_finish());
      },
      child: Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: _canSwitchSlot ? _slotSwitch() : Text(_title),
            actions: [
              IconButton(
                onPressed: _busy ? null : _capture,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                tooltip: _captureTooltip,
              ),
              IconButton(
                key: const ValueKey<String>('calibration-remove-sample'),
                onPressed: _busy || _sample == null ? null : _removeSample,
                icon: const Icon(Icons.delete_outline),
                tooltip: t.game_lookup_samples_remove,
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed:
                    _busy ||
                        !_canPreview ||
                        _samples.isEmpty ||
                        _previewRunning ||
                        !_applyPreviewsAccepted
                    ? null
                    : () => _finish(apply: true),
                icon: const Icon(Icons.sports_esports_outlined),
                label: Text(t.game_lookup_samples_apply),
              ),
              const SizedBox(width: 4),
              CloseButton(onPressed: _busy ? null : () => _finish()),
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              if (_busy || _previewRunning) const LinearProgressIndicator(),
              _statusBanner(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder:
                            (
                              BuildContext context,
                              BoxConstraints constraints,
                            ) => Column(
                              children: [
                                if (_samples.length > 1)
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxHeight: constraints.maxHeight * 0.2,
                                    ),
                                    child: SingleChildScrollView(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        8,
                                        16,
                                        0,
                                      ),
                                      child: Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: [
                                          for (
                                            int i = 0;
                                            i < _samples.length;
                                            i++
                                          )
                                            ChoiceChip(
                                              label: Text('${i + 1}'),
                                              selected: i == _selected,
                                              showCheckmark: false,
                                              onSelected: _busy
                                                  ? null
                                                  : (_) => setState(() {
                                                      _selected = i;
                                                      _hoverIndex = null;
                                                    }),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      12,
                                      16,
                                      8,
                                    ),
                                    child: _image(),
                                  ),
                                ),
                                if (_sample != null) _sampleControls(),
                              ],
                            ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 340,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        child: _controls(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBanner() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final Color foreground = _failed
        ? colors.onErrorContainer
        : colors.onSurfaceVariant;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _failed
            ? colors.errorContainer
            : FushiDesignTokens.of(
                context,
              ).surfaces.overlay.withValues(alpha: 0.5),
        borderRadius: FushiBorderRadius.card,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            _failed ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: foreground,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  _message ??
                      (_canPreview
                          ? t.game_lookup_samples_auto_hint
                          : t.game_lookup_samples_auto_pending),
                  style: text.bodyMedium?.copyWith(color: foreground),
                ),
                if (_failed && _diagnosticDetail != null) ...<Widget>[
                  const SizedBox(height: 4),
                  SelectableText(
                    t.game_lookup_samples_diagnostic(
                      reason: _diagnosticDetail!,
                      detail: '',
                    ),
                    style: text.bodySmall?.copyWith(color: foreground),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptySamples() {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: FushiBorderRadius.control,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.add_photo_alternate_outlined,
                size: 48,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(t.game_lookup_samples_empty, style: text.titleMedium),
              const SizedBox(height: 6),
              Text(
                t.game_lookup_samples_hint,
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                key: const ValueKey<String>('calibration-empty-capture'),
                onPressed: _busy ? null : _capture,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(t.game_lookup_samples_capture),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepHeader(int step, String title) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$step',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: colors.onPrimaryContainer),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
      ],
    );
  }

  Widget _secondaryText(String value) => Text(
    value,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  bool get _canSwitchSlot =>
      widget.slot != null &&
      (widget.onOpenNarrationCalibration != null ||
          widget.onOpenDialogueCalibration != null);

  /// Replaces the title when the other calibration slot can be opened.
  Widget _slotSwitch() {
    final GalLookupCalibrationSlotV1 slot = widget.slot!;
    final Future<void> Function()? toNarration =
        widget.onOpenNarrationCalibration;
    final Future<void> Function()? toDialogue =
        widget.onOpenDialogueCalibration;
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<GalLookupCalibrationSlotV1>(
        showSelectedIcon: false,
        segments: <ButtonSegment<GalLookupCalibrationSlotV1>>[
          ButtonSegment<GalLookupCalibrationSlotV1>(
            value: GalLookupCalibrationSlotV1.dialogue,
            icon: const Icon(Icons.format_quote_outlined),
            enabled:
                slot == GalLookupCalibrationSlotV1.dialogue ||
                toDialogue != null,
            label: Text(
              t.game_lookup_samples_dialogue,
              key: const ValueKey<String>('calibration-dialogue-settings'),
            ),
          ),
          ButtonSegment<GalLookupCalibrationSlotV1>(
            value: GalLookupCalibrationSlotV1.narration,
            icon: const Icon(Icons.subject_outlined),
            enabled:
                slot == GalLookupCalibrationSlotV1.narration ||
                toNarration != null,
            label: Text(
              t.game_lookup_samples_narration,
              key: const ValueKey<String>('calibration-narration-settings'),
            ),
          ),
        ],
        selected: <GalLookupCalibrationSlotV1>{slot},
        onSelectionChanged: _busy
            ? null
            : (Set<GalLookupCalibrationSlotV1> next) {
                final Future<void> Function()? open =
                    next.first == GalLookupCalibrationSlotV1.narration
                    ? toNarration
                    : toDialogue;
                if (next.first != slot && open != null) {
                  unawaited(_switchCalibrationSlot(open));
                }
              },
      ),
    );
  }

  Widget _image() {
    final GalCalibrationSample? sample = _sample;
    if (sample == null) return _emptySamples();
    return GalLookupCalibrationCanvas(
      key: ValueKey<Object>(sample.capture),
      pngBytes: sample.capture.pngBytes,
      client: sample.capture.referenceClient,
      rect: _rect,
      layoutRect: _layoutRect,
      grid: _layout.cellGrid,
      gridEditing: _manualGridEdit,
      text: sample.capture.sourceText,
      characterAdvances: _layout.characterAdvances,
      boxes: _preview?.boxes ?? [],
      anchors: const {},
      selectedIndex: null,
      mode: GalCalibrationEditMode.region,
      opacity: 0.55,
      enabled: !_busy,
      onRectChanged: (GalLookupNormalizedRectV1 rect) {
        _setSearchRect(rect);
      },
      onLayoutRectChanged: _setLayoutRect,
      onGridChanged: _setGrid,
      onCharacterAdvanceChanged: _setCharacterAdvance,
      onAnchorChanged: (_, __) {},
      onIndexSelected: (_) {},
      onHover: (int? index) {
        if (_hoverIndex != index) setState(() => _hoverIndex = index);
      },
    );
  }

  Widget _sampleControls() {
    final GalCalibrationSample sample = _sample!;
    final GalCalibrationBox? hovered = _hoverIndex == null
        ? null
        : _preview?.boxForIndex(_hoverIndex!);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  !_canPreview
                      ? t.game_lookup_samples_region_hint
                      : hovered == null
                      ? t.game_lookup_samples_hover
                      : '「${sample.capture.sourceText.substring(hovered.charIndex, hovered.charIndex + hovered.charLength)}」 · ${hovered.charIndex + 1}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 12),
              _secondaryText(
                '${sample.capture.referenceClient.widthPx} × ${sample.capture.referenceClient.heightPx}',
              ),
            ],
          ),
          if (_preview != null && !_preview!.accepted)
            Text(
              t.game_lookup_samples_auto_sample_failed(
                sample: '${_selected + 1}',
                reason: t.game_lookup_samples_auto_preview_failed,
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }

  Widget _specialCharacterControls() {
    final List<GalLookupCharacterAdvanceV1> advances =
        _layout.characterAdvances;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SwitchListTile.adaptive(
          key: const ValueKey<String>('calibration-special-character-width'),
          contentPadding: EdgeInsets.zero,
          title: Text(t.game_lookup_samples_special_chars_title),
          subtitle: Text(t.game_lookup_samples_special_chars_hint),
          value: _specialCharacterAdvancesEnabled,
          onChanged: _busy ? null : _toggleSpecialCharacterAdvances,
        ),
        if (_specialCharacterAdvancesEnabled) ...<Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const ValueKey<String>(
                    'calibration-special-character-input',
                  ),
                  controller: _specialCharacterController,
                  enabled: !_busy,
                  maxLength: 32,
                  decoration: InputDecoration(
                    labelText: t.game_lookup_samples_special_chars_input,
                    hintText: t.game_lookup_samples_special_chars_input_hint,
                    counterText: '',
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addSpecialCharacters(),
                ),
              ),
              IconButton(
                key: const ValueKey<String>(
                  'calibration-special-character-add',
                ),
                tooltip: t.game_lookup_samples_special_chars_add,
                onPressed: _busy ? null : _addSpecialCharacters,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          for (final GalLookupCharacterAdvanceV1 advance in advances)
            Row(
              key: ValueKey<String>(
                'calibration-special-character-${advance.codePoint}',
              ),
              children: <Widget>[
                SizedBox(
                  width: 32,
                  child: Text(
                    advance.character,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: Slider(
                    min: GalLookupCharacterAdvanceV1.minAdvanceRatio,
                    max: GalLookupCharacterAdvanceV1.maxAdvanceRatio,
                    divisions: 37,
                    value: advance.advanceRatio,
                    label: '${(advance.advanceRatio * 100).round()}%',
                    onChanged: _busy
                        ? null
                        : (double value) => _updateSpecialCharacterAdvance(
                            advance.codePoint,
                            value,
                          ),
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: Text('${(advance.advanceRatio * 100).round()}%'),
                ),
                IconButton(
                  key: ValueKey<String>(
                    'calibration-special-character-remove-${advance.codePoint}',
                  ),
                  tooltip: t.game_lookup_samples_special_chars_remove,
                  onPressed: _busy
                      ? null
                      : () => _removeSpecialCharacter(advance.codePoint),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
        ],
      ],
    );
  }

  Widget _gridAdvanceControl(GalLookupCellGridV1 grid) {
    final ({double min, double max}) range = _gridAdvanceRange(grid);
    final double value =
        (grid.advancePerClientHeight / grid.cellHeightPerClientHeight)
            .clamp(range.min, range.max)
            .toDouble();
    // 0.1 % per slider step, keyboard arrow and button press.
    final int divisions = ((range.max - range.min) / _advanceStep)
        .round()
        .clamp(1, 4000);
    final String formattedValue = '${(value * 100).toStringAsFixed(1)}%';
    // Snap button steps to the 0.1 % grid so repeated presses stay exact.
    double stepped(int direction) =>
        ((value / _advanceStep).round() + direction) * _advanceStep;
    return Column(
      key: const ValueKey<String>('calibration-grid-advance'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(t.game_lookup_samples_grid_advance)),
            IconButton(
              key: const ValueKey<String>('calibration-grid-advance-decrease'),
              tooltip: t.game_lookup_samples_grid_advance_decrease,
              onPressed: _busy || value <= range.min
                  ? null
                  : () => _setGridAdvanceRatio(stepped(-1)),
              icon: const Icon(Icons.remove),
            ),
            SizedBox(
              width: 56,
              child: Text(formattedValue, textAlign: TextAlign.center),
            ),
            IconButton(
              key: const ValueKey<String>('calibration-grid-advance-increase'),
              tooltip: t.game_lookup_samples_grid_advance_increase,
              onPressed: _busy || value >= range.max
                  ? null
                  : () => _setGridAdvanceRatio(stepped(1)),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        Slider(
          key: const ValueKey<String>('calibration-grid-advance-slider'),
          min: range.min,
          max: range.max,
          divisions: divisions,
          value: value,
          label: formattedValue,
          onChanged: _busy ? null : _setGridAdvanceRatio,
        ),
      ],
    );
  }

  String _formatContinuationIndent(double value) {
    final String compact = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value
              .toStringAsFixed(2)
              .replaceFirst(RegExp(r'0+$'), '')
              .replaceFirst(RegExp(r'\.$'), '');
    final String signed = value > 0 ? '+$compact' : compact;
    return '$signed ${t.game_lookup_samples_continuation_cells}';
  }

  Widget _continuationIndentControl({
    required String keyName,
    required String label,
    required double value,
    required double maximum,
    required ValueChanged<double>? onChanged,
  }) {
    final int divisions = ((maximum + 1) * 20).round().clamp(1, 200);
    return Column(
      key: ValueKey<String>('calibration-$keyName'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label)),
            Text(
              _formatContinuationIndent(value),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        Slider(
          key: ValueKey<String>('calibration-$keyName-slider'),
          min: -1,
          max: maximum,
          divisions: divisions,
          value: value.clamp(-1.0, maximum),
          label: _formatContinuationIndent(value),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _continuationIndentControls(GalLookupCellGridV1 grid) {
    final double maximumIndent = math.min(grid.columns - 1, 8).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 12),
        Text(
          t.game_lookup_samples_continuation_title,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        _secondaryText(t.game_lookup_samples_continuation_hint),
        const SizedBox(height: 8),
        _continuationIndentControl(
          keyName: 'continuation-indent',
          label: t.game_lookup_samples_continuation_label,
          value: grid.continuationIndent,
          maximum: maximumIndent,
          onChanged: _busy ? null : _setContinuationIndent,
        ),
      ],
    );
  }

  Widget _controls() {
    final GalLookupCellGridV1? grid = _layout.cellGrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.nativeGeometryActive) ...<Widget>[
          Row(
            key: const ValueKey<String>('calibration-native-fallback'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.info_outline,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  t.game_lookup_samples_native_fallback_hint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (_canSwitchSlot) ...<Widget>[
          _secondaryText(t.game_lookup_samples_narration_hint),
          const SizedBox(height: 20),
        ],
        _stepHeader(1, t.game_lookup_samples_search_title),
        const SizedBox(height: 6),
        _secondaryText(t.game_lookup_samples_search_hint),
        const SizedBox(height: 20),
        _stepHeader(2, t.game_lookup_samples_auto_align),
        const SizedBox(height: 6),
        _secondaryText(
          _fitAllSamples
              ? t.game_lookup_samples_auto_all_hint
              : t.game_lookup_samples_auto_current_hint,
        ),
        const SizedBox(height: 8),
        if (galCalibrationOcrModelStatus != null) ...[
          if (_ocrModel?.ready == true)
            Row(
              children: <Widget>[
                Icon(
                  Icons.check_circle_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(child: _secondaryText(t.manga_ocr_model_status_ready)),
              ],
            )
          else ...[
            _secondaryText(
              '${t.manga_ocr_model_status_missing} · '
              '${t.manga_ocr_model_download_size(size: '31 MB')}。'
              '${t.manga_ocr_engine_local_onnx_desc}',
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              key: const ValueKey<String>('calibration-ocr-download'),
              onPressed: _busy || _ocrDownloadBusy ? null : _downloadOcrModel,
              icon: const Icon(Icons.download),
              label: Text(
                _ocrDownloadBusy
                    ? t.manga_ocr_downloading_file(file: _ocrDownloadFileName)
                    : t.manga_ocr_download,
              ),
            ),
            if (_ocrDownloadBusy && _ocrDownloadTotal > 0)
              LinearProgressIndicator(
                value: (_ocrDownloadReceived / _ocrDownloadTotal).clamp(
                  0.0,
                  1.0,
                ),
              ),
          ],
          const SizedBox(height: 8),
        ],
        FilledButton.icon(
          key: const ValueKey<String>('calibration-auto-align'),
          onPressed: _busy || _ocrDownloadBusy || _samples.isEmpty
              ? null
              : _fitImage,
          icon: const Icon(Icons.auto_fix_high),
          label: Text(
            _fitAllSamples
                ? t.game_lookup_samples_auto_align_all
                : t.game_lookup_samples_auto_align_current,
          ),
        ),
        const SizedBox(height: 16),
        const Divider(height: 1),
        ExpansionTile(
          key: const ValueKey<String>('calibration-advanced'),
          initiallyExpanded: _showAdvanced,
          tilePadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text(
            t.game_lookup_samples_advanced,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          subtitle: _secondaryText(t.game_lookup_samples_advanced_hint),
          onExpansionChanged: (bool value) =>
              setState(() => _showAdvanced = value),
          children: [
            if (_samples.length > 1)
              SwitchListTile.adaptive(
                key: const ValueKey<String>('calibration-fit-all'),
                contentPadding: EdgeInsets.zero,
                title: Text(t.game_lookup_samples_fit_all),
                subtitle: Text(t.game_lookup_samples_fit_all_hint),
                value: _fitAllSamples,
                onChanged: _busy
                    ? null
                    : (bool value) => setState(() => _fitAllSamples = value),
              ),
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                t.game_lookup_samples_layout_title,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (grid != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  t.game_lookup_samples_auto_grid,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey<String>('calibration-manual-layout'),
                onPressed: _busy || grid == null
                    ? null
                    : () => setState(() => _manualGridEdit = !_manualGridEdit),
                icon: Icon(_manualGridEdit ? Icons.done : Icons.tune),
                label: Text(t.game_lookup_samples_manual_layout),
              ),
            ),
            if (grid != null && _manualGridEdit) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                t.game_lookup_samples_grid_edit_hint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (grid != null && _manualGridEdit) ...<Widget>[
              _gridAdvanceControl(grid),
              _continuationIndentControls(grid),
              _specialCharacterControls(),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ],
    );
  }

  void _setSearchRect(GalLookupNormalizedRectV1 rect) {
    _rect = rect;
    _layoutRect = rect;
    _advanceBaseline = null;
    _manualGridEdit = false;
    // A new crop needs a new fit; never apply stale geometry from another crop.
    _layout = copyGalCalibrationLayout(_layout, clearCellGrid: true);
    _changed();
  }
}
