import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

const GalAttachedSurfaceTarget _target = GalAttachedSurfaceTarget(
  sessionEpoch: 101,
  surfaceEpoch: 7,
  targetPid: 4242,
  targetHwnd: 0x123456,
);

const List<GalAttachedMeasuredGlyph> _glyphs = <GalAttachedMeasuredGlyph>[
  GalAttachedMeasuredGlyph(
    start: 0,
    length: 1,
    left: 10,
    top: 20,
    right: 40,
    bottom: 52,
  ),
  GalAttachedMeasuredGlyph(
    start: 1,
    length: 2,
    left: 40,
    top: 20,
    right: 70,
    bottom: 52,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String channelName = 'app.fushi.reader/gal_hook_text';
  const MethodChannel channel = MethodChannel(channelName);
  late List<MethodCall> calls;
  late Object? nextReply;

  setUp(() {
    calls = <MethodCall>[];
    nextReply = <String, Object?>{'status': 'ready'};
    GalHookTextOverlayChannel.platformOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return nextReply;
        });
  });

  tearDown(() {
    GalHookTextOverlayChannel.platformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('glyphs encode as a flat Int32List [start,len,l,t,r,b]*n', () {
    final Int32List? words = encodeGalAttachedMeasuredGlyphs(_glyphs);
    expect(words, isNotNull);
    expect(words!.toList(), <int>[0, 1, 10, 20, 40, 52, 1, 2, 40, 20, 70, 52]);
    expect(
      encodeGalAttachedMeasuredGlyphs(const <GalAttachedMeasuredGlyph>[]),
      isEmpty,
    );
    expect(
      encodeGalAttachedMeasuredGlyphs(const <GalAttachedMeasuredGlyph>[
        GalAttachedMeasuredGlyph(
          start: 0,
          length: 1,
          left: 0,
          top: 0,
          right: 0x80000000,
          bottom: 1,
        ),
      ]),
      isNull,
    );
  });

  test(
    'configureMeasured carries epochs, tyrano_dom source and input mode',
    () async {
      final GalAttachedCallResult result =
          await GalHookTextOverlayChannel.attachedConfigureMeasured(
            target: _target,
          );
      expect(result.ok, isTrue);
      expect(calls.single.method, 'attachedConfigureMeasured');
      expect(calls.single.arguments, <String, Object?>{
        ..._target.toMap(),
        'measuredSource': 'tyrano_dom',
        'inputMode': GalLookupSurfaceProfileV1.inputMode,
      });
    },
  );

  test(
    'updateMeasuredText sends text, generation, glyphs and client size',
    () async {
      await GalHookTextOverlayChannel.attachedUpdateMeasuredText(
        target: _target,
        sourceText: '本文です',
        textGeneration: 3,
        glyphs: _glyphs,
        clientWidth: 1280,
        clientHeight: 720,
      );
      final MethodCall call = calls.single;
      expect(call.method, 'attachedUpdateMeasuredText');
      final Map<Object?, Object?> args =
          call.arguments as Map<Object?, Object?>;
      expect(args['sessionEpoch'], 101);
      expect(args['surfaceEpoch'], 7);
      expect(args['targetPid'], 4242);
      expect(args['targetHwnd'], 0x123456);
      expect(args['sourceText'], '本文です');
      expect(args['textGeneration'], 3);
      expect(args['clientWidth'], 1280);
      expect(args['clientHeight'], 720);
      // Must stay an Int32List through the standard codec so the runner reads
      // std::vector<int32_t>.
      expect(args['glyphs'], isA<Int32List>());
      expect((args['glyphs']! as Int32List).toList(), <int>[
        0,
        1,
        10,
        20,
        40,
        52,
        1,
        2,
        40,
        20,
        70,
        52,
      ]);
    },
  );

  test(
    'out-of-range glyph values fail locally without a channel call',
    () async {
      final GalAttachedCallResult result =
          await GalHookTextOverlayChannel.attachedUpdateMeasuredText(
            target: _target,
            sourceText: 'a',
            textGeneration: 1,
            glyphs: const <GalAttachedMeasuredGlyph>[
              GalAttachedMeasuredGlyph(
                start: 0,
                length: 1,
                left: -0x80000001,
                top: 0,
                right: 1,
                bottom: 1,
              ),
            ],
            clientWidth: 10,
            clientHeight: 10,
          );
      expect(result.error, 'measured_glyphs_malformed');
      expect(calls, isEmpty);
    },
  );

  test('runner rejection and measured identity are surfaced', () async {
    nextReply = <String, Object?>{
      'error': 'measured_client_size_mismatch',
      'status': 'measuredLayoutStale',
      'state': 'suspended',
      'layoutSource': 'measured',
      'measuredSource': 'tyrano_dom',
    };
    final GalAttachedCallResult result =
        await GalHookTextOverlayChannel.attachedUpdateMeasuredText(
          target: _target,
          sourceText: 'a',
          textGeneration: 2,
          glyphs: const <GalAttachedMeasuredGlyph>[
            GalAttachedMeasuredGlyph(
              start: 0,
              length: 1,
              left: 0,
              top: 0,
              right: 1,
              bottom: 1,
            ),
          ],
          clientWidth: 800,
          clientHeight: 600,
        );
    expect(result.ok, isFalse);
    expect(result.error, 'measured_client_size_mismatch');
    expect(result.status, 'measuredLayoutStale');
    expect(result.layoutSource, galAttachedLayoutSourceMeasured);
    expect(result.measuredSource, galAttachedMeasuredSourceTyranoDom);
  });

  test('state events default to calibrated and parse measured', () {
    final Map<String, Object?> base = <String, Object?>{
      ..._target.toMap(),
      'state': 'visible',
      'status': 'visible',
    };
    final GalAttachedSurfaceStateEvent? calibrated =
        GalAttachedSurfaceStateEvent.fromMap(base);
    expect(calibrated!.layoutSource, galAttachedLayoutSourceCalibrated);
    expect(calibrated.isMeasured, isFalse);
    expect(calibrated.measuredSource, isNull);

    final GalAttachedSurfaceStateEvent? measured =
        GalAttachedSurfaceStateEvent.fromMap(<String, Object?>{
          ...base,
          'layoutSource': 'measured',
          'measuredSource': 'tyrano_dom',
        });
    expect(measured!.isMeasured, isTrue);
    expect(measured.measuredSource, 'tyrano_dom');

    // Unknown values never masquerade as measured.
    final GalAttachedSurfaceStateEvent? unknown =
        GalAttachedSurfaceStateEvent.fromMap(<String, Object?>{
          ...base,
          'layoutSource': 'guessed',
        });
    expect(unknown!.layoutSource, galAttachedLayoutSourceCalibrated);
  });
}
