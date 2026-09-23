import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';

const String _shaA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

GalLookupSurfaceVariantV1 variant({
  int width = 1920,
  int height = 1080,
  GalLookupNormalizedRectV1 bodyRect =
      GalAttachedTextController.defaultBodyRect,
  GalLookupCalibrationSlotV1? slot,
}) {
  final GalLookupReferenceClientV1 client = GalLookupReferenceClientV1(
    widthPx: width,
    heightPx: height,
    dpi: 144,
  );
  return GalLookupSurfaceVariantV1(
    aspectRatio: client.aspectRatio,
    referenceClient: client,
    bodyRect: bodyRect,
    layout: const GalLookupTextLayoutV1(),
    slot: slot,
  );
}

GalLookupSurfaceProfileV1 profile({
  GalLookupSurfaceMode mode = GalLookupSurfaceMode.attachedOnly,
  bool accepted = true,
  List<GalLookupSurfaceVariantV1>? variants,
}) => GalLookupSurfaceProfileV1(
  exePath: r'C:/Games/Test/game.exe',
  exeSha256: _shaA,
  mode: mode,
  unsafeLeftClickAccepted: accepted,
  variants: variants ?? <GalLookupSurfaceVariantV1>[variant()],
);

void main() {
  test('exact v1 top-level schema and path-key identity round-trip', () {
    final Map<String, Object?> json = profile().toJson();
    expect(json.keys.toSet(), <String>{
      'schemaVersion',
      'exePath',
      'exeSha256',
      'mode',
      'unsafeLeftClickAccepted',
      'variants',
    });
    expect(json['mode'], 'attachedOnly');
    expect(json['exePath'], r'c:\games\test\game.exe');
    expect(GalLookupSurfaceProfileV1.tryFromJson(json)?.toJson(), json);
    expect(
      GalLookupSurfaceProfileV1.preferenceKeyForExePath(
        r'C:/Games/Test/game.exe',
      ),
      r'gal_lookup_surface_v1::c:\games\test\game.exe',
    );
    expect(
      GalLookupSurfaceProfileV1.preferenceKeyForExePath(
        r'\\Server//Share///Game.exe',
      ),
      r'gal_lookup_surface_v1::\\server\share\game.exe',
    );
  });

  test(
    'all four mode wire values are closed and unknown mode rejects profile',
    () {
      expect(
        GalLookupSurfaceMode.values.map(
          (GalLookupSurfaceMode mode) => mode.wireName,
        ),
        <String>['auto', 'nativeOnly', 'attachedOnly', 'off'],
      );
      final Map<String, Object?> invalid = profile().toJson()
        ..['mode'] = 'futureMode';
      expect(GalLookupSurfaceProfileV1.tryFromJson(invalid), isNull);
    },
  );

  test('fixed default rect and layout match plan', () {
    expect(
      GalAttachedTextController.defaultBodyRect,
      const GalLookupNormalizedRectV1(
        left: 0.08,
        top: 0.68,
        width: 0.84,
        height: 0.24,
      ),
    );
    expect(const GalLookupTextLayoutV1().toJson(), <String, Object?>{
      'fontFamily': '',
      'fontSizePerClientHeight': 0.045,
      'letterSpacingPerClientHeight': 0.0,
      'lineHeight': 1.0,
      'textAlign': 'left',
      'verticalAlign': 'top',
      'paddingPerClientHeight': 0.0,
    });
  });

  test('quote-only grid source keeps Hook line breaks and legacy defaults', () {
    const String source = '軽音部員「じゃあベースは？\r\nキーボードは？\nそもそも？」後続';
    expect(
      galLookupGridSourceText(source, quotedTextOnly: true),
      '「じゃあベースは？\r\nキーボードは？\nそもそも？」',
    );
    expect(
      galLookupGridSourceText('軽音部員「途中\n次行', quotedTextOnly: true),
      '「途中\n次行',
    );
    expect(galLookupGridSourceText('旁白\n第二行', quotedTextOnly: true), '旁白\n第二行');
    expect(galLookupGridSourceText(source, quotedTextOnly: false), source);
    const GalLookupTextLayoutV1 enabled = GalLookupTextLayoutV1(
      quotedTextOnly: true,
    );
    expect(enabled.toJson()['quotedTextOnly'], true);
    expect(GalLookupTextLayoutV1.tryFromJson(enabled.toJson()), enabled);
    expect(
      const GalLookupTextLayoutV1().toJson().containsKey('quotedTextOnly'),
      isFalse,
    );
    expect(
      GalLookupTextLayoutV1.tryFromJson(
        Map<String, Object?>.of(enabled.toJson())..['quotedTextOnly'] = 'true',
      ),
      isNull,
    );
  });

  test(
    'optional cell grid round-trips without changing legacy layout JSON',
    () {
      const GalLookupCellGridV1 grid = GalLookupCellGridV1(
        advancePerClientHeight: 0.03,
        lineAdvancePerClientHeight: 0.04,
        cellHeightPerClientHeight: 0.035,
        columns: 24,
        continuationIndent: 2,
        quotedContinuationIndent: 3,
      );
      const GalLookupTextLayoutV1 layout = GalLookupTextLayoutV1(
        cellGrid: grid,
      );
      expect(grid.isValid, isTrue);
      expect(layout.isValid, isTrue);
      expect(layout.toJson()['cellGrid'], grid.toJson());
      expect(GalLookupTextLayoutV1.tryFromJson(layout.toJson()), layout);
      expect(
        const GalLookupTextLayoutV1().toJson().containsKey('cellGrid'),
        isFalse,
      );
    },
  );

  test(
    'cell grid accepts legacy JSON and strictly round-trips hanging mode',
    () {
      const GalLookupCellGridV1 legacyGrid = GalLookupCellGridV1(
        advancePerClientHeight: 0.03,
        lineAdvancePerClientHeight: 0.04,
        cellHeightPerClientHeight: 0.035,
        columns: 24,
        continuationIndent: 2,
        quotedContinuationIndent: 3,
      );
      final Map<String, Object?> legacyJson = legacyGrid.toJson();
      expect(legacyJson.containsKey('hangingPunctuation'), isFalse);
      expect(legacyJson.containsKey('trimWrapWhitespace'), isFalse);
      expect(GalLookupCellGridV1.tryFromJson(legacyJson), legacyGrid);
      final Map<String, Object?> explicitFalse = Map<String, Object?>.of(
        legacyJson,
      )..['hangingPunctuation'] = false;
      expect(GalLookupCellGridV1.tryFromJson(explicitFalse), legacyGrid);
      final Map<String, Object?> explicitTrimFalse = Map<String, Object?>.of(
        legacyJson,
      )..['trimWrapWhitespace'] = false;
      expect(GalLookupCellGridV1.tryFromJson(explicitTrimFalse), legacyGrid);

      const GalLookupCellGridV1 hangingGrid = GalLookupCellGridV1(
        advancePerClientHeight: 0.03,
        lineAdvancePerClientHeight: 0.04,
        cellHeightPerClientHeight: 0.035,
        columns: 24,
        continuationIndent: 2,
        quotedContinuationIndent: 3,
        hangingPunctuation: true,
      );
      final Map<String, Object?> hangingJson = hangingGrid.toJson();
      expect(hangingJson['hangingPunctuation'], true);
      expect(GalLookupCellGridV1.tryFromJson(hangingJson), hangingGrid);
      expect(hangingGrid, isNot(legacyGrid));
      expect(hangingGrid.hashCode, isNot(legacyGrid.hashCode));

      const GalLookupCellGridV1 trimmedGrid = GalLookupCellGridV1(
        advancePerClientHeight: 0.03,
        lineAdvancePerClientHeight: 0.04,
        cellHeightPerClientHeight: 0.035,
        columns: 24,
        continuationIndent: 2,
        quotedContinuationIndent: 3,
        hangingPunctuation: true,
        trimWrapWhitespace: true,
        lineWidthInCells: 23.5,
      );
      final Map<String, Object?> trimmedJson = trimmedGrid.toJson();
      expect(trimmedJson['trimWrapWhitespace'], true);
      expect(GalLookupCellGridV1.tryFromJson(trimmedJson), trimmedGrid);
      expect(trimmedGrid, isNot(hangingGrid));
      expect(trimmedGrid.hashCode, isNot(hangingGrid.hashCode));

      final Map<String, Object?> wrongType = Map<String, Object?>.of(
        hangingJson,
      )..['hangingPunctuation'] = 1;
      expect(GalLookupCellGridV1.tryFromJson(wrongType), isNull);
      final Map<String, Object?> wrongTrimType = Map<String, Object?>.of(
        trimmedJson,
      )..['trimWrapWhitespace'] = 1;
      expect(GalLookupCellGridV1.tryFromJson(wrongTrimType), isNull);
      final Map<String, Object?> unknown = Map<String, Object?>.of(legacyJson)
        ..['unexpected'] = false;
      expect(GalLookupCellGridV1.tryFromJson(unknown), isNull);
    },
  );

  test(
    'cell grid preserves fractional continuation indents and old integers',
    () {
      const GalLookupCellGridV1 fractionalGrid = GalLookupCellGridV1(
        advancePerClientHeight: 0.03,
        lineAdvancePerClientHeight: 0.04,
        cellHeightPerClientHeight: 0.035,
        columns: 24,
        continuationIndent: 0.5,
        quotedContinuationIndent: 1.5,
      );
      expect(fractionalGrid.isValid, isTrue);
      final Map<String, Object?> fractionalJson = fractionalGrid.toJson();
      expect(fractionalJson['continuationIndent'], 0.5);
      expect(fractionalJson['quotedContinuationIndent'], 1.5);
      expect(GalLookupCellGridV1.tryFromJson(fractionalJson), fractionalGrid);

      final Map<String, Object?> legacyJson =
          Map<String, Object?>.of(fractionalJson)
            ..['continuationIndent'] = 2
            ..['quotedContinuationIndent'] = 3;
      expect(
        GalLookupCellGridV1.tryFromJson(legacyJson),
        const GalLookupCellGridV1(
          advancePerClientHeight: 0.03,
          lineAdvancePerClientHeight: 0.04,
          cellHeightPerClientHeight: 0.035,
          columns: 24,
          continuationIndent: 2,
          quotedContinuationIndent: 3,
        ),
      );

      final Map<String, Object?> hangingIndent =
          Map<String, Object?>.of(fractionalJson)
            ..['continuationIndent'] = -1
            ..['quotedContinuationIndent'] = -1;
      final GalLookupCellGridV1 restored = GalLookupCellGridV1.tryFromJson(
        hangingIndent,
      )!;
      expect(restored.continuationIndent, -1);
      expect(restored.quotedContinuationIndent, -1);
      expect(GalLookupCellGridV1.tryFromJson(restored.toJson()), restored);
      for (final Object? missing in <Object?>[null, 'invalid']) {
        expect(
          GalLookupCellGridV1.tryFromJson(
            Map<String, Object?>.of(hangingIndent)
              ..['continuationIndent'] = missing,
          ),
          isNull,
        );
      }

      for (final double invalid in <double>[
        -1.01,
        double.nan,
        double.infinity,
      ]) {
        final Map<String, Object?> invalidJson = Map<String, Object?>.of(
          fractionalJson,
        )..['continuationIndent'] = invalid;
        expect(GalLookupCellGridV1.tryFromJson(invalidJson), isNull);
      }
      final Map<String, Object?> outOfRange = Map<String, Object?>.of(
        fractionalJson,
      )..['quotedContinuationIndent'] = 8.01;
      expect(GalLookupCellGridV1.tryFromJson(outOfRange), isNull);
    },
  );

  test(
    'punctuation visual bounds round-trip without changing the cell grid',
    () {
      const GalLookupCellGridV1 grid = GalLookupCellGridV1(
        advancePerClientHeight: 0.03,
        lineAdvancePerClientHeight: 0.04,
        cellHeightPerClientHeight: 0.035,
        columns: 24,
        continuationIndent: 2,
        quotedContinuationIndent: 3,
      );
      const GalLookupPunctuationVisualBoundV1 bound =
          GalLookupPunctuationVisualBoundV1(
            codePoint: 0x3002,
            left: 0.35,
            top: 0.55,
            right: 0.65,
            bottom: 0.95,
          );
      const GalLookupTextLayoutV1 layout = GalLookupTextLayoutV1(
        cellGrid: grid,
        punctuationVisualBounds: <GalLookupPunctuationVisualBoundV1>[bound],
      );
      expect(bound.isValid, isTrue);
      expect(layout.isValid, isTrue);
      final Map<String, Object?> json = layout.toJson();
      expect(json['punctuationVisualBounds'], <Map<String, Object?>>[
        bound.toJson(),
      ]);
      expect(GalLookupTextLayoutV1.tryFromJson(json), layout);
      expect(
        const GalLookupTextLayoutV1().toJson().containsKey(
          'punctuationVisualBounds',
        ),
        isFalse,
      );

      final Map<String, Object?> invalid = Map<String, Object?>.of(json)
        ..['punctuationVisualBounds'] = <Object?>[
          <String, Object?>{...bound.toJson(), 'codePoint': 0x3042},
        ];
      expect(GalLookupTextLayoutV1.tryFromJson(invalid), isNull);
      final Map<String, Object?> supplementary = Map<String, Object?>.of(json)
        ..['punctuationVisualBounds'] = <Object?>[
          <String, Object?>{...bound.toJson(), 'codePoint': 0x1f4a9},
        ];
      expect(GalLookupTextLayoutV1.tryFromJson(supplementary), isNull);
      final Map<String, Object?> outOfCell = Map<String, Object?>.of(json)
        ..['punctuationVisualBounds'] = <Object?>[
          <String, Object?>{...bound.toJson(), 'right': 1.1},
        ];
      expect(GalLookupTextLayoutV1.tryFromJson(outOfCell), isNull);
    },
  );

  test('present but malformed cell grid rejects the complete layout', () {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.03,
      lineAdvancePerClientHeight: 0.04,
      cellHeightPerClientHeight: 0.035,
      columns: 24,
      continuationIndent: 2,
      quotedContinuationIndent: 3,
    );
    final Map<String, Object?> valid = const GalLookupTextLayoutV1(
      cellGrid: grid,
    ).toJson();
    Map<String, Object?> withGrid(
      void Function(Map<String, Object?> grid) mutate,
    ) {
      final Map<String, Object?> result = Map<String, Object?>.of(valid);
      final Map<String, Object?> gridMap = Map<String, Object?>.of(
        (valid['cellGrid']! as Map<Object?, Object?>).cast<String, Object?>(),
      );
      mutate(gridMap);
      result['cellGrid'] = gridMap;
      return result;
    }

    final Map<String, Object?> missing = withGrid(
      (Map<String, Object?> grid) => grid.remove('columns'),
    );
    expect(GalLookupTextLayoutV1.tryFromJson(missing), isNull);

    final Map<String, Object?> invalidLineAdvance = withGrid(
      (Map<String, Object?> grid) => grid['lineAdvancePerClientHeight'] = 0.02,
    );
    expect(GalLookupTextLayoutV1.tryFromJson(invalidLineAdvance), isNull);

    final Map<String, Object?> invalidIndent = withGrid(
      (Map<String, Object?> grid) => grid['continuationIndent'] = 9,
    );
    expect(GalLookupTextLayoutV1.tryFromJson(invalidIndent), isNull);
  });

  test('best of multiple variants must be within one-percent aspect error', () {
    final GalLookupSurfaceProfileV1 value = profile(
      variants: <GalLookupSurfaceVariantV1>[
        variant(width: 1280, height: 960),
        variant(width: 1920, height: 1080),
        variant(width: 1600, height: 1000),
      ],
    );
    const GalLookupReferenceClientV1 nearWide = GalLookupReferenceClientV1(
      widthPx: 1770,
      heightPx: 1000,
      dpi: 96,
    );
    expect(
      value.bestVariantForClient(nearWide)?.aspectRatio,
      closeTo(16 / 9, 1e-9),
    );
    expect(
      value.bestVariantForClient(
        const GalLookupReferenceClientV1(
          widthPx: 1700,
          heightPx: 1000,
          dpi: 96,
        ),
      ),
      isNull,
    );
    expect(
      value.bestVariantForClient(
        const GalLookupReferenceClientV1(widthPx: 1280, heightPx: 720, dpi: 96),
      ),
      isNull,
      reason: 'a large same-aspect size jump needs a fresh calibration',
    );
  });

  test(
    'unknown fields, non-finite values, and out-of-bounds rect reject all',
    () {
      final Map<String, Object?> unknown = profile().toJson()
        ..['legacyEnabled'] = true;
      expect(GalLookupSurfaceProfileV1.tryFromJson(unknown), isNull);

      final Map<String, Object?> nonFinite = profile().toJson();
      final List<Object?> variants = nonFinite['variants']! as List<Object?>;
      final Map<String, Object?> first =
          (variants.single! as Map<Object?, Object?>).cast<String, Object?>();
      final Map<String, Object?> layout =
          (first['layout']! as Map<Object?, Object?>).cast<String, Object?>();
      layout['fontSizePerClientHeight'] = double.nan;
      expect(GalLookupSurfaceProfileV1.tryFromJson(nonFinite), isNull);

      final Map<String, Object?> outOfBounds = profile().toJson();
      final Map<String, Object?> variantMap =
          ((outOfBounds['variants']! as List<Object?>).single!
                  as Map<Object?, Object?>)
              .cast<String, Object?>();
      variantMap['bodyRect'] = <String, Object?>{
        'left': 0.8,
        'top': 0.7,
        'width': 0.3,
        'height': 0.4,
      };
      expect(GalLookupSurfaceProfileV1.tryFromJson(outOfBounds), isNull);

      final Map<String, Object?> fractionalSchema = profile().toJson()
        ..['schemaVersion'] = 1.5;
      expect(GalLookupSurfaceProfileV1.tryFromJson(fractionalSchema), isNull);

      final Map<String, Object?> fractionalClient = profile().toJson();
      final Map<String, Object?> client =
          (((fractionalClient['variants']! as List<Object?>).single!
                      as Map<Object?, Object?>)['referenceClient']!
                  as Map<Object?, Object?>)
              .cast<String, Object?>();
      client['widthPx'] = 1920.5;
      expect(GalLookupSurfaceProfileV1.tryFromJson(fractionalClient), isNull);

      final Map<String, Object?> nonStringFont = profile().toJson();
      final Map<String, Object?> fontLayout =
          (((nonStringFont['variants']! as List<Object?>).single!
                      as Map<Object?, Object?>)['layout']!
                  as Map<Object?, Object?>)
              .cast<String, Object?>();
      fontLayout['fontFamily'] = 42;
      expect(GalLookupSurfaceProfileV1.tryFromJson(nonStringFont), isNull);

      // Persisted preferences and MethodChannel payloads are untrusted.  A
      // wrong primitive type must reject the whole profile, never escape as a
      // TypeError that tears down session synchronization.
      final Map<String, Object?> wrongType = profile().toJson();
      final Map<String, Object?> wrongRect =
          (((wrongType['variants']! as List<Object?>).single!
                      as Map<Object?, Object?>)['bodyRect']!
                  as Map<Object?, Object?>)
              .cast<String, Object?>();
      wrongRect['left'] = '0.08';
      expect(
        () => GalLookupSurfaceProfileV1.tryFromJson(wrongType),
        returnsNormally,
      );
      expect(GalLookupSurfaceProfileV1.tryFromJson(wrongType), isNull);
    },
  );

  test('cell-grid variants scale across same-aspect resolution changes', () {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.03,
      lineAdvancePerClientHeight: 0.04,
      cellHeightPerClientHeight: 0.035,
      columns: 24,
      continuationIndent: 0,
      quotedContinuationIndent: 1,
    );
    final GalLookupSurfaceProfileV1 value = profile(
      variants: <GalLookupSurfaceVariantV1>[
        GalLookupSurfaceVariantV1(
          aspectRatio: 16 / 9,
          referenceClient: const GalLookupReferenceClientV1(
            widthPx: 1280,
            heightPx: 720,
            dpi: 96,
          ),
          bodyRect: GalAttachedTextController.defaultBodyRect,
          layout: const GalLookupTextLayoutV1(cellGrid: grid),
        ),
      ],
    );
    expect(
      value.bestVariantForClient(
        const GalLookupReferenceClientV1(
          widthPx: 2560,
          heightPx: 1440,
          dpi: 144,
        ),
      ),
      isNotNull,
    );
  });

  test('dialogue and narration slots select by Japanese quote markers', () {
    final GalLookupSurfaceVariantV1 dialogue = variant(
      slot: GalLookupCalibrationSlotV1.dialogue,
    );
    final GalLookupSurfaceVariantV1 narration = variant(
      slot: GalLookupCalibrationSlotV1.narration,
    );
    final GalLookupSurfaceProfileV1 value = profile(
      variants: <GalLookupSurfaceVariantV1>[dialogue, narration],
    );
    const GalLookupReferenceClientV1 client = GalLookupReferenceClientV1(
      widthPx: 1920,
      heightPx: 1080,
      dpi: 144,
    );
    expect(isGalLookupDialogueText('「外层引号」'), isTrue);
    expect(isGalLookupDialogueText('台词前缀「内嵌引号」后缀'), isTrue);
    expect(isGalLookupDialogueText('「更新中的台词'), isTrue);
    expect(isGalLookupDialogueText('更新中的台词」'), isTrue);
    expect(isGalLookupDialogueText('旁白没有对话引号'), isFalse);
    expect(value.bestVariantForSourceText(client, '「外层引号」'), dialogue);
    expect(value.bestVariantForSourceText(client, '台词前缀「内嵌引号」后缀'), dialogue);
    expect(value.bestVariantForSourceText(client, '旁白没有对话引号'), narration);
  });

  test('one usable slot is the shared fallback for every source text', () {
    final GalLookupSurfaceVariantV1 narration = variant(
      slot: GalLookupCalibrationSlotV1.narration,
    );
    final GalLookupSurfaceProfileV1 value = profile(
      variants: <GalLookupSurfaceVariantV1>[narration],
    );
    const GalLookupReferenceClientV1 client = GalLookupReferenceClientV1(
      widthPx: 1920,
      heightPx: 1080,
      dpi: 144,
    );
    expect(value.bestVariantForSourceText(client, '「对话」'), narration);
    expect(value.bestVariantForSourceText(client, '旁白'), narration);
  });

  test('character advances and fractional line widths round-trip strictly', () {
    const GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: 0.03,
      lineAdvancePerClientHeight: 0.04,
      cellHeightPerClientHeight: 0.035,
      columns: 24,
      continuationIndent: 2,
      quotedContinuationIndent: 3,
      lineWidthInCells: 23.5,
    );
    const GalLookupCharacterAdvanceV1 advance = GalLookupCharacterAdvanceV1(
      codePoint: 0x1f600,
      advanceRatio: 0.75,
    );
    const GalLookupTextLayoutV1 layout = GalLookupTextLayoutV1(
      cellGrid: grid,
      characterAdvances: <GalLookupCharacterAdvanceV1>[advance],
    );
    expect(grid.effectiveLineWidthInCells, 23.5);
    expect(layout.isValid, isTrue);
    expect(GalLookupTextLayoutV1.tryFromJson(layout.toJson()), layout);
    expect(
      GalLookupTextLayoutV1.tryFromJson(
        Map<String, Object?>.of(layout.toJson())..remove('cellGrid'),
      ),
      isNull,
    );
    expect(
      GalLookupCharacterAdvanceV1.tryFromJson(<String, Object?>{
        'codePoint': 0x20,
        'advanceRatio': 0.25,
      }),
      const GalLookupCharacterAdvanceV1(codePoint: 0x20, advanceRatio: 0.25),
    );
    for (final int codePoint in <int>[0x09, 0x0a, 0x3000, 0x200b]) {
      expect(
        GalLookupCharacterAdvanceV1.tryFromJson(<String, Object?>{
          'codePoint': codePoint,
          'advanceRatio': 0.25,
        }),
        isNull,
      );
    }
    expect(
      GalLookupCharacterAdvanceV1.tryFromJson(<String, Object?>{
        'codePoint': 0x1f600,
        'advanceRatio': 2.1,
      }),
      isNull,
    );
  });
}
