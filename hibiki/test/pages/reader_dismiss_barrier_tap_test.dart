import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';
import 'reader_hibiki_page_source_corpus.dart';

class _BarrierTapAppModel extends AppModel {
  _BarrierTapAppModel() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 360;

  @override
  double get popupMaxHeight => 360;

  @override
  bool get popupBottomDocked => false;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];

  @override
  bool get lowMemoryMode => false;

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

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

class _RecordingHostPage extends BaseSourcePage {
  const _RecordingHostPage({super.key}) : super(item: null);

  @override
  BaseSourcePageState<_RecordingHostPage> createState() =>
      _RecordingHostPageState();
}

class _RecordingHostPageState extends BaseSourcePageState<_RecordingHostPage> {
  final List<Offset> barrierTaps = <Offset>[];

  @override
  void onDismissBarrierTap(Offset globalPos) {
    barrierTaps.add(globalPos);
    // Do NOT call super: only assert the hook receives the global position.
  }

  Future<void> topSearch(String term) {
    prunePopupStack(0);
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        const Positioned.fill(child: SizedBox.expand()),
        buildDictionary(),
      ],
    );
  }
}

class _DefaultHostPage extends BaseSourcePage {
  const _DefaultHostPage({super.key}) : super(item: null);

  @override
  BaseSourcePageState<_DefaultHostPage> createState() =>
      _DefaultHostPageState();
}

class _DefaultHostPageState extends BaseSourcePageState<_DefaultHostPage> {
  Future<void> topSearch(String term) {
    prunePopupStack(0);
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        const Positioned.fill(child: SizedBox.expand()),
        buildDictionary(),
      ],
    );
  }
}

Widget _wrap({required AppModel appModel, required Widget child}) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (context, c) => Spacing(
          dataBuilder: (context) => SpacingData.generate(10),
          child: c ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
}

const Offset _bareBarrierPoint = Offset(740, 560);

void main() {
  setUpAll(installFakeInAppWebViewPlatform);
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('behaviour: barrier onTapUp -> onDismissBarrierTap hook', () {
    testWidgets('forwards the global pointer position to the override',
        (WidgetTester tester) async {
      final appModel = _BarrierTapAppModel();
      final hostKey = GlobalKey<_RecordingHostPageState>();
      await tester.pumpWidget(
        _wrap(appModel: appModel, child: _RecordingHostPage(key: hostKey)),
      );
      await tester.pump();
      await tester.pump();

      final host = hostKey.currentState!;
      await host.topSearch('first');
      await tester.pump();
      expect(host.debugPopupStack, hasLength(1));
      expect(host.dictionaryPopupShown, isTrue);

      await tester.tapAt(_bareBarrierPoint);
      await tester.pump();

      expect(host.barrierTaps, hasLength(1),
          reason: 'a tap on the bare barrier must invoke onDismissBarrierTap');
      expect(host.barrierTaps.single, _bareBarrierPoint,
          reason: 'the hook receives the GLOBAL pointer position so reader can '
              'globalToLocal it onto the WebView (TODO-1027)');
    });

    testWidgets(
        'default override (video/home/audiobook parity) still clears the whole '
        'stack, hidden warm slot survives', (WidgetTester tester) async {
      final appModel = _BarrierTapAppModel();
      final hostKey = GlobalKey<_DefaultHostPageState>();
      await tester.pumpWidget(
        _wrap(appModel: appModel, child: _DefaultHostPage(key: hostKey)),
      );
      await tester.pump();
      await tester.pump();

      final host = hostKey.currentState!;
      await host.topSearch('first');
      await tester.pump();
      expect(host.dictionaryPopupShown, isTrue);

      await tester.tapAt(_bareBarrierPoint);
      await tester.pump();

      expect(host.dictionaryPopupShown, isFalse,
          reason: 'default onDismissBarrierTap=clearDictionaryResult, '
              'tap-blank closes the visible stack (unchanged for non-reader)');
      expect(host.debugPopupStack, hasLength(1),
          reason: 'the hidden warm slot survives (BUG-092)');
      expect(host.debugPopupStack.single.visible, isFalse);
      expect(host.debugPopupStack.single.isWarmSlot, isTrue);
    });
  });

  group('source guard: base barrier wiring', () {
    final String base = File('lib/src/pages/base_source_page.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');

    test(
        'barrier forwards onTapUp.globalPosition to onDismissBarrierTap, not a '
        'hardcoded onTap: clearDictionaryResult', () {
      expect(base.contains('onTapUp: (details) =>'), isTrue,
          reason: 'barrier must capture the tap-up global position');
      expect(
          base.contains('onDismissBarrierTap(details.globalPosition)'), isTrue,
          reason: 'barrier must route through the overridable hook');
      expect(base.contains('onTap: clearDictionaryResult'), isFalse,
          reason: 'the barrier must NOT hardcode onTap: clearDictionaryResult '
              '(reader overrides the hook to forward taps to lookup)');
    });

    test('onDismissBarrierTap default still clears the whole stack', () {
      expect(
        base.contains(
            'void onDismissBarrierTap(Offset globalPos) => clearDictionaryResult();'),
        isTrue,
        reason: 'default keeps video/home/audiobook "tap blank closes stack"',
      );
    });
  });

  group('source guard: reader override + onTapEmpty', () {
    final String corpus = readReaderPageSource();

    test(
        'reader overrides onDismissBarrierTap and forwards the tap to lookup '
        'via globalToLocal + _selectTextAt', () {
      final int idx =
          corpus.indexOf('void onDismissBarrierTap(Offset globalPos)');
      expect(idx, greaterThan(0),
          reason: 'reader must override the barrier-tap hook (TODO-1027)');
      final String body = corpus.substring(idx, idx + 900);
      expect(body.contains('_webViewKey.currentContext?.findRenderObject()'),
          isTrue,
          reason: 'reader must map global -> WebView local via its RenderBox');
      expect(body.contains('obj.globalToLocal(globalPos)'), isTrue);
      expect(body.contains('_selectTextAt(local.dx, local.dy)'), isTrue,
          reason:
              'real tap path (fromHover:false): word->lookup, blank->onTapEmpty');
      expect(body.contains('clearDictionaryResult();'), isTrue,
          reason: 'RenderBox-unavailable fallback still closes (no crash)');
    });

    test('reader onTapEmpty clears the stack when a popup is visible', () {
      final int idx = corpus.indexOf("handlerName: 'onTapEmpty'");
      expect(idx, greaterThan(0));
      final String body = corpus.substring(idx, idx + 700);
      expect(body.contains('if (isDictionaryShown) {'), isTrue,
          reason: 'barrier-forwarded blank tap (popup visible) must close the '
              'stack, not toggle chrome (TODO-1027)');
      expect(body.contains('clearDictionaryResult();'), isTrue);
    });
  });
}
