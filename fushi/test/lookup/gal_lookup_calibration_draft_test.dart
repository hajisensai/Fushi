import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_draft.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:image/image.dart' as img;

const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const String _otherSha =
    'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
const GalLookupReferenceClientV1 _client = GalLookupReferenceClientV1(
  widthPx: 1000,
  heightPx: 500,
  dpi: 96,
);
const GalLookupNormalizedRectV1 _rect = GalLookupNormalizedRectV1(
  left: 0.1,
  top: 0.2,
  width: 0.6,
  height: 0.25,
);
const GalLookupTextLayoutV1 _layout = GalLookupTextLayoutV1(
  fontFamily: 'Synthetic fixture font',
  fontSizePerClientHeight: 0.04,
  lineHeight: 1.2,
);
const WindowCaptureMetadata _metadata = WindowCaptureMetadata(
  capturedHwnd: 77,
  capturedPid: 1234,
  clientLeftPx: -300,
  clientTopPx: 90,
  clientWidthPx: 1000,
  clientHeightPx: 500,
  imageWidthPx: 1000,
  imageHeightPx: 500,
  dpi: 96,
  clientAreaComplete: true,
  capturedAtTickMs: 400,
);
final Uint8List _png = Uint8List.fromList(
  img.encodePng(img.Image(width: 1000, height: 500)),
);

GalCalibrationSample _sample({
  String text = 'ABCDE',
  String sha = _sha,
  String occurrenceId = 'synthetic-entry-1',
  bool validation = false,
  Map<int, Offset> anchors = const <int, Offset>{},
  Uint8List? png,
}) => GalCalibrationSample(
  capture: GalLookupCalibrationCapture(
    sourceText: text,
    pngBytes: png ?? _png,
    referenceClient: _client,
    exePath: r'C:\synthetic\game.exe',
    exeSha256: sha,
    sessionEpoch: 2,
    occurrenceId: occurrenceId,
    sourceSequence: 17,
    targetHwnd: 77,
    capturedAt: DateTime.utc(2026, 9, 17, 12),
    selectedThreadKey: 'synthetic-body',
    captureMetadata: _metadata,
  ),
  validation: validation,
  anchors: anchors,
);

GalLookupCalibrationDraft _draft(
  List<GalCalibrationSample> samples, {
  GalLookupCalibrationSlotV1? slot,
}) => GalLookupCalibrationDraft(
  rect: _rect,
  layout: _layout,
  samples: samples,
  slot: slot,
);

/// A simple, independently defined renderer for fitting tests. Each glyph has
/// a 20 px advance before tracking, with a 10 by 20 px hit region.
Future<GalCalibrationPreview> _linearPreview({
  required String text,
  required GalLookupReferenceClientV1 client,
  required GalLookupNormalizedRectV1 rect,
  required GalLookupTextLayoutV1 layout,
}) async => GalCalibrationPreview(
  boxes: <GalCalibrationBox>[
    for (int i = 0; i < text.length; i++)
      GalCalibrationBox(
        i,
        1,
        Rect.fromLTWH(
          rect.left * client.widthPx +
              i * (20 + layout.letterSpacingPerClientHeight * client.heightPx),
          rect.top * client.heightPx,
          10,
          20,
        ),
      ),
  ],
);

// The first and last characters require a 15 px horizontal / 5 px vertical
// translation plus an additional 2 px per character advance.
const Map<int, Offset> _targetPoints = <int, Offset>{
  0: Offset(0.120, 0.230),
  4: Offset(0.208, 0.230),
};

void main() {
  test('fitted capture provenance survives removing the original sample', () {
    final GalLookupCalibrationDraft draft = GalLookupCalibrationDraft(
      rect: _rect,
      layout: _layout,
      samples: const [],
      layoutReferenceClient: _client,
      layoutCaptureMetadata: _metadata,
    );
    final GalLookupCalibrationDraft restored =
        GalLookupCalibrationDraft.fromJson(draft.toJson());
    expect(restored.validFor(_sha), isTrue);
    expect(restored.layoutCaptureMetadata!.toJson(), _metadata.toJson());
    final GalLookupCalibrationDraft mismatch = GalLookupCalibrationDraft(
      rect: _rect,
      layout: _layout,
      samples: const [],
      layoutReferenceClient: const GalLookupReferenceClientV1(
        widthPx: 800,
        heightPx: 600,
        dpi: 96,
      ),
      layoutCaptureMetadata: _metadata,
    );
    expect(mismatch.validFor(_sha), isFalse);
  });

  test(
    'search crop and fitted layout survive independently, including legacy drafts',
    () {
      final GalLookupCalibrationDraft original = _draft(<GalCalibrationSample>[
        _sample(),
      ]);
      final Map<String, Object?> legacy = original.toJson()
        ..remove('searchRect')
        ..remove('layoutReferenceClient');
      expect(
        GalLookupCalibrationDraft.fromJson(legacy).searchRect,
        original.rect,
      );
      expect(
        GalLookupCalibrationDraft.fromJson(legacy).layoutReferenceClient,
        original.samples.first.capture.referenceClient,
      );
      const GalLookupNormalizedRectV1 search = GalLookupNormalizedRectV1(
        left: .05,
        top: .1,
        width: .8,
        height: .6,
      );
      final GalLookupCalibrationDraft draft = GalLookupCalibrationDraft(
        rect: original.rect,
        searchRect: search,
        layout: original.layout,
        samples: original.samples,
        layoutReferenceClient: const GalLookupReferenceClientV1(
          widthPx: 1600,
          heightPx: 900,
          dpi: 144,
        ),
      );
      final GalLookupCalibrationDraft restored =
          GalLookupCalibrationDraft.fromJson(draft.toJson());
      expect(restored.rect, original.rect);
      expect(restored.searchRect, search);
      expect(
        restored.layoutReferenceClient,
        const GalLookupReferenceClientV1(
          widthPx: 1600,
          heightPx: 900,
          dpi: 144,
        ),
      );
      final Map<String, Object?> invalid = draft.toJson()
        ..['searchRect'] = <String, Object?>{'left': -1};
      expect(
        () => GalLookupCalibrationDraft.fromJson(invalid),
        throwsFormatException,
      );
      final Map<String, Object?> invalidReference = draft.toJson()
        ..['layoutReferenceClient'] = <String, Object?>{'widthPx': 0};
      expect(
        () => GalLookupCalibrationDraft.fromJson(invalidReference),
        throwsFormatException,
      );
      final Map<String, Object?> unknown = draft.toJson()
        ..['futureField'] = true;
      expect(
        () => GalLookupCalibrationDraft.fromJson(unknown),
        throwsFormatException,
      );
    },
  );
  group('private calibration draft storage', () {
    late Directory directory;
    late GalLookupCalibrationStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('fushi-calibration-');
      store = GalLookupCalibrationStore(directory: directory);
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test(
      'missing draft is empty and saved samples survive replacement',
      () async {
        expect(await store.load(_sha), isNull);
        final GalCalibrationSample reference = _sample(anchors: _targetPoints);
        final GalCalibrationSample validation = _sample(
          text: 'FGHIJ',
          occurrenceId: 'synthetic-entry-2',
          validation: true,
          anchors: const <int, Offset>{2: Offset(0.15, 0.22)},
        );
        await store.save(_sha, _draft(<GalCalibrationSample>[reference]));
        await store.save(
          _sha,
          _draft(<GalCalibrationSample>[reference, validation]),
        );

        final GalLookupCalibrationDraft restored = (await store.load(_sha))!;
        expect(restored.rect, _rect);
        expect(restored.layout, _layout);
        expect(restored.samples, hasLength(2));
        expect(restored.samples.first.anchors, _targetPoints);
        expect(restored.samples.first.capture.pngBytes, _png);
        expect(
          restored.samples.first.capture.occurrenceId,
          'synthetic-entry-1',
        );
        expect(restored.samples.first.capture.sourceSequence, 17);
        expect(
          restored.samples.first.capture.captureMetadata!.clientLeftPx,
          -300,
        );
        expect(restored.samples.last.validation, isTrue);
        expect(restored.samples.last.capture.sourceText, 'FGHIJ');
        expect(
          await directory.list().length,
          1,
          reason: 'No pending file remains',
        );
      },
    );

    test(
      'wrong executable cannot replace or load another game draft',
      () async {
        await store.save(_sha, _draft(<GalCalibrationSample>[_sample()]));
        await expectLater(
          store.save(
            _sha,
            _draft(<GalCalibrationSample>[_sample(sha: _otherSha)]),
          ),
          throwsFormatException,
        );
        expect(
          (await store.load(_sha))!.samples.single.capture.exeSha256,
          _sha,
        );

        final File file = File(
          '${directory.path}${Platform.pathSeparator}$_sha.json',
        );
        final Map<String, dynamic> json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        (json['samples'] as List<dynamic>).single['capture']['exeSha256'] =
            _otherSha;
        await file.writeAsString(jsonEncode(json));
        await expectLater(store.load(_sha), throwsFormatException);
        await expectLater(store.load('../outside'), throwsFormatException);
      },
    );

    test(
      'ninth sample is refused without overwriting the saved draft',
      () async {
        final GalCalibrationSample sample = _sample();
        await store.save(_sha, _draft(<GalCalibrationSample>[sample]));
        final GalLookupCalibrationDraft oversized = _draft(
          List<GalCalibrationSample>.filled(9, sample),
        );
        await expectLater(store.save(_sha, oversized), throwsFormatException);
        expect((await store.load(_sha))!.samples, hasLength(1));
        expect(
          () => GalLookupCalibrationDraft.fromJson(oversized.toJson()),
          throwsFormatException,
        );
      },
    );

    test('combined screenshot budget is enforced before writing', () async {
      await store.save(_sha, _draft(<GalCalibrationSample>[_sample()]));
      final Uint8List largePng = Uint8List(12 * 1024 * 1024)
        ..setRange(0, _png.length, _png);
      final GalCalibrationSample largeSample = _sample(png: largePng);
      final GalLookupCalibrationDraft oversized = _draft(
        List<GalCalibrationSample>.filled(6, largeSample),
      );
      await expectLater(store.save(_sha, oversized), throwsFormatException);
      expect((await store.load(_sha))!.samples.single.capture.pngBytes, _png);
    });

    test(
      'slot files are isolated and legacy drafts remain readable seeds',
      () async {
        final GalCalibrationSample reference = _sample();
        final GalLookupCalibrationDraft legacy = _draft(<GalCalibrationSample>[
          reference,
        ]);
        await store.save(_sha, legacy);
        final GalLookupCalibrationDraft? legacySeed = await store.load(
          _sha,
          slot: GalLookupCalibrationSlotV1.dialogue,
        );
        expect(legacySeed?.slot, isNull);

        final GalLookupCalibrationDraft dialogue = _draft(
          <GalCalibrationSample>[reference],
          slot: GalLookupCalibrationSlotV1.dialogue,
        );
        await store.save(
          _sha,
          dialogue,
          slot: GalLookupCalibrationSlotV1.dialogue,
        );
        expect(
          (await store.load(
            _sha,
            slot: GalLookupCalibrationSlotV1.dialogue,
          ))?.slot,
          GalLookupCalibrationSlotV1.dialogue,
        );
        expect(
          (await store.load(
            _sha,
            slot: GalLookupCalibrationSlotV1.narration,
          ))?.slot,
          isNull,
        );
        expect((await store.load(_sha))?.slot, isNull);
      },
    );

    test('a fixed slot accepts at most one sample', () async {
      final GalLookupCalibrationDraft invalid = _draft(<GalCalibrationSample>[
        _sample(),
        _sample(occurrenceId: 'second'),
      ], slot: GalLookupCalibrationSlotV1.dialogue);
      expect(invalid.validFor(_sha), isFalse);
      await expectLater(store.save(_sha, invalid), throwsFormatException);
    });

    test(
      'an unreadable slot draft is not overwritten by a new capture',
      () async {
        final GalLookupCalibrationDraft draft = _draft(<GalCalibrationSample>[
          _sample(),
        ], slot: GalLookupCalibrationSlotV1.dialogue);
        await store.save(_sha, draft);
        final File file = File('${directory.path}/$_sha.dialogue.json');
        final Map<String, Object?> unsupported = draft.toJson()
          ..['version'] = 2;
        final String original = jsonEncode(unsupported);
        await file.writeAsString(original);
        await expectLater(
          store.load(_sha, slot: draft.slot),
          throwsFormatException,
        );
        await expectLater(store.save(_sha, draft), throwsFormatException);
        expect(await file.readAsString(), original);
      },
    );
  });

  test('leaving measured grid clears its character advances', () {
    const GalLookupTextLayoutV1 layout = GalLookupTextLayoutV1(
      cellGrid: GalLookupCellGridV1(
        advancePerClientHeight: .03,
        lineAdvancePerClientHeight: .04,
        cellHeightPerClientHeight: .035,
        columns: 24,
        continuationIndent: 0,
        quotedContinuationIndent: 1,
      ),
      characterAdvances: [
        GalLookupCharacterAdvanceV1(codePoint: 0x3001, advanceRatio: .5),
      ],
    );
    final GalLookupTextLayoutV1 manual = copyGalCalibrationLayout(
      layout,
      clearCellGrid: true,
    );
    expect(manual.cellGrid, isNull);
    expect(manual.characterAdvances, isEmpty);
    expect(manual.isValid, isTrue);
  });

  group('fitting marked characters', () {
    test('redundant marks limit one misclick without erasing it', () async {
      final Map<int, Offset> points = <int, Offset>{
        for (int i = 0; i < 8; i++) i: Offset((120 + 22 * i) / 1000, 115 / 500),
      };
      // An erroneous far-end mark has high leverage in ordinary least squares.
      points[7] = points[7]! + const Offset(0.06, 0.04);
      final GalLookupCalibrationDraft draft = _draft(<GalCalibrationSample>[
        _sample(text: 'ABCDEFGH', anchors: points),
      ]);
      final GalLookupCalibrationDraft result = (await fitGalCalibrationAnchors(
        draft,
        build: _linearPreview,
      ))!;
      expect(result.rect.left * 1000, closeTo(115, 1));
      expect(result.rect.top * 500, closeTo(105, 1));
      expect(result.layout.letterSpacingPerClientHeight * 500, closeTo(2, 0.1));
      expect(
        result.samples.single.anchors,
        points,
        reason: 'All marks remain visible and editable, including the outlier',
      );
    });

    test('anchor fitting preserves the fixed calibration slot', () async {
      final GalLookupCalibrationDraft result = (await fitGalCalibrationAnchors(
        _draft(<GalCalibrationSample>[
          _sample(anchors: _targetPoints),
        ], slot: GalLookupCalibrationSlotV1.dialogue),
        build: _linearPreview,
      ))!;
      expect(result.slot, GalLookupCalibrationSlotV1.dialogue);
    });

    test(
      'small marking noise is shared across multiple training samples',
      () async {
        const List<double> noise = <double>[
          0.5,
          -0.8,
          0.3,
          -0.4,
          0.7,
          -0.3,
          0.2,
          -0.2,
        ];
        final List<GalCalibrationSample> samples = <GalCalibrationSample>[
          for (int sample = 0; sample < 2; sample++)
            _sample(
              text: 'ABCDEFGH',
              anchors: <int, Offset>{
                for (int i = sample * 4; i < sample * 4 + 4; i++)
                  i: Offset(
                    (120 + 22 * i + noise[i]) / 1000,
                    (115 + noise[7 - i]) / 500,
                  ),
              },
            ),
          _sample(
            text: 'VALIDATION',
            validation: true,
            anchors: const <int, Offset>{
              0: Offset(0.8, 0.8),
              8: Offset(0.9, 0.9),
            },
          ),
        ];
        final GalLookupCalibrationDraft result =
            (await fitGalCalibrationAnchors(
              _draft(samples),
              build: _linearPreview,
            ))!;
        final GalCalibrationPreview preview = await _linearPreview(
          text: 'VALIDATION',
          client: _client,
          rect: result.rect,
          layout: result.layout,
        );
        expect(preview.boxForIndex(8)!.rect.center.dx, closeTo(296, 1));
        expect(preview.boxForIndex(8)!.rect.center.dy, closeTo(115, 1));
      },
    );

    test(
      'two separated characters determine translation and tracking',
      () async {
        final GalLookupCalibrationDraft original = _draft(
          <GalCalibrationSample>[_sample(anchors: _targetPoints)],
        );
        final GalLookupCalibrationDraft result =
            (await fitGalCalibrationAnchors(original, build: _linearPreview))!;
        expect(result.rect.left, closeTo(0.115, 1e-9));
        expect(result.rect.top, closeTo(0.210, 1e-9));
        expect(
          result.layout.letterSpacingPerClientHeight,
          closeTo(0.004, 1e-9),
        );
        expect(result.rect.width, original.rect.width);
        expect(result.rect.height, original.rect.height);
        expect(result.layout.fontFamily, original.layout.fontFamily);
        expect(
          result.layout.fontSizePerClientHeight,
          original.layout.fontSizePerClientHeight,
        );
        expect(result.layout.lineHeight, original.layout.lineHeight);
        expect(
          original.rect,
          _rect,
          reason: 'Fitting does not mutate the draft',
        );

        final GalCalibrationPreview preview = await _linearPreview(
          text: 'ABCDE',
          client: _client,
          rect: result.rect,
          layout: result.layout,
        );
        expect(preview.boxForIndex(0)!.rect.center.dx, closeTo(120, 1e-8));
        expect(preview.boxForIndex(4)!.rect.center.dx, closeTo(208, 1e-8));
        expect(preview.boxForIndex(4)!.rect.center.dy, closeTo(115, 1e-8));
      },
    );

    test(
      'held-out points remain available but cannot influence the fit',
      () async {
        final List<String> rendered = <String>[];
        final GalCalibrationSample validation = _sample(
          text: 'HELDOUT',
          validation: true,
          anchors: const <int, Offset>{
            0: Offset(0.8, 0.8),
            4: Offset(0.9, 0.9),
          },
        );
        final GalLookupCalibrationDraft result =
            (await fitGalCalibrationAnchors(
              _draft(<GalCalibrationSample>[
                _sample(anchors: _targetPoints),
                validation,
              ]),
              build:
                  ({
                    required String text,
                    required GalLookupReferenceClientV1 client,
                    required GalLookupNormalizedRectV1 rect,
                    required GalLookupTextLayoutV1 layout,
                  }) async {
                    rendered.add(text);
                    return _linearPreview(
                      text: text,
                      client: client,
                      rect: rect,
                      layout: layout,
                    );
                  },
            ))!;
        expect(
          rendered,
          contains('HELDOUT'),
          reason: 'Held-out layout is checked',
        );
        expect(result.rect.left, closeTo(0.115, 1e-9));
        expect(
          result.layout.letterSpacingPerClientHeight,
          closeTo(0.004, 1e-9),
        );
        expect(result.samples.last, same(validation));
      },
    );

    test(
      'held-out overflow refuses the fit without changing the draft',
      () async {
        final GalLookupCalibrationDraft original = _draft(
          <GalCalibrationSample>[
            _sample(anchors: _targetPoints),
            _sample(text: 'HELDOUT', validation: true),
          ],
        );
        final GalLookupCalibrationDraft? fitted =
            await fitGalCalibrationAnchors(
              original,
              build:
                  ({
                    required String text,
                    required GalLookupReferenceClientV1 client,
                    required GalLookupNormalizedRectV1 rect,
                    required GalLookupTextLayoutV1 layout,
                  }) async {
                    if (text == 'HELDOUT' &&
                        layout.letterSpacingPerClientHeight > 0) {
                      return const GalCalibrationPreview(
                        boxes: <GalCalibrationBox>[],
                        reason: 'text_does_not_fit',
                      );
                    }
                    return _linearPreview(
                      text: text,
                      client: client,
                      rect: rect,
                      layout: layout,
                    );
                  },
            );
        expect(fitted, isNull);
        expect(original.rect, _rect);
        expect(original.layout, _layout);
        expect(original.samples.last.validation, isTrue);
      },
    );

    test('a single point or only held-out points cannot train a fit', () async {
      for (final GalCalibrationSample sample in <GalCalibrationSample>[
        _sample(anchors: const <int, Offset>{0: Offset(0.12, 0.23)}),
        _sample(anchors: _targetPoints, validation: true),
      ]) {
        expect(
          await fitGalCalibrationAnchors(
            _draft(<GalCalibrationSample>[sample]),
            build: _linearPreview,
          ),
          isNull,
        );
      }
    });

    test(
      'points on different lines cannot establish character spacing',
      () async {
        final GalLookupCalibrationDraft? result =
            await fitGalCalibrationAnchors(
              _draft(<GalCalibrationSample>[_sample(anchors: _targetPoints)]),
              build:
                  ({
                    required String text,
                    required GalLookupReferenceClientV1 client,
                    required GalLookupNormalizedRectV1 rect,
                    required GalLookupTextLayoutV1 layout,
                  }) async {
                    final GalCalibrationPreview preview = await _linearPreview(
                      text: text,
                      client: client,
                      rect: rect,
                      layout: layout,
                    );
                    return GalCalibrationPreview(
                      boxes: <GalCalibrationBox>[
                        for (final GalCalibrationBox box in preview.boxes)
                          GalCalibrationBox(
                            box.charIndex,
                            box.charLength,
                            box.rect.shift(
                              Offset(0, box.charIndex == 4 ? 40 : 0),
                            ),
                          ),
                      ],
                    );
                  },
            );
        expect(result, isNull);
      },
    );

    for (final bool duringDerivative in <bool>[true, false]) {
      test(
        'rejects wrapping ${duringDerivative ? 'during measurement' : 'after fitting'}',
        () async {
          final GalLookupCalibrationDraft? result =
              await fitGalCalibrationAnchors(
                _draft(<GalCalibrationSample>[_sample(anchors: _targetPoints)]),
                build:
                    ({
                      required String text,
                      required GalLookupReferenceClientV1 client,
                      required GalLookupNormalizedRectV1 rect,
                      required GalLookupTextLayoutV1 layout,
                    }) async {
                      final GalCalibrationPreview preview =
                          await _linearPreview(
                            text: text,
                            client: client,
                            rect: rect,
                            layout: layout,
                          );
                      final bool wrap = duringDerivative
                          ? layout.letterSpacingPerClientHeight < 0
                          : layout.letterSpacingPerClientHeight > 0;
                      return GalCalibrationPreview(
                        boxes: <GalCalibrationBox>[
                          for (final GalCalibrationBox box in preview.boxes)
                            GalCalibrationBox(
                              box.charIndex,
                              box.charLength,
                              box.rect.shift(
                                Offset(0, wrap && box.charIndex == 4 ? 40 : 0),
                              ),
                            ),
                        ],
                      );
                    },
              );
          expect(result, isNull);
        },
      );
    }

    test(
      'rejects a fit when the renderer makes the marked error worse',
      () async {
        final GalLookupCalibrationDraft? result =
            await fitGalCalibrationAnchors(
              _draft(<GalCalibrationSample>[_sample(anchors: _targetPoints)]),
              build:
                  ({
                    required String text,
                    required GalLookupReferenceClientV1 client,
                    required GalLookupNormalizedRectV1 rect,
                    required GalLookupTextLayoutV1 layout,
                  }) async {
                    final GalCalibrationPreview preview = await _linearPreview(
                      text: text,
                      client: client,
                      rect: rect,
                      layout: layout,
                    );
                    final double nonlinearShift =
                        layout.letterSpacingPerClientHeight > 0 ? 50 : 0;
                    return GalCalibrationPreview(
                      boxes: <GalCalibrationBox>[
                        for (final GalCalibrationBox box in preview.boxes)
                          GalCalibrationBox(
                            box.charIndex,
                            box.charLength,
                            box.rect.shift(Offset(nonlinearShift, 0)),
                          ),
                      ],
                    );
                  },
            );
        expect(result, isNull);
      },
    );
  });
}
