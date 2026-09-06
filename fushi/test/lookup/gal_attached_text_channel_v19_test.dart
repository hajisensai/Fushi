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
const GalLookupReferenceClientV1 _client = GalLookupReferenceClientV1(
  widthPx: 1920,
  heightPx: 1080,
  dpi: 144,
);
const GalLookupNormalizedRectV1 _rect = GalLookupNormalizedRectV1(
  left: 0.1,
  top: 0.6,
  width: 0.8,
  height: 0.3,
);
const GalLookupTextLayoutV1 _layout = GalLookupTextLayoutV1();
const String _sha =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const GalAttachedCalibrationProbes _probes = GalAttachedCalibrationProbes(
  startIndex: 0,
  middleIndex: 2,
  endIndex: 4,
  startConfirmed: true,
  middleConfirmed: true,
  endConfirmed: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String channelName = 'app.fushi.reader/gal_hook_text';
  const MethodChannel channel = MethodChannel(channelName);
  const MethodCodec codec = StandardMethodCodec();
  late List<MethodCall> calls;

  Future<void> invokeFromNative(String method, Object? arguments) async {
    final ByteData data = codec.encodeMethodCall(MethodCall(method, arguments));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channelName, data, (_) {});
  }

  setUp(() {
    calls = <MethodCall>[];
    GalHookTextOverlayChannel.platformOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          if (call.method == 'attachedInspectTarget') {
            return <String, Object?>{
              'exePath': r'C:\Games\Sample\game.exe',
              'exeSha256': _sha,
              'referenceClient': _client.toJson(),
              'status': 'inspected',
            };
          }
          return <String, Object?>{'status': 'ready'};
        });
  });

  tearDown(() {
    GalHookTextOverlayChannel.clearEventHandlers();
    GalHookTextOverlayChannel.platformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'all frozen attached calls carry epochs and int64 target identity',
    () async {
      final GalAttachedCallResult inspected =
          await GalHookTextOverlayChannel.attachedInspectTarget(
            _target,
            launchExePath: r'C:\Games\Launcher\start.exe',
          );
      await GalHookTextOverlayChannel.attachedCalibrationStart(
        target: _target,
        bodyRect: _rect,
        referenceClient: _client,
        layout: _layout,
        riskAccepted: true,
      );
      await GalHookTextOverlayChannel.attachedCalibrationUpdate(
        target: _target,
        bodyRect: _rect,
        probes: _probes,
      );
      await GalHookTextOverlayChannel.attachedCalibrationCommit(
        target: _target,
        bodyRect: _rect,
        probes: _probes,
      );
      await GalHookTextOverlayChannel.attachedCalibrationCancel(_target);
      await GalHookTextOverlayChannel.attachedConfigure(
        target: _target,
        variant: GalLookupSurfaceVariantV1(
          aspectRatio: _client.aspectRatio,
          referenceClient: _client,
          bodyRect: _rect,
          layout: _layout,
        ),
        mode: GalLookupSurfaceMode.auto,
        riskAccepted: true,
      );
      await GalHookTextOverlayChannel.attachedUpdateText(
        target: _target,
        sourceText: '本文です',
        textGeneration: 3,
      );
      await GalHookTextOverlayChannel.attachedUpdateStyle(
        target: _target,
        layout: _layout,
      );
      await GalHookTextOverlayChannel.attachedSuspendForCapture(
        target: _target,
        textGeneration: 3,
        captureGeneration: 91,
      );
      await GalHookTextOverlayChannel.attachedRestoreAfterCapture(
        target: _target,
        textGeneration: 3,
        captureGeneration: 91,
      );
      await GalHookTextOverlayChannel.attachedDetach(_target);

      expect(inspected.exeSha256, _sha);
      expect(inspected.referenceClient, _client);
      expect(calls.map((MethodCall call) => call.method), <String>[
        'attachedInspectTarget',
        'attachedCalibrationStart',
        'attachedCalibrationUpdate',
        'attachedCalibrationCommit',
        'attachedCalibrationCancel',
        'attachedConfigure',
        'attachedUpdateText',
        'attachedUpdateStyle',
        'attachedSuspendForCapture',
        'attachedRestoreAfterCapture',
        'attachedDetach',
      ]);
      for (final MethodCall call in calls) {
        final Map<Object?, Object?> args =
            call.arguments! as Map<Object?, Object?>;
        expect(args['sessionEpoch'], 101, reason: call.method);
        expect(args['surfaceEpoch'], 7, reason: call.method);
        expect(args['targetPid'], 4242, reason: call.method);
        expect(args['targetHwnd'], 0x123456, reason: call.method);
      }
      final Map<Object?, Object?> inspect = calls.first.arguments! as Map;
      expect(inspect['launchExePath'], r'C:\Games\Launcher\start.exe');
      final Map<Object?, Object?> configure = calls[5].arguments! as Map;
      expect(configure['bodyRect'], _rect.toJson());
      expect(configure['referenceClient'], _client.toJson());
      expect(configure['layout'], _layout.toJson());
      expect(configure['inputMode'], 'unsafeLeftClick');
      expect(configure['mode'], 'auto');
      expect(configure['riskAccepted'], isTrue);
      final Map<Object?, Object?> calibrationCommit =
          calls[3].arguments! as Map;
      expect(calibrationCommit['probeStartIndex'], 0);
      expect(calibrationCommit['probeMiddleIndex'], 2);
      expect(calibrationCommit['probeEndIndex'], 4);
      expect(calibrationCommit['probeStartConfirmed'], isTrue);
      expect(calibrationCommit['probeMiddleConfirmed'], isTrue);
      expect(calibrationCommit['probeEndConfirmed'], isTrue);
      final Map<Object?, Object?> updateText = calls[6].arguments! as Map;
      expect(updateText['sourceText'], '本文です');
      expect(updateText['textGeneration'], 3);
      expect(updateText['writingMode'], 'horizontal');
      final Map<Object?, Object?> suspend = calls[8].arguments! as Map;
      expect(suspend['textGeneration'], 3);
      expect(suspend['captureGeneration'], 91);
      final Map<Object?, Object?> restore = calls[9].arguments! as Map;
      expect(restore['textGeneration'], 3);
      expect(restore['captureGeneration'], 91);
    },
  );

  test(
    'zero provider identity parses as absent while status stays unavailable',
    () {
      final GalAttachedCallResult result = GalAttachedCallResult.fromReply(
        <String, Object?>{
          'status': 'ready',
          'providerKind': 0,
          'providerId': 0,
          'providerStatus': 0,
        },
      );

      expect(result.providerKind, isNull);
      expect(result.providerId, isNull);
      expect(result.providerStatus, 0);
    },
  );

  test('malformed attached replies and state tokens fail closed', () {
    expect(GalAttachedCallResult.fromReply(null).ok, isFalse);
    expect(
      GalAttachedCallResult.fromReply(<String, Object?>{'status': 7}).ok,
      isFalse,
    );
    expect(GalAttachedCallResult.fromReply(<String, Object?>{}).ok, isFalse);
    expect(
      GalAttachedSurfaceStateEvent.fromMap(<Object?, Object?>{
        ..._target.toMap(),
        'status': <String>['activeNative'],
      }),
      isNull,
    );
  });

  test(
    'v19 attached lookup hit preserves epochs/generation/UTF-16 bounds',
    () async {
      GalAttachedLookupHitV19? received;
      GalHookTextOverlayChannel.setEventHandlers(
        onAttachedLookupText: (GalAttachedLookupHitV19 hit) => received = hit,
      );
      const String text = 'これは本文です';
      await invokeFromNative('lookupText', <String, Object?>{
        'surface': 'attached',
        ..._target.toMap(),
        'sourceText': text,
        'textGeneration': 9,
        'charIndex': 3,
        'sourceLength': 2,
        'wordLeft': 320.0,
        'wordTop': 700.0,
        'wordWidth': 28.0,
        'wordHeight': 36.0,
      });

      expect(received, isNotNull);
      expect(received!.target.matches(_target), isTrue);
      expect(received!.textGeneration, 9);
      expect(received!.charIndex, 3);
      expect(received!.sourceLength, 2);
      expect(received!.hasConsistentSourceLength, isTrue);
      expect(received!.wordRect, const Rect.fromLTWH(320, 700, 28, 36));
      expect(received!.hover, isFalse, reason: '无 hover 字段（老 runner）= 点击');
    },
  );

  test(
    'attached Shift+hover hit is typed and takes the same handler',
    () async {
      GalAttachedLookupHitV19? received;
      GalHookTextOverlayChannel.setEventHandlers(
        onAttachedLookupText: (GalAttachedLookupHitV19 hit) => received = hit,
      );
      await invokeFromNative('lookupText', <String, Object?>{
        'surface': 'attached',
        ..._target.toMap(),
        'sourceText': 'これは本文です',
        'textGeneration': 9,
        'charIndex': 3,
        'sourceLength': 2,
        'hover': true,
      });
      expect(received, isNotNull);
      expect(received!.hover, isTrue);
      expect(received!.charIndex, 3);

      received = null;
      await invokeFromNative('lookupText', <String, Object?>{
        'surface': 'attached',
        ..._target.toMap(),
        'sourceText': 'これは本文です',
        'textGeneration': 9,
        'charIndex': 3,
        'sourceLength': 2,
        'hover': 'yes',
      });
      expect(received, isNotNull);
      expect(received!.hover, isFalse, reason: '只认布尔 true，其它值一律当点击');
    },
  );

  test('attached lookup rejects half or malformed UTF-16 clusters', () async {
    int calls = 0;
    GalHookTextOverlayChannel.setEventHandlers(
      onAttachedLookupText: (GalAttachedLookupHitV19 _) {
        calls++;
      },
    );

    Future<void> emit(String source, int index, int length) =>
        invokeFromNative('lookupText', <String, Object?>{
          'surface': 'attached',
          ..._target.toMap(),
          'sourceText': source,
          'textGeneration': 9,
          'charIndex': index,
          'sourceLength': length,
        });

    await emit('A𠮷B', 1, 1);
    await emit('A𠮷B', 2, 1);
    expect(calls, 0);
    final String unpaired = String.fromCharCodes(<int>[0x41, 0xD842, 0x42]);
    expect(
      GalAttachedLookupHitV19.fromMap(<Object?, Object?>{
        'surface': 'attached',
        ..._target.toMap(),
        'sourceText': unpaired,
        'textGeneration': 9,
        'charIndex': 1,
        'sourceLength': 1,
      }),
      isNull,
    );
  });

  test(
    'frozen state/calibration events are typed and malformed epochs drop',
    () async {
      GalAttachedSurfaceStateEvent? state;
      GalAttachedCalibrationEvent? committed;
      GalAttachedCalibrationCancelledEvent? cancelled;
      GalHookTextOverlayChannel.setEventHandlers(
        onAttachedSurfaceStateChanged: (GalAttachedSurfaceStateEvent event) {
          state = event;
        },
        onAttachedCalibrationCommitted: (GalAttachedCalibrationEvent event) {
          committed = event;
        },
        onAttachedCalibrationCancelled:
            (GalAttachedCalibrationCancelledEvent event) {
              cancelled = event;
            },
      );

      await invokeFromNative('attachedSurfaceStateChanged', <String, Object?>{
        ..._target.toMap(),
        'state': 'visible',
        'status': 'visible',
        'surfaceVisible': true,
        'referenceClient': _client.toJson(),
        'bodyRect': _rect.toJson(),
        'layout': _layout.toJson(),
        'providerKind': 4,
        'providerId': 11,
        'providerStatus': 2,
        'shield': <String, Object?>{
          'available': true,
          'requestSeq': 8,
          'appliedSeq': 8,
          'requiredMask': 0x7f,
          'readyMask': 0x7f,
          'observedMask': 0x7f,
          'faultMask': 0,
          'statusFlags': 1,
        },
        'calibrationProbeMask': 3,
      });
      await invokeFromNative('attachedCalibrationCommitted', <String, Object?>{
        ..._target.toMap(),
        'bodyRect': _rect.toJson(),
        'referenceClient': _client.toJson(),
        'layout': _layout.toJson(),
        'riskAccepted': true,
        'calibrationProbeMask': 7,
      });
      await invokeFromNative('attachedCalibrationCancelled', <String, Object?>{
        ..._target.toMap(),
        'reason': 'user_cancelled',
      });

      expect(state?.status, 'visible');
      expect(state?.state, 'visible');
      expect(state?.surfaceVisible, isTrue);
      expect(state?.bodyRect, _rect);
      expect(state?.layout, _layout);
      expect(state?.providerKind, 4);
      expect(state?.providerId, 11);
      expect(state?.providerStatus, 2);
      expect(state?.shield.conclusion, GalAttachedShieldConclusion.verified);
      expect(state?.calibrationProbeMask, 3);
      expect(committed?.bodyRect, _rect);
      expect(committed?.riskAccepted, isTrue);
      expect(committed?.calibrationProbeMask, 7);
      expect(cancelled?.reason, 'user_cancelled');

      state = null;
      await invokeFromNative('attachedSurfaceStateChanged', <String, Object?>{
        ..._target.toMap(),
        'surfaceEpoch': 0,
        'state': 'visible',
        'status': 'visible',
      });
      expect(state, isNull);
    },
  );
}
