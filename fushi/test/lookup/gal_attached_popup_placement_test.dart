import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

class _LookupAppModel extends AppModel {
  _LookupAppModel()
    : super(testPlatformServices(isWindows: true, isDesktop: true));

  @override
  double get appUiScale => 1.0;

  @override
  double get dictionaryFontSize => 16.0;

  @override
  double get popupWheelSpeed => 1.0;

  @override
  bool get popupInstantScroll => false;

  @override
  double get popupInstantScrollWheelStep => 0.5;

  @override
  double get popupInstantScrollTouchStep => 0.5;

  @override
  int get popupDictionaryColumns => 1;

  @override
  int get popupAutoExpandDictionaries => 0;

  @override
  bool get deduplicatePitchAccents => false;

  @override
  bool get harmonicFrequency => false;

  @override
  bool get showExpressionTags => false;

  @override
  bool get collapseDictionaries => false;

  @override
  bool get compactGlossaries => false;

  @override
  LookupSize get overlayLookupEffectiveSize => const LookupSize(420.0, 600.0);

  @override
  bool get lookupBlockCapture => false;

  @override
  List<Dictionary> get dictionaries => const <Dictionary>[];

  @override
  List<String> get enabledAudioSources => const <String>[];

  @override
  Map<String, String> get customDictCSS => const <String, String>{};

  @override
  String get globalDictCSS => '';

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

Map<String, Object?> _mapArguments(MethodCall call) {
  return Map<String, Object?>.from(call.arguments as Map);
}

double _number(Object? value) => (value as num).toDouble();

Map<String, Object?> _decodeRenderStackPayload(String script) {
  const String marker = 'renderStack(';
  final int markerStart = script.indexOf(marker);
  expect(markerStart, greaterThanOrEqualTo(0));
  final int jsonStart = script.indexOf('{', markerStart + marker.length);
  expect(jsonStart, greaterThan(markerStart));

  bool inString = false;
  bool escaped = false;
  int depth = 0;
  int jsonEnd = -1;
  for (int i = jsonStart; i < script.length; i++) {
    final int code = script.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code == 0x5c) {
        escaped = true;
      } else if (code == 0x22) {
        inString = false;
      }
      continue;
    }
    if (code == 0x22) {
      inString = true;
    } else if (code == 0x7b) {
      depth++;
    } else if (code == 0x7d) {
      depth--;
      if (depth == 0) {
        jsonEnd = i + 1;
        break;
      }
    }
  }
  expect(jsonEnd, greaterThan(jsonStart));
  return Map<String, Object?>.from(
    jsonDecode(script.substring(jsonStart, jsonEnd)) as Map,
  );
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('app.fushi.reader/global_lookup');

  testWidgets(
    'attached physical placement uses its viewport and does not leak to desktop lookup',
    (WidgetTester tester) async {
      final _LookupAppModel appModel = _LookupAppModel();
      final List<MethodCall> calls = <MethodCall>[];
      final List<Map<String, Object?>> showAtCalls = <Map<String, Object?>>[];
      const double monitorDpr = 1.5;
      const Rect anchor = Rect.fromLTWH(-1840.25, -120.5, 24.0, 26.0);
      const Rect viewport = Rect.fromLTWH(-1920.0, -180.0, 1600.0, 900.0);

      GlobalLookupController.platformOverride = true;
      addTearDown(() {
        GlobalLookupController.instance.setPhysicalCap();
        GlobalLookupController.platformOverride = null;
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });

      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        MethodCall call,
      ) async {
        calls.add(call);
        if (call.method == 'showAt') {
          final Map<String, Object?> args = _mapArguments(call);
          showAtCalls.add(args);
          final int x = args['x'] as int;
          final int y = args['y'] as int;
          return <String, Object?>{
            'ok': true,
            'workW': viewport.width,
            'workH': viewport.height,
            'cursorWorkX': x - viewport.left.round(),
            'cursorWorkY': y - viewport.top.round(),
            'monitorDpr': monitorDpr,
          };
        }
        if (call.method == 'isWebViewReady') return true;
        if (call.method == 'isShowing') return false;
        return null;
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appModel.navigatorKey,
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(devicePixelRatio: 1.75),
            child: child ?? const SizedBox.shrink(),
          ),
          home: const SizedBox.shrink(),
        ),
      );
      await tester.pump();

      final GlobalLookupController controller = GlobalLookupController.instance;
      await controller.start(appModel: appModel);
      await tester.pump();

      final bool attachedResult = await controller.lookupText(
        '附着词',
        autoRead: false,
        physicalPlacement: const GlobalLookupPhysicalPlacement(
          anchorScreenRect: anchor,
          destinationViewportScreenRect: viewport,
        ),
      );
      expect(
        attachedResult,
        isTrue,
        reason:
            'native calls: ${calls.map((MethodCall call) => call.method).toList()}',
      );
      expect(showAtCalls, hasLength(1));

      final Map<String, Object?> attachedShow = showAtCalls.single;
      expect(attachedShow['x'], anchor.left.round());
      expect(attachedShow['y'], anchor.top.round());
      expect(attachedShow['width'], isA<int>());
      expect(attachedShow['height'], isA<int>());
      expect(attachedShow['width'], greaterThan(420));
      expect(attachedShow['height'], greaterThan(600));
      expect(attachedShow['atCursor'], isFalse);
      expect(attachedShow['capW'], viewport.width.round());
      expect(attachedShow['capH'], viewport.height.round());
      expect(attachedShow['capX'], anchor.left.round() - viewport.left.round());
      expect(attachedShow['capY'], anchor.top.round() - viewport.top.round());

      final MethodCall attachedRender = calls.singleWhere(
        (MethodCall call) => call.method == 'render',
      );
      final Map<String, Object?> renderArgs = _mapArguments(attachedRender);
      final Map<String, Object?> renderPayload = _decodeRenderStackPayload(
        renderArgs['json'] as String,
      );
      final List<Object?> popups = renderPayload['popups'] as List<Object?>;
      expect(popups, hasLength(1));
      final Map<String, Object?> root = Map<String, Object?>.from(
        popups.single as Map,
      );
      final Map<String, Object?> frame = Map<String, Object?>.from(
        root['frame'] as Map,
      );
      final int showX = attachedShow['x'] as int;
      final int showY = attachedShow['y'] as int;
      final Rect frameOnScreen = Rect.fromLTWH(
        showX + _number(frame['left']) * monitorDpr,
        showY + _number(frame['top']) * monitorDpr,
        _number(frame['width']) * monitorDpr,
        _number(frame['height']) * monitorDpr,
      );
      expect(frameOnScreen.left, greaterThanOrEqualTo(viewport.left - 1e-6));
      expect(frameOnScreen.top, greaterThanOrEqualTo(viewport.top - 1e-6));
      expect(frameOnScreen.right, lessThanOrEqualTo(viewport.right + 1e-6));
      expect(frameOnScreen.bottom, lessThanOrEqualTo(viewport.bottom + 1e-6));
      expect(
        frameOnScreen.bottom <= anchor.top + 1e-6 ||
            frameOnScreen.top >= anchor.bottom - 1e-6,
        isTrue,
        reason: 'root card must be above or below the hit word, never over it',
      );

      final int attachedWidth = attachedShow['width'] as int;
      final int attachedHeight = attachedShow['height'] as int;
      // Seed the singleton with the kind of cap left by a previous galCard
      // session. The next desktop route must ignore both the cap and viewport
      // state while computing its initial size and showAt arguments.
      controller.setPhysicalCap(
        width: 180,
        height: 180,
        workWidth: 700,
        workHeight: 500,
        workOriginX: 17,
        workOriginY: 23,
      );
      final bool ordinaryResult = await controller.lookupText(
        '普通词',
        autoRead: false,
      );
      expect(ordinaryResult, isTrue);
      expect(showAtCalls, hasLength(2));

      final Map<String, Object?> ordinaryShow = showAtCalls[1];
      expect(ordinaryShow['atCursor'], isTrue);
      expect(ordinaryShow['x'], 0);
      expect(ordinaryShow['y'], 0);
      expect(ordinaryShow['capW'], 0);
      expect(ordinaryShow['capH'], 0);
      expect(ordinaryShow['capX'], 0);
      expect(ordinaryShow['capY'], 0);
      expect(
        ordinaryShow['width'],
        attachedWidth,
        reason: 'initial size stays tied to the main Flutter DPR across routes',
      );
      expect(ordinaryShow['height'], attachedHeight);

      // Let the ready-driven safety timer complete before the test isolate tears
      // down the mock channel; the handler deliberately acknowledges that path.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    },
  );
}
