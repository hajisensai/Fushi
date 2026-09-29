import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_draft.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_image_fit.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/pages/implementations/gal_lookup_samples_dialog.dart';
import 'package:fushi/src/pages/implementations/gal_lookup_calibration_canvas.dart';
import 'package:image/image.dart' as img;

const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const String _text = 'A😀e\u0301B';
const GalLookupReferenceClientV1 _client = GalLookupReferenceClientV1(
  widthPx: 800,
  heightPx: 600,
  dpi: 96,
);
const GalLookupNormalizedRectV1 _rect = GalLookupNormalizedRectV1(
  left: 0.1,
  top: 0.6,
  width: 0.8,
  height: 0.25,
);
const GalLookupTextLayoutV1 _layout = GalLookupTextLayoutV1(
  fontFamily: 'Initial font',
);
const WindowCaptureMetadata _metadata = WindowCaptureMetadata(
  capturedHwnd: 77,
  capturedPid: 1234,
  clientLeftPx: 120,
  clientTopPx: 90,
  clientWidthPx: 800,
  clientHeightPx: 600,
  imageWidthPx: 800,
  imageHeightPx: 600,
  dpi: 96,
  clientAreaComplete: true,
  capturedAtTickMs: 400,
);
final Uint8List _png = Uint8List.fromList(
  img.encodePng(img.Image(width: 800, height: 600)),
);

GalLookupCalibrationCapture _capture({
  GalLookupReferenceClientV1 client = _client,
  String sourceText = _text,
  String occurrenceId = 'synthetic-entry-1',
}) => GalLookupCalibrationCapture(
  sourceText: sourceText,
  pngBytes: _png,
  referenceClient: client,
  exePath: r'C:\synthetic\game.exe',
  exeSha256: _sha,
  sessionEpoch: 2,
  occurrenceId: occurrenceId,
  sourceSequence: 17,
  targetHwnd: 77,
  capturedAt: DateTime.utc(2026, 9, 17, 12),
  selectedThreadKey: 'synthetic-body',
  captureMetadata: _metadata,
);

GalLookupCalibrationDraft _draft({
  int count = 1,
  GalLookupNormalizedRectV1 rect = _rect,
  GalLookupTextLayoutV1 layout = _layout,
  Map<int, Offset> anchors = const <int, Offset>{},
}) => GalLookupCalibrationDraft(
  rect: rect,
  layout: layout,
  samples: <GalCalibrationSample>[
    for (int i = 0; i < count; i++)
      GalCalibrationSample(capture: _capture(), anchors: anchors),
  ],
);

Future<GalCalibrationPreview> _preview({
  required String text,
  required GalLookupReferenceClientV1 client,
  required GalLookupNormalizedRectV1 rect,
  required GalLookupTextLayoutV1 layout,
}) async => const GalCalibrationPreview(
  boxes: <GalCalibrationBox>[
    GalCalibrationBox(0, 1, Rect.fromLTWH(80, 360, 24, 30)),
    GalCalibrationBox(1, 2, Rect.fromLTWH(104, 360, 24, 30)),
    GalCalibrationBox(3, 2, Rect.fromLTWH(128, 360, 24, 30)),
    GalCalibrationBox(5, 1, Rect.fromLTWH(152, 360, 24, 30)),
  ],
);

class _MemoryStore extends GalLookupCalibrationStore {
  _MemoryStore({this.draft});

  GalLookupCalibrationDraft? draft;
  bool failSave = false;
  final List<GalLookupCalibrationDraft> saved = <GalLookupCalibrationDraft>[];

  @override
  Future<GalLookupCalibrationDraft?> load(
    String hash, {
    GalLookupCalibrationSlotV1? slot,
  }) async {
    expect(hash, _sha);
    return draft;
  }

  @override
  Future<void> save(
    String hash,
    GalLookupCalibrationDraft draft, {
    GalLookupCalibrationSlotV1? slot,
  }) async {
    expect(hash, _sha);
    if (failSave) throw StateError('synthetic disk failure');
    saved.add(draft);
    this.draft = draft;
  }
}

class _Result {
  bool closed = false;
  GalLookupCalibrationDraft? applied;
}

Future<_Result> _open(
  WidgetTester tester, {
  required _MemoryStore store,
  Future<GalLookupCalibrationCapture> Function() capture = _captureAsync,
  GalCalibrationPreviewBuilder previewBuilder = _preview,
  Future<GalCalibrationImageFit> Function(
        GalLookupCalibrationDraft draft, {
        GalCalibrationPreviewBuilder build,
      })
      imageFitter =
      fitGalCalibrationImages,
  Size size = const Size(1280, 900),
  bool manual = true,
  GalLookupCalibrationSlotV1? slot,
  Future<void> Function()? onOpenNarrationCalibration,
  Future<void> Function()? onOpenDialogueCalibration,
  bool nativeGeometryActive = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final _Result result = _Result();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result.applied = await showDialog<GalLookupCalibrationDraft>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => GalLookupSamplesDialog(
                    exeSha256: _sha,
                    initialRect: _rect,
                    initialLayout: _layout,
                    capture: capture,
                    slot: slot,
                    onOpenNarrationCalibration: onOpenNarrationCalibration,
                    onOpenDialogueCalibration: onOpenDialogueCalibration,
                    nativeGeometryActive: nativeGeometryActive,
                    store: store,
                    previewBuilder: previewBuilder,
                    imageFitter: imageFitter,
                  ),
                );
                result.closed = true;
              },
              child: const Text('Open synthetic sample notebook'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byType(ElevatedButton));
  await tester.pumpAndSettle();
  // Some tests need to inspect the advanced settings panel.
  if (manual) {
    final Finder advanced = find.byKey(
      const ValueKey<String>('calibration-advanced'),
    );
    await tester.ensureVisible(advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
  }
  return result;
}

Future<GalLookupCalibrationCapture> _captureAsync() async => _capture();

Finder _sampleChip(int index) => find.byWidgetPredicate(
  (Widget widget) =>
      widget is ChoiceChip &&
      widget.label is Text &&
      (widget.label as Text).data == '${index + 1}',
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  GalLookupCalibrationCanvas canvas(WidgetTester tester) =>
      tester.widget<GalLookupCalibrationCanvas>(
        find.byType(GalLookupCalibrationCanvas),
      );

  testWidgets(
    'dragging the outer area moves layout without moving reference points',
    (WidgetTester tester) async {
      final _MemoryStore store = _MemoryStore(
        draft: _draft(anchors: const <int, Offset>{0: Offset(0.3, 0.7)}),
      );
      await _open(tester, store: store);
      final Size imageSize = tester.getSize(find.byType(Image));
      await tester.drag(
        find.byKey(const ValueKey<String>('calibration-region-move')),
        const Offset(30, -20),
      );
      await tester.pumpAndSettle();
      expect(
        canvas(tester).rect.left,
        closeTo(_rect.left + 30 / imageSize.width, 0.002),
      );
      expect(
        canvas(tester).rect.top,
        closeTo(_rect.top - 20 / imageSize.height, 0.002),
      );
      expect(canvas(tester).anchors, isEmpty);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(store.saved.last.rect, canvas(tester).rect);
      expect(
        store.saved.last.samples.single.anchors[0],
        const Offset(0.3, 0.7),
      );
    },
  );

  testWidgets(
    'bottom handle visibly resizes outer area without changing font size',
    (WidgetTester tester) async {
      final _MemoryStore store = _MemoryStore(draft: _draft());
      await _open(tester, store: store);
      final Size imageSize = tester.getSize(find.byType(Image));
      await tester.drag(
        find.byKey(const ValueKey<String>('calibration-region-bottom')),
        const Offset(0, -35),
      );
      await tester.pumpAndSettle();
      expect(
        canvas(tester).rect.height,
        closeTo(_rect.height - 35 / imageSize.height, 0.002),
      );
      expect(canvas(tester).rect.top, _rect.top);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        store.saved.last.layout.fontSizePerClientHeight,
        _layout.fontSizePerClientHeight,
      );
    },
  );

  testWidgets(
    'zoomed region drag uses inverse transform and stays inside the screenshot',
    (WidgetTester tester) async {
      await _open(tester, store: _MemoryStore(draft: _draft()));
      final Size imageSize = tester.getSize(find.byType(Image));
      await tester.tap(find.byTooltip(t.game_lookup_samples_zoom_in));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey<String>('calibration-region-move')),
        const Offset(30, -15),
      );
      await tester.pumpAndSettle();
      expect(
        canvas(tester).rect.left,
        closeTo(_rect.left + 30 / 1.5 / imageSize.width, 0.003),
      );
      await tester.drag(
        find.byKey(const ValueKey<String>('calibration-region-move')),
        const Offset(2000, 2000),
      );
      await tester.pumpAndSettle();
      expect(canvas(tester).rect.isValid, isTrue);
      expect(
        canvas(tester).rect.left + canvas(tester).rect.width,
        closeTo(1, 1e-8),
      );
      expect(
        canvas(tester).rect.top + canvas(tester).rect.height,
        closeTo(1, 1e-8),
      );
    },
  );

  testWidgets('zoomed image pans when dragging outside the yellow region', (
    WidgetTester tester,
  ) async {
    await _open(tester, store: _MemoryStore(draft: _draft()));
    await tester.tap(find.byTooltip(t.game_lookup_samples_zoom_in));
    await tester.pumpAndSettle();
    final Finder image = find.byKey(
      const ValueKey<String>('calibration-image'),
    );
    final Rect before = tester.getRect(image);
    final TestGesture mouse = await tester.startGesture(
      before.center,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(40, 25));
    await mouse.up();
    await tester.pumpAndSettle();
    final Rect after = tester.getRect(image);
    expect(after.left - before.left, closeTo(40, 0.5));
    expect(after.top - before.top, closeTo(25, 0.5));
  });

  testWidgets('mouse-wheel zoom keeps the pointer position fixed', (
    WidgetTester tester,
  ) async {
    await _open(tester, store: _MemoryStore(draft: _draft()));
    final Finder image = find.byKey(
      const ValueKey<String>('calibration-image'),
    );
    final Rect before = tester.getRect(image);
    final Offset focus = before.topLeft + const Offset(100, 80);
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(focus));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
    await tester.pumpAndSettle();

    final Rect after = tester.getRect(image);
    expect(
      after.left,
      closeTo(focus.dx - 1.15 * (focus.dx - before.left), 0.5),
    );
    expect(after.top, closeTo(focus.dy - 1.15 * (focus.dy - before.top), 0.5));
  });

  testWidgets(
    'advanced settings hide numeric region, point mode, and validation controls',
    (WidgetTester tester) async {
      final _MemoryStore store = _MemoryStore(draft: _draft());
      await _open(tester, store: store);
      expect(
        find.byKey(const ValueKey<String>('calibration-number-height')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('calibration-mode-region')),
        findsNothing,
      );
      expect(find.byType(FilterChip), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('calibration-font')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('calibration-manual-layout')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('special character widths are optional and persisted', (
    WidgetTester tester,
  ) async {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.04,
      lineAdvancePerClientHeight: 0.06,
      cellHeightPerClientHeight: 0.05,
      columns: 20,
      continuationIndent: 0,
      quotedContinuationIndent: 1,
    );
    final _MemoryStore store = _MemoryStore(
      draft: _draft(layout: const GalLookupTextLayoutV1(cellGrid: grid)),
    );
    await _open(tester, store: store);
    final Finder manualLayout = find.byKey(
      const ValueKey<String>('calibration-manual-layout'),
    );
    await tester.ensureVisible(manualLayout);
    await tester.tap(manualLayout);
    await tester.pumpAndSettle();
    final Finder toggle = find.byKey(
      const ValueKey<String>('calibration-special-character-width'),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('calibration-special-character-input')),
      '、',
    );
    final Finder add = find.byKey(
      const ValueKey<String>('calibration-special-character-add'),
    );
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(store.saved.last.layout.characterAdvances, hasLength(1));
    expect(store.saved.last.layout.characterAdvances.single.character, '、');
    expect(
      store.saved.last.layout.characterAdvances.single.advanceRatio,
      closeTo(0.75, 0.001),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(store.saved.last.layout.characterAdvances, isEmpty);
  });

  testWidgets('engine geometry marks the calibration as a fallback', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      store: _MemoryStore(draft: _draft()),
      manual: false,
      nativeGeometryActive: true,
    );
    expect(
      find.byKey(const ValueKey<String>('calibration-native-fallback')),
      findsOneWidget,
    );
    expect(
      find.text(t.game_lookup_samples_native_fallback_hint),
      findsOneWidget,
    );
  });

  testWidgets('attached calibration shows no fallback note', (
    WidgetTester tester,
  ) async {
    await _open(tester, store: _MemoryStore(draft: _draft()), manual: false);
    expect(
      find.byKey(const ValueKey<String>('calibration-native-fallback')),
      findsNothing,
    );
  });

  testWidgets('a surface between states is not reported as a missing line', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      store: _MemoryStore(),
      manual: false,
      capture: () async => throw const GalLookupCalibrationCaptureException(
        GalLookupCalibrationCaptureFailure.surfaceNotReady,
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('calibration-empty-capture')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(t.game_lookup_samples_capture_surface_not_ready),
      findsOneWidget,
    );
    expect(find.text(t.game_lookup_samples_capture_source), findsNothing);
  });

  testWidgets('empty notebook offers capturing the current line', (
    WidgetTester tester,
  ) async {
    final _MemoryStore store = _MemoryStore();
    int captures = 0;
    await _open(
      tester,
      store: store,
      manual: false,
      capture: () async {
        captures++;
        return _capture();
      },
    );
    expect(find.text(t.game_lookup_samples_empty), findsOneWidget);
    final Finder capture = find.byKey(
      const ValueKey<String>('calibration-empty-capture'),
    );
    expect(capture, findsOneWidget);
    await tester.tap(capture);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(captures, 1);
    expect(find.byType(GalLookupCalibrationCanvas), findsOneWidget);
    expect(capture, findsNothing);
  });

  testWidgets('dialogue advanced settings expose manual layout entry', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      store: _MemoryStore(draft: _draft()),
      slot: GalLookupCalibrationSlotV1.dialogue,
    );
    expect(
      find.byKey(const ValueKey<String>('calibration-manual-layout')),
      findsOneWidget,
    );
  });

  testWidgets('retired quote-only filter is cleared when recalibrating', (
    WidgetTester tester,
  ) async {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.04,
      lineAdvancePerClientHeight: 0.06,
      cellHeightPerClientHeight: 0.05,
      columns: 20,
      continuationIndent: 0,
      quotedContinuationIndent: 1,
    );
    final _MemoryStore store = _MemoryStore(
      draft: _draft(
        layout: const GalLookupTextLayoutV1(
          cellGrid: grid,
          quotedTextOnly: true,
        ),
      ),
    );
    await _open(tester, store: store);
    expect(
      find.byKey(const ValueKey<String>('calibration-quoted-text-only')),
      findsNothing,
    );
    final Finder manualLayout = find.byKey(
      const ValueKey<String>('calibration-manual-layout'),
    );
    await tester.ensureVisible(manualLayout);
    await tester.tap(manualLayout);
    await tester.pumpAndSettle();
    final Finder toggle = find.byKey(
      const ValueKey<String>('calibration-special-character-width'),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('calibration-special-character-input')),
      '、',
    );
    final Finder add = find.byKey(
      const ValueKey<String>('calibration-special-character-add'),
    );
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(store.saved, isNotEmpty);
    expect(store.saved.last.layout.quotedTextOnly, isFalse);
  });

  test(
    'quote-only fitting restores original Hook sample after OCR assist',
    () async {
      const String source = '軽音部員「A\r\nB\nC」尾注';
      final GalLookupCalibrationDraft original = GalLookupCalibrationDraft(
        rect: _rect,
        layout: const GalLookupTextLayoutV1(quotedTextOnly: true),
        samples: <GalCalibrationSample>[
          GalCalibrationSample(capture: _capture(sourceText: source)),
        ],
        slot: GalLookupCalibrationSlotV1.dialogue,
      );
      galCalibrationOcrAssist =
          (
            GalLookupCalibrationDraft fitting, {
            required GalCalibrationPreviewBuilder build,
          }) async {
            expect(fitting.samples.single.capture.sourceText, '「A\r\nB\nC」');
            expect(fitting.layout.quotedTextOnly, isTrue);
            return GalCalibrationImageFit(draft: fitting);
          };
      addTearDown(() {
        galCalibrationOcrAssist = null;
      });
      int previewCalls = 0;
      final GalCalibrationImageFit result = await fitGalCalibrationImages(
        original,
        build:
            ({
              required String text,
              required GalLookupReferenceClientV1 client,
              required GalLookupNormalizedRectV1 rect,
              required GalLookupTextLayoutV1 layout,
            }) async {
              previewCalls++;
              expect(text, source);
              expect(layout.quotedTextOnly, isTrue);
              return _preview(
                text: text,
                client: client,
                rect: rect,
                layout: layout,
              );
            },
      );
      expect(result.draft?.samples.single.capture.sourceText, source);
      expect(result.draft?.slot, GalLookupCalibrationSlotV1.dialogue);
      expect(previewCalls, 1);
    },
  );

  testWidgets('manual layout controls stay hidden until activated', (
    WidgetTester tester,
  ) async {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.04,
      lineAdvancePerClientHeight: 0.06,
      cellHeightPerClientHeight: 0.05,
      columns: 20,
      continuationIndent: 0,
      quotedContinuationIndent: 1,
    );
    await _open(
      tester,
      store: _MemoryStore(
        draft: _draft(layout: const GalLookupTextLayoutV1(cellGrid: grid)),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('calibration-grid-advance-slider')),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey<String>('calibration-continuation-indent-slider'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('calibration-special-character-width')),
      findsNothing,
    );

    final Finder manualLayout = find.byKey(
      const ValueKey<String>('calibration-manual-layout'),
    );
    await tester.ensureVisible(manualLayout);
    await tester.tap(manualLayout);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('calibration-grid-advance-slider')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('calibration-continuation-indent-slider'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('calibration-special-character-width')),
      findsOneWidget,
    );
  });

  testWidgets('continuation start control applies to all text', (
    WidgetTester tester,
  ) async {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.04,
      lineAdvancePerClientHeight: 0.06,
      cellHeightPerClientHeight: 0.05,
      columns: 20,
      continuationIndent: 0,
      quotedContinuationIndent: 1,
    );
    final _MemoryStore store = _MemoryStore(
      draft: _draft(layout: const GalLookupTextLayoutV1(cellGrid: grid)),
    );
    await _open(tester, store: store);
    final Finder manualLayout = find.byKey(
      const ValueKey<String>('calibration-manual-layout'),
    );
    await tester.ensureVisible(manualLayout);
    await tester.tap(manualLayout);
    await tester.pumpAndSettle();

    final Slider continuation = tester.widget<Slider>(
      find.byKey(
        const ValueKey<String>('calibration-continuation-indent-slider'),
      ),
    );
    expect(continuation.min, -1);
    expect(continuation.max, 8);
    expect(
      find.byKey(
        const ValueKey<String>('calibration-quoted-continuation-indent-slider'),
      ),
      findsNothing,
    );
    continuation.onChanged!(1.75);
    await tester.pump();

    expect(canvas(tester).grid!.continuationIndent, closeTo(1.75, 1e-8));
    expect(canvas(tester).grid!.quotedContinuationIndent, closeTo(1.75, 1e-8));
    await tester.tap(find.text(t.game_lookup_samples_apply));
    await tester.pumpAndSettle();
    expect(store.saved.last.layout.cellGrid!.continuationIndent, 1.75);
    expect(store.saved.last.layout.cellGrid!.quotedContinuationIndent, 1.75);
  });

  testWidgets('normal cell width control persists and expands the frame', (
    WidgetTester tester,
  ) async {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.04,
      lineAdvancePerClientHeight: 0.06,
      cellHeightPerClientHeight: 0.05,
      columns: 20,
      continuationIndent: 0,
      quotedContinuationIndent: 1,
    );
    const GalLookupNormalizedRectV1 rect = GalLookupNormalizedRectV1(
      left: 0.1,
      top: 0.6,
      width: 0.5,
      height: 0.25,
    );
    final _MemoryStore store = _MemoryStore(
      draft: _draft(
        rect: rect,
        layout: const GalLookupTextLayoutV1(cellGrid: grid),
      ),
    );
    await _open(tester, store: store);
    final Finder manualLayout = find.byKey(
      const ValueKey<String>('calibration-manual-layout'),
    );
    await tester.ensureVisible(manualLayout);
    await tester.tap(manualLayout);
    await tester.pumpAndSettle();

    Slider slider() => tester.widget<Slider>(
      find.byKey(const ValueKey<String>('calibration-grid-advance-slider')),
    );
    // A narrow ±15 % span around the starting width with 0.1 % steps.
    expect(slider().value, closeTo(0.8, 1e-8));
    expect(slider().min, closeTo(0.65, 1e-8));
    expect(slider().max, closeTo(0.95, 1e-8));
    expect(slider().divisions, 300);
    expect(find.text('80.0%'), findsOneWidget);
    slider().onChanged!(0.9);
    await tester.pump();

    // 20 cells × 0.005 advance × 600/800 = 0.075 wider box.
    expect(canvas(tester).grid!.advancePerClientHeight, closeTo(0.045, 1e-8));
    expect(canvas(tester).layoutRect!.width, closeTo(0.575, 1e-8));
    expect(find.text('90.0%'), findsOneWidget);
    await tester.tap(find.text(t.game_lookup_samples_apply));
    await tester.pumpAndSettle();
    expect(
      store.saved.last.layout.cellGrid!.advancePerClientHeight,
      closeTo(0.045, 1e-8),
    );
    expect(store.saved.last.rect.width, closeTo(0.575, 1e-8));
  });

  testWidgets(
    'grid width returns to the exact box and never leaves the image',
    (WidgetTester tester) async {
      const GalLookupCellGridV1 grid = GalLookupCellGridV1(
        advancePerClientHeight: 0.04,
        lineAdvancePerClientHeight: 0.06,
        cellHeightPerClientHeight: 0.05,
        columns: 20,
        continuationIndent: 0,
        quotedContinuationIndent: 1,
      );
      // Only 0.05 of free width to the right: the edge, not the span, limits.
      const GalLookupNormalizedRectV1 rect = GalLookupNormalizedRectV1(
        left: 0.35,
        top: 0.6,
        width: 0.6,
        height: 0.25,
      );
      await _open(
        tester,
        store: _MemoryStore(
          draft: _draft(
            rect: rect,
            layout: const GalLookupTextLayoutV1(cellGrid: grid),
          ),
        ),
      );
      final Finder manualLayout = find.byKey(
        const ValueKey<String>('calibration-manual-layout'),
      );
      await tester.ensureVisible(manualLayout);
      await tester.tap(manualLayout);
      await tester.pumpAndSettle();
      Slider slider() => tester.widget<Slider>(
        find.byKey(const ValueKey<String>('calibration-grid-advance-slider')),
      );
      // 0.05 free width / (20 × 600/800) = 0.00333 advance → ratio ≈ 0.8667.
      expect(slider().max, closeTo(0.8 + 0.05 / 15 / 0.05, 1e-8));
      for (final double overshoot in <double>[5.0, 0.95, 0.9]) {
        slider().onChanged!(overshoot);
        await tester.pump();
        expect(canvas(tester).layoutRect!.right, lessThanOrEqualTo(1 + 1e-9));
        expect(canvas(tester).layoutRect!.width, greaterThan(0.6 - 1e-9));
      }
      slider().onChanged!(0.7);
      await tester.pump();
      slider().onChanged!(0.8);
      await tester.pump();
      expect(canvas(tester).grid!.advancePerClientHeight, closeTo(0.04, 1e-9));
      expect(canvas(tester).layoutRect!.left, closeTo(0.35, 1e-9));
      expect(canvas(tester).layoutRect!.width, closeTo(0.6, 1e-9));

      final Finder increase = find.byKey(
        const ValueKey<String>('calibration-grid-advance-increase'),
      );
      await tester.ensureVisible(increase);
      await tester.tap(increase);
      await tester.pump();
      expect(find.text('80.1%'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('calibration-grid-advance-decrease')),
      );
      await tester.pump();
      expect(find.text('80.0%'), findsOneWidget);
      expect(canvas(tester).layoutRect!.width, closeTo(0.6, 1e-9));
    },
  );

  testWidgets('grid editing uses visual handles for uniform cell correction', (
    WidgetTester tester,
  ) async {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.04,
      lineAdvancePerClientHeight: 0.06,
      cellHeightPerClientHeight: 0.05,
      columns: 20,
      continuationIndent: 0,
      quotedContinuationIndent: 1,
    );
    final _MemoryStore store = _MemoryStore(
      draft: _draft(layout: const GalLookupTextLayoutV1(cellGrid: grid)),
    );
    await _open(tester, store: store);
    final Finder manualLayout = find.byKey(
      const ValueKey<String>('calibration-manual-layout'),
    );
    expect(manualLayout, findsOneWidget);
    await tester.ensureVisible(manualLayout);
    await tester.tap(manualLayout);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('calibration-grid-move')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('calibration-cell-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('calibration-region-move')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('calibration-region-bottom')),
      findsNothing,
    );
    for (final String corner in <String>[
      'top-left',
      'top-right',
      'bottom-left',
      'bottom-right',
    ]) {
      expect(
        find.byKey(ValueKey<String>('calibration-grid-$corner')),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(const ValueKey<String>('calibration-grid-columns')),
      findsNothing,
    );
    final GalLookupNormalizedRectV1 originalLayoutRect = canvas(
      tester,
    ).layoutRect!;
    await tester.drag(
      find.byKey(const ValueKey<String>('calibration-grid-top-right')),
      const Offset(16, -12),
    );
    await tester.pumpAndSettle();
    expect(
      canvas(tester).layoutRect!.width,
      greaterThan(originalLayoutRect.width),
    );
    expect(
      canvas(tester).layoutRect!.height,
      greaterThan(originalLayoutRect.height),
    );
    final double originalAdvance = canvas(tester).grid!.advancePerClientHeight;
    await tester.drag(
      find.byKey(const ValueKey<String>('calibration-cell-0')),
      const Offset(20, 0),
    );
    await tester.pumpAndSettle();
    expect(
      canvas(tester).grid!.advancePerClientHeight,
      greaterThan(originalAdvance),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(store.saved.last.layout.cellGrid, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('special-character cell resizing stays independent', (
    WidgetTester tester,
  ) async {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.04,
      lineAdvancePerClientHeight: 0.06,
      cellHeightPerClientHeight: 0.05,
      columns: 20,
      continuationIndent: 0,
      quotedContinuationIndent: 1,
    );
    const GalLookupCharacterAdvanceV1 emojiAdvance =
        GalLookupCharacterAdvanceV1(codePoint: 0x1f600, advanceRatio: 0.75);
    final _MemoryStore store = _MemoryStore(
      draft: _draft(
        layout: const GalLookupTextLayoutV1(
          cellGrid: grid,
          characterAdvances: <GalLookupCharacterAdvanceV1>[emojiAdvance],
        ),
      ),
    );
    await _open(tester, store: store);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('calibration-manual-layout')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('calibration-manual-layout')),
    );
    await tester.pumpAndSettle();
    final double originalGridAdvance = canvas(
      tester,
    ).grid!.advancePerClientHeight;
    final double originalLayoutWidth = canvas(tester).layoutRect!.width;
    await tester.drag(
      find.byKey(const ValueKey<String>('calibration-cell-1')),
      const Offset(12, 0),
    );
    await tester.pumpAndSettle();
    expect(
      canvas(tester).grid!.advancePerClientHeight,
      closeTo(originalGridAdvance, 1e-8),
    );
    expect(canvas(tester).layoutRect!.width, greaterThan(originalLayoutWidth));
    expect(
      canvas(tester).characterAdvances.single.advanceRatio,
      greaterThan(0.75),
    );
  });

  testWidgets('a narrow saved region at the edge can still be resized', (
    WidgetTester tester,
  ) async {
    const GalLookupNormalizedRectV1 narrow = GalLookupNormalizedRectV1(
      left: 0.001,
      top: 0.4,
      width: 0.005,
      height: 0.2,
    );
    await _open(
      tester,
      store: _MemoryStore(draft: _draft(rect: narrow)),
    );
    final Offset start = tester.getCenter(
      find.byKey(const ValueKey<String>('calibration-region-left')),
    );
    final TestGesture mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(-25, 0));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(canvas(tester).rect.left, 0);
    expect(canvas(tester).rect.width, closeTo(0.006, 1e-8));
  });

  testWidgets('capture action saves the exact sample immediately', (
    WidgetTester tester,
  ) async {
    final _MemoryStore store = _MemoryStore();
    int captures = 0;
    final GalLookupCalibrationCapture sample = _capture();
    final _Result result = await _open(
      tester,
      store: store,
      capture: () async {
        captures++;
        return sample;
      },
    );
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.byTooltip(t.game_lookup_samples_capture));
    await tester.pumpAndSettle();
    expect(captures, 1);
    expect(store.saved, hasLength(1));
    expect(store.saved.single.samples.single.capture, same(sample));
    expect(find.byType(Image), findsOneWidget);
    expect(result.closed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('surface mapping failure uses the dedicated capture message', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      store: _MemoryStore(),
      manual: false,
      capture: () async {
        throw const GalLookupCalibrationCaptureException(
          GalLookupCalibrationCaptureFailure.surfaceMappingUnavailable,
          captureReason: 'magpie_source_viewport_invalid',
        );
      },
    );
    await tester.tap(find.byTooltip(t.game_lookup_samples_capture));
    await tester.pumpAndSettle();
    expect(
      find.text(t.game_lookup_samples_capture_surface_mapping),
      findsOneWidget,
    );
    expect(find.text(t.game_lookup_samples_capture_source), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixed slot keeps failed sample and replaces it on success', (
    WidgetTester tester,
  ) async {
    final GalLookupCalibrationCapture oldCapture = _capture(
      occurrenceId: 'old-entry',
    );
    final GalLookupCalibrationCapture newCapture = _capture(
      occurrenceId: 'new-entry',
    );
    final _MemoryStore store = _MemoryStore(
      draft: GalLookupCalibrationDraft(
        rect: _rect,
        layout: _layout,
        samples: <GalCalibrationSample>[
          GalCalibrationSample(capture: oldCapture),
        ],
        slot: GalLookupCalibrationSlotV1.dialogue,
      ),
    );
    int captures = 0;

    await _open(
      tester,
      store: store,
      manual: false,
      slot: GalLookupCalibrationSlotV1.dialogue,
      capture: () async {
        captures++;
        if (captures == 1) {
          throw const GalLookupCalibrationCaptureException(
            GalLookupCalibrationCaptureFailure.sceneChanged,
          );
        }
        return newCapture;
      },
    );
    expect(find.text(t.game_lookup_samples_dialogue), findsOneWidget);
    expect(
      find.byTooltip(t.game_lookup_samples_capture_replace),
      findsOneWidget,
    );
    expect(find.byTooltip(t.game_lookup_samples_capture), findsNothing);
    expect(find.byKey(ValueKey<Object>(oldCapture)), findsOneWidget);

    await tester.tap(find.byTooltip(t.game_lookup_samples_capture_replace));
    await tester.pumpAndSettle();
    expect(captures, 1);
    expect(store.saved, isEmpty);
    expect(store.draft!.samples.single.capture, same(oldCapture));
    expect(find.byKey(ValueKey<Object>(oldCapture)), findsOneWidget);
    expect(find.text(t.game_lookup_samples_capture_changed), findsOneWidget);

    await tester.tap(find.byTooltip(t.game_lookup_samples_capture_replace));
    await tester.pumpAndSettle();
    expect(captures, 2);
    expect(store.saved, hasLength(1));
    expect(store.saved.single.samples, hasLength(1));
    expect(store.saved.single.samples.single.capture, same(newCapture));
    expect(find.byKey(ValueKey<Object>(oldCapture)), findsNothing);
    expect(find.byKey(ValueKey<Object>(newCapture)), findsOneWidget);
  });

  testWidgets('dialogue advanced settings open narration calibration', (
    WidgetTester tester,
  ) async {
    bool opened = false;
    await _open(
      tester,
      store: _MemoryStore(draft: _draft()),
      slot: GalLookupCalibrationSlotV1.dialogue,
      onOpenNarrationCalibration: () async => opened = true,
    );
    final Finder narration = find.byKey(
      const ValueKey<String>('calibration-narration-settings'),
    );
    expect(narration, findsOneWidget);
    expect(find.text(t.game_lookup_samples_narration_hint), findsOneWidget);
    await tester.ensureVisible(narration);
    await tester.tap(narration);
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narration explains its use and can return to dialogue', (
    WidgetTester tester,
  ) async {
    bool opened = false;
    await _open(
      tester,
      store: _MemoryStore(draft: _draft()),
      slot: GalLookupCalibrationSlotV1.narration,
      onOpenDialogueCalibration: () async => opened = true,
    );
    expect(find.text(t.game_lookup_samples_narration_hint), findsOneWidget);
    final Finder dialogue = find.byKey(
      const ValueKey<String>('calibration-dialogue-settings'),
    );
    expect(dialogue, findsOneWidget);
    await tester.ensureVisible(dialogue);
    await tester.tap(dialogue);
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });

  testWidgets('visual grid edits can be applied without font controls', (
    WidgetTester tester,
  ) async {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.04,
      lineAdvancePerClientHeight: 0.06,
      cellHeightPerClientHeight: 0.05,
      columns: 20,
      continuationIndent: 0,
      quotedContinuationIndent: 1,
    );
    final _MemoryStore store = _MemoryStore(
      draft: _draft(layout: const GalLookupTextLayoutV1(cellGrid: grid)),
    );
    final _Result result = await _open(tester, store: store);
    final Finder manualLayout = find.byKey(
      const ValueKey<String>('calibration-manual-layout'),
    );
    await tester.ensureVisible(manualLayout);
    await tester.tap(manualLayout);
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey<String>('calibration-grid-top-left')),
      const Offset(8, 0),
    );
    await tester.tap(find.text(t.game_lookup_samples_apply));
    await tester.pumpAndSettle();
    expect(result.closed, isTrue);
    expect(result.applied!.layout.cellGrid, isNotNull);
    expect(
      find.byKey(const ValueKey<String>('calibration-font')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'image alignment applies grid and hides irrelevant font controls',
    (tester) async {
      const GalLookupNormalizedRectV1 fittedRect = GalLookupNormalizedRectV1(
        left: .11,
        top: .61,
        width: .85,
        height: .3,
      );
      const fittedClient = GalLookupReferenceClientV1(
        widthPx: 800,
        heightPx: 600,
        dpi: 144,
      );
      final _MemoryStore store = _MemoryStore(draft: _draft());
      final _Result result = await _open(
        tester,
        store: store,
        manual: false,
        imageFitter: (draft, {build = _preview}) async {
          expect(draft.samples.single.validation, isFalse);
          expect(draft.samples.single.anchors, isEmpty);
          return GalCalibrationImageFit(
            draft: GalLookupCalibrationDraft(
              rect: fittedRect,
              searchRect: draft.searchRect,
              layoutReferenceClient: fittedClient,
              layoutCaptureMetadata: _metadata,
              samples: draft.samples,
              layout: const GalLookupTextLayoutV1(
                cellGrid: GalLookupCellGridV1(
                  advancePerClientHeight: 0.04,
                  lineAdvancePerClientHeight: 0.06,
                  cellHeightPerClientHeight: 0.05,
                  columns: 20,
                  continuationIndent: 0,
                  quotedContinuationIndent: 1,
                ),
              ),
            ),
          );
        },
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('calibration-auto-align')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('calibration-font')),
        findsNothing,
      );
      expect(find.text(t.game_lookup_samples_auto_success), findsWidgets);
      expect(
        tester
            .widget<GalLookupCalibrationCanvas>(
              find.byType(GalLookupCalibrationCanvas),
            )
            .rect,
        _rect,
      );
      await tester.tap(find.text(t.game_lookup_samples_apply));
      await tester.pumpAndSettle();
      expect(result.applied!.layout.cellGrid!.columns, 20);
      expect(result.applied!.rect, fittedRect);
      expect(result.applied!.searchRect, _rect);
      expect(result.applied!.layoutReferenceClient, fittedClient);
      expect(result.applied!.layoutCaptureMetadata, _metadata);
      expect(
        store.saved.single.layout.cellGrid,
        result.applied!.layout.cellGrid,
      );
    },
  );

  testWidgets(
    'automatic alignment defaults to the selected sample and preserves the notebook',
    (WidgetTester tester) async {
      const GalLookupNormalizedRectV1 fittedRect = GalLookupNormalizedRectV1(
        left: .11,
        top: .61,
        width: .85,
        height: .3,
      );
      final _MemoryStore store = _MemoryStore(draft: _draft(count: 3));
      final List<int> fitSampleCounts = <int>[];
      final _Result result = await _open(
        tester,
        store: store,
        manual: false,
        imageFitter: (draft, {build = _preview}) async {
          fitSampleCounts.add(draft.samples.length);
          return GalCalibrationImageFit(
            draft: GalLookupCalibrationDraft(
              rect: fittedRect,
              searchRect: draft.searchRect,
              samples: draft.samples,
              layout: const GalLookupTextLayoutV1(
                cellGrid: GalLookupCellGridV1(
                  advancePerClientHeight: 0.04,
                  lineAdvancePerClientHeight: 0.06,
                  cellHeightPerClientHeight: 0.05,
                  columns: 20,
                  continuationIndent: 0,
                  quotedContinuationIndent: 1,
                ),
              ),
            ),
          );
        },
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('calibration-auto-align')),
      );
      await tester.pumpAndSettle();
      expect(fitSampleCounts, [1]);
      await tester.tap(find.text(t.game_lookup_samples_apply));
      await tester.pumpAndSettle();
      expect(result.applied!.samples, hasLength(3));
    },
  );

  testWidgets(
    'single image fit stores its selected reference without changing validation groups',
    (WidgetTester tester) async {
      const GalLookupReferenceClientV1 selectedClient =
          GalLookupReferenceClientV1(widthPx: 1280, heightPx: 720, dpi: 120);
      final GalLookupCalibrationDraft original = GalLookupCalibrationDraft(
        rect: _rect,
        layout: _layout,
        samples: <GalCalibrationSample>[
          GalCalibrationSample(capture: _capture()),
          GalCalibrationSample(
            capture: _capture(
              client: selectedClient,
              occurrenceId: 'synthetic-entry-2',
            ),
            validation: true,
          ),
        ],
      );
      final _MemoryStore store = _MemoryStore(draft: original);
      final _Result result = await _open(
        tester,
        store: store,
        manual: false,
        imageFitter: (draft, {build = _preview}) async {
          expect(draft.samples, hasLength(1));
          expect(draft.samples.single.capture.referenceClient, selectedClient);
          expect(draft.samples.single.validation, isFalse);
          return GalCalibrationImageFit(
            draft: GalLookupCalibrationDraft(
              rect: draft.rect,
              searchRect: draft.searchRect,
              layout: const GalLookupTextLayoutV1(
                cellGrid: GalLookupCellGridV1(
                  advancePerClientHeight: 0.04,
                  lineAdvancePerClientHeight: 0.06,
                  cellHeightPerClientHeight: 0.05,
                  columns: 20,
                  continuationIndent: 0,
                  quotedContinuationIndent: 1,
                ),
              ),
              samples: draft.samples,
            ),
          );
        },
      );
      final Finder advanced = find.byKey(
        const ValueKey<String>('calibration-advanced'),
      );
      await tester.ensureVisible(advanced);
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      await tester.tap(_sampleChip(1));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('calibration-auto-align')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.game_lookup_samples_apply));
      await tester.pumpAndSettle();
      expect(result.applied!.layoutReferenceClient, selectedClient);
      expect(result.applied!.samples.map((sample) => sample.validation), [
        false,
        true,
      ]);
    },
  );

  testWidgets(
    'single image fit reports its selected sample when the fitter returns index zero',
    (WidgetTester tester) async {
      final GalLookupCalibrationCapture selected = _capture(
        occurrenceId: 'synthetic-entry-2',
      );
      final _MemoryStore store = _MemoryStore(
        draft: GalLookupCalibrationDraft(
          rect: _rect,
          layout: _layout,
          samples: <GalCalibrationSample>[
            GalCalibrationSample(capture: _capture()),
            GalCalibrationSample(capture: selected),
          ],
        ),
      );
      await _open(
        tester,
        store: store,
        manual: false,
        imageFitter: (draft, {build = _preview}) async =>
            const GalCalibrationImageFit(
              reason: 'inconsistent_samples',
              sampleIndex: 0,
            ),
      );
      final Finder advanced = find.byKey(
        const ValueKey<String>('calibration-advanced'),
      );
      await tester.ensureVisible(advanced);
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      await tester.tap(_sampleChip(1));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('calibration-auto-align')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          t.game_lookup_samples_auto_sample_failed(
            sample: '2',
            reason: t.game_lookup_samples_auto_inconsistent,
          ),
        ),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey<Object>(selected)), findsOneWidget);
    },
  );

  testWidgets(
    'applying a single fit ignores an overflow in an older validation sample',
    (WidgetTester tester) async {
      const GalLookupReferenceClientV1 selectedClient =
          GalLookupReferenceClientV1(widthPx: 640, heightPx: 480, dpi: 96);
      final GalLookupCalibrationDraft original = GalLookupCalibrationDraft(
        rect: _rect,
        layout: _layout,
        samples: <GalCalibrationSample>[
          GalCalibrationSample(capture: _capture(), validation: true),
          GalCalibrationSample(
            capture: _capture(
              client: selectedClient,
              occurrenceId: 'synthetic-entry-2',
            ),
          ),
        ],
      );
      final _MemoryStore store = _MemoryStore(draft: original);
      final _Result result = await _open(
        tester,
        store: store,
        manual: false,
        previewBuilder:
            ({
              required text,
              required client,
              required rect,
              required layout,
            }) async => client == selectedClient
            ? _preview(text: text, client: client, rect: rect, layout: layout)
            : const GalCalibrationPreview(boxes: [], reason: 'overflow'),
        imageFitter: (draft, {build = _preview}) async =>
            GalCalibrationImageFit(
              draft: GalLookupCalibrationDraft(
                rect: draft.rect,
                searchRect: draft.searchRect,
                layout: const GalLookupTextLayoutV1(
                  cellGrid: GalLookupCellGridV1(
                    advancePerClientHeight: 0.04,
                    lineAdvancePerClientHeight: 0.06,
                    cellHeightPerClientHeight: 0.05,
                    columns: 20,
                    continuationIndent: 0,
                    quotedContinuationIndent: 1,
                  ),
                ),
                samples: draft.samples,
              ),
            ),
      );
      final Finder advanced = find.byKey(
        const ValueKey<String>('calibration-advanced'),
      );
      await tester.ensureVisible(advanced);
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      await tester.tap(_sampleChip(1));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('calibration-auto-align')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.game_lookup_samples_apply));
      await tester.pumpAndSettle();
      expect(result.closed, isTrue);
      expect(result.applied!.layoutReferenceClient, selectedClient);
      expect(result.applied!.samples.map((sample) => sample.validation), [
        true,
        false,
      ]);
    },
  );

  testWidgets('ambiguous image alignment preserves the saved layout', (
    tester,
  ) async {
    final _MemoryStore store = _MemoryStore(draft: _draft());
    await _open(
      tester,
      store: store,
      manual: false,
      imageFitter: (draft, {build = _preview}) async =>
          const GalCalibrationImageFit(reason: 'multiline_required'),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('calibration-auto-align')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.game_lookup_samples_auto_multiline), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(store.draft!.layout, _layout);
    expect(store.draft!.rect, _rect);
  });

  testWidgets(
    'automatic mode ignores legacy overflow and preserves the split',
    (WidgetTester tester) async {
      final GalLookupCalibrationDraft original = _draft(count: 3);
      final _MemoryStore store = _MemoryStore(
        draft: GalLookupCalibrationDraft(
          rect: original.rect,
          layout: original.layout,
          samples: [
            original.samples[0].copyWith(validation: true),
            original.samples[1],
            original.samples[2],
          ],
        ),
      );
      int previews = 0;
      await _open(
        tester,
        store: store,
        manual: false,
        previewBuilder:
            ({
              required text,
              required client,
              required rect,
              required layout,
            }) async {
              previews++;
              return const GalCalibrationPreview(boxes: [], reason: 'overflow');
            },
        imageFitter: (draft, {build = _preview}) async {
          expect(draft.samples.map((s) => s.validation), [true, false, false]);
          return const GalCalibrationImageFit(
            reason: 'inconsistent_samples',
            sampleIndex: 2,
          );
        },
      );
      final Finder advanced = find.byKey(
        const ValueKey<String>('calibration-advanced'),
      );
      await tester.ensureVisible(advanced);
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      final Finder fitAll = find.byKey(
        const ValueKey<String>('calibration-fit-all'),
      );
      await tester.ensureVisible(fitAll);
      await tester.tap(fitAll);
      await tester.pumpAndSettle();
      expect(previews, 0);
      expect(canvas(tester).boxes, isEmpty);
      expect(canvas(tester).anchors, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('calibration-font')),
        findsNothing,
      );
      expect(find.text(t.game_lookup_samples_unavailable), findsNothing);
      expect(find.text(t.game_lookup_samples_auto_pending), findsOneWidget);
      final ButtonStyleButton apply = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text(t.game_lookup_samples_apply),
          matching: find.byWidgetPredicate(
            (Widget w) => w is ButtonStyleButton,
          ),
        ),
      );
      expect(apply.onPressed, isNull);
      final Finder autoAlign = find.byKey(
        const ValueKey<String>('calibration-auto-align'),
      );
      await tester.ensureVisible(autoAlign);
      await tester.tap(autoAlign);
      await tester.pumpAndSettle();
      expect(
        find.text(
          t.game_lookup_samples_auto_sample_failed(
            sample: '3',
            reason: t.game_lookup_samples_auto_inconsistent,
          ),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(store.draft!.layout, original.layout);
      expect(store.draft!.rect, original.rect);
      expect(store.draft!.samples.map((s) => s.validation), [
        true,
        false,
        false,
      ]);
    },
  );

  testWidgets(
    'deleting from eight allows capture and a failed attempt recovers',
    (WidgetTester tester) async {
      final _MemoryStore store = _MemoryStore(draft: _draft(count: 8));
      int captures = 0;
      await _open(
        tester,
        store: store,
        manual: false,
        capture: () async {
          captures++;
          if (captures == 1) {
            throw const GalLookupCalibrationCaptureException(
              GalLookupCalibrationCaptureFailure.sceneChanged,
            );
          }
          return _capture();
        },
      );
      await tester.tap(find.byTooltip(t.game_lookup_samples_capture));
      await tester.pumpAndSettle();
      expect(captures, 0);
      expect(find.text(t.game_lookup_samples_limit), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('calibration-remove-sample')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(t.game_lookup_samples_capture));
      await tester.pumpAndSettle();
      expect(captures, 1);
      expect(find.text(t.game_lookup_samples_capture_changed), findsOneWidget);
      expect(store.saved.last.samples, hasLength(7));
      await tester.tap(find.byTooltip(t.game_lookup_samples_capture));
      await tester.pumpAndSettle();
      expect(captures, 2);
      expect(store.saved.last.samples, hasLength(8));
      expect(find.text(t.game_lookup_samples_capture_changed), findsNothing);
    },
  );

  testWidgets('disk failure keeps the new capture available for saving', (
    WidgetTester tester,
  ) async {
    final _MemoryStore store = _MemoryStore()..failSave = true;
    await _open(tester, store: store, manual: false);
    await tester.tap(find.byTooltip(t.game_lookup_samples_capture));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text(t.game_lookup_samples_save_failed), findsOneWidget);
    expect(find.text(t.game_lookup_samples_capture_failed), findsNothing);
    store.failSave = false;
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(store.saved.single.samples, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final Size size in <Size>[const Size(1280, 900), const Size(800, 600)]) {
    testWidgets(
      'eight samples fit ${size.width.toInt()} by ${size.height.toInt()} without overflow',
      (WidgetTester tester) async {
        await _open(
          tester,
          store: _MemoryStore(draft: _draft(count: 8)),
          size: size,
        );
        expect(find.byType(Image), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
