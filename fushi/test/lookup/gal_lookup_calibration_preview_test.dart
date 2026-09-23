import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

const GalLookupReferenceClientV1 _client = GalLookupReferenceClientV1(
  widthPx: 800,
  heightPx: 600,
  dpi: 144,
);
const GalLookupNormalizedRectV1 _rect = GalLookupNormalizedRectV1(
  left: 0.1,
  top: 0.7,
  width: 0.8,
  height: 0.2,
);
const GalLookupTextLayoutV1 _layout = GalLookupTextLayoutV1(
  fontFamily: 'Fixture',
);

Map<String, Object?> _box() => <String, Object?>{
  'charIndex': 1,
  'charLength': 2,
  'left': 90,
  'top': 420,
  'right': 120,
  'bottom': 450,
};

Future<GalCalibrationPreview> _build({String text = 'A😀BC'}) =>
    GalLookupCalibrationPreviewChannel.build(
      text: text,
      client: _client,
      rect: _rect,
      layout: _layout,
    );

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  Object? reply;

  setUp(() {
    calls = <MethodCall>[];
    reply = <String, Object?>{
      'accepted': true,
      'boxes': <Object?>[_box()],
    };
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      FushiChannels.galHookText,
      (MethodCall call) async {
        calls.add(call);
        return reply;
      },
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      FushiChannels.galHookText,
      null,
    );
  });

  test('requests native layout without registering a live surface', () async {
    final GalCalibrationPreview preview = await _build();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'attachedPreviewLayout');
    expect(calls.single.arguments, <String, Object?>{
      'sourceText': 'A😀BC',
      'referenceClient': _client.toJson(),
      'bodyRect': _rect.toJson(),
      'layout': _layout.toJson(),
    });
    expect(preview.accepted, isTrue);
    expect(
      preview.boxForIndex(1)!.rect,
      const Rect.fromLTRB(90, 420, 120, 450),
    );
    expect(
      preview.boxForIndex(1)!.visualRect,
      const Rect.fromLTRB(90, 420, 120, 450),
    );
    expect(preview.boxForIndex(2), same(preview.boxForIndex(1)));
    expect(preview.boxForIndex(0), isNull);
    expect(preview.boxForIndex(3), isNull);
    expect(() => preview.boxes.clear(), throwsUnsupportedError);
  });

  test('exposes visual bounds while keeping legacy hit edges', () async {
    reply = <String, Object?>{
      'accepted': true,
      'boxes': <Object?>[
        <String, Object?>{
          ..._box(),
          'visualLeft': 98,
          'visualTop': 428,
          'visualRight': 112,
          'visualBottom': 445,
        },
      ],
    };
    final GalCalibrationPreview preview = await _build();
    final GalCalibrationBox box = preview.boxForIndex(1)!;
    expect(box.hitRect, const Rect.fromLTRB(90, 420, 120, 450));
    expect(box.visualRect, const Rect.fromLTRB(98, 428, 112, 445));
    expect(box.rect, box.hitRect);
  });

  test('invalid inputs never call native layout', () async {
    for (final String text in <String>['', 'A' * 16385]) {
      expect((await _build(text: text)).accepted, isFalse);
    }
    final GalCalibrationPreview invalidClient =
        await GalLookupCalibrationPreviewChannel.build(
          text: 'ABCDE',
          client: const GalLookupReferenceClientV1(
            widthPx: 0,
            heightPx: 600,
            dpi: 96,
          ),
          rect: _rect,
          layout: _layout,
        );
    expect(invalidClient.accepted, isFalse);
    final GalCalibrationPreview invalidArea =
        await GalLookupCalibrationPreviewChannel.build(
          text: 'ABCDE',
          client: _client,
          rect: const GalLookupNormalizedRectV1(
            left: 0.9,
            top: 0,
            width: 0.2,
            height: 0.2,
          ),
          layout: _layout,
        );
    expect(invalidArea.accepted, isFalse);
    final GalCalibrationPreview invalidFont =
        await GalLookupCalibrationPreviewChannel.build(
          text: 'ABCDE',
          client: _client,
          rect: _rect,
          layout: const GalLookupTextLayoutV1(
            fontSizePerClientHeight: double.nan,
          ),
        );
    expect(invalidFont.accepted, isFalse);
    expect(calls, isEmpty);
  });

  test('native rejection preserves its reason and exposes no boxes', () async {
    reply = <String, Object?>{
      'accepted': false,
      'reason': 'text_does_not_fit',
      'boxes': <Object?>[_box()],
    };
    final GalCalibrationPreview preview = await _build();
    expect(preview.accepted, isFalse);
    expect(preview.reason, 'text_does_not_fit');
    expect(preview.boxes, isEmpty);
  });

  test(
    'empty or missing native response cannot become an accepted preview',
    () async {
      for (final Object? response in <Object?>[
        null,
        <String, Object?>{'accepted': true},
        <String, Object?>{'accepted': true, 'boxes': <Object?>[]},
        <String, Object?>{'accepted': true, 'boxes': 'invalid'},
      ]) {
        reply = response;
        final GalCalibrationPreview preview = await _build();
        expect(preview.accepted, isFalse);
        expect(preview.boxes, isEmpty);
      }
    },
  );

  final Map<String, Map<String, Object?>> invalidBoxes =
      <String, Map<String, Object?>>{
        'negative character index': <String, Object?>{'charIndex': -1},
        'character index past text': <String, Object?>{'charIndex': 5},
        'fractional character index': <String, Object?>{'charIndex': 1.5},
        'empty cluster': <String, Object?>{'charLength': 0},
        'cluster past text': <String, Object?>{'charLength': 5},
        'non-numeric edge': <String, Object?>{'left': '90'},
        'non-finite edge': <String, Object?>{'right': double.infinity},
        'NaN edge': <String, Object?>{'top': double.nan},
        'left outside client': <String, Object?>{'left': -1},
        'top outside client': <String, Object?>{'top': -1},
        'right outside client': <String, Object?>{'right': 801},
        'bottom outside client': <String, Object?>{'bottom': 601},
        'zero width': <String, Object?>{'right': 90},
        'inverted height': <String, Object?>{'bottom': 419},
        'visual box outside hit box': <String, Object?>{
          'visualLeft': 89,
          'visualTop': 420,
          'visualRight': 120,
          'visualBottom': 450,
        },
        'partial visual box': <String, Object?>{'visualLeft': 92},
      };
  for (final MapEntry<String, Map<String, Object?>> invalid
      in invalidBoxes.entries) {
    test('rejects ${invalid.key}, including preceding valid boxes', () async {
      reply = <String, Object?>{
        'accepted': true,
        'boxes': <Object?>[_box(), _box()..addAll(invalid.value)],
      };
      final GalCalibrationPreview preview = await _build();
      expect(preview.accepted, isFalse);
      expect(preview.boxes, isEmpty);
      expect(preview.reason, 'invalid_boxes');
    });
  }

  test(
    'rejects a non-map box instead of retaining a partial preview',
    () async {
      reply = <String, Object?>{
        'accepted': true,
        'boxes': <Object?>[_box(), 42],
      };
      final GalCalibrationPreview preview = await _build();
      expect(preview.accepted, isFalse);
      expect(preview.boxes, isEmpty);
    },
  );
}
