import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../test/helpers/test_platform_services.dart';

/// iOS 查词弹窗「已制卡 ✓」探针：生产 [DictionaryPopupLayer] 挂真 WKWebView，
/// `onDuplicateCheck` 恒答 true 并计数，读 DOM 上 `.mine-button[data-mined]`。
///
/// 跑法：`.\tool\run_mac_itest.ps1 integration_test/ios_popup_duplicate_check_probe_itest.dart -Ios`
class _ProbeAppModel extends AppModel {
  _ProbeAppModel() : super(testPlatformServices());

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
  bool get lowMemoryMode => false;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];
  @override
  double get dictionaryFontSize => 16;
  @override
  double get popupWheelSpeed => 1.0;
  @override
  bool get popupInstantScroll => false;
  @override
  double get popupInstantScrollWheelStep => 0.5;
  @override
  double get popupInstantScrollTouchStep => 0.25;
  @override
  bool get compactGlossaries => false;
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
  List<Dictionary> get dictionaries => const <Dictionary>[];
  @override
  Map<String, String> get customDictCSS => const <String, String>{};
  @override
  String get globalDictCSS => '';
}

DictionarySearchResult _result(String term) => DictionarySearchResult(
  searchTerm: term,
  entries: <DictionaryEntry>[
    DictionaryEntry(
      dictionaryName: 'd',
      word: term,
      reading: 'けんぶつ',
      meaning: '"sightseeing"',
    ),
  ],
);

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.webViewKey, required this.calls});

  final GlobalKey<DictionaryPopupWebViewState> webViewKey;
  final List<String> calls;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool visible = false;
  DictionarySearchResult result = DictionarySearchResult(searchTerm: '');

  void update({bool? visible, DictionarySearchResult? result}) {
    setState(() {
      if (visible != null) this.visible = visible;
      if (result != null) this.result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 360,
        height: 360,
        child: Visibility(
          visible: visible,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: DictionaryPopupLayer(
            result: result,
            keepWebViewWarm: true,
            webViewKey: widget.webViewKey,
            onDismiss: () {},
            onTextSelected: (String _, Rect __) {},
            onLinkClick: (String _, Rect __) {},
            onMineEntry: (Map<String, String> _) async =>
                const MinePopupResult(),
            onDuplicateCheck: (String expression, String reading) async {
              widget.calls.add(expression);
              return true;
            },
          ),
        ),
      ),
    );
  }
}

const String _probeJs = '''(function(){
  var b = document.querySelectorAll('.mine-button');
  var mined = document.querySelectorAll('.mine-button[data-mined="1"]');
  return JSON.stringify({
    buttons: b.length,
    mined: mined.length,
    visibility: document.visibilityState,
    io: typeof IntersectionObserver,
    w: window.innerWidth, h: window.innerHeight
  });
})()''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Map<String, dynamic>> probe(
    WidgetTester tester,
    GlobalKey<DictionaryPopupWebViewState> key,
  ) async {
    final Object? raw = await key.currentState?.debugEval(_probeJs);
    return raw == null
        ? <String, dynamic>{}
        : jsonDecode(raw.toString()) as Map<String, dynamic>;
  }

  Future<void> pumpFor(WidgetTester tester, Duration d) async {
    final int n = d.inMilliseconds ~/ 100;
    for (int i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final String mode in <String>['shown-first', 'hidden-then-shown']) {
    testWidgets('popup paints ✓ when duplicateCheck answers true ($mode)', (
      WidgetTester tester,
    ) async {
      LocaleSettings.setLocale(AppLocale.en);
      final GlobalKey<DictionaryPopupWebViewState> key =
          GlobalKey<DictionaryPopupWebViewState>();
      final GlobalKey<_HarnessState> harness = GlobalKey<_HarnessState>();
      final List<String> calls = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith((ref) => _ProbeAppModel()),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: _Harness(key: harness, webViewKey: key, calls: calls),
              ),
            ),
          ),
        ),
      );
      // 热槽 seed：WebView 在隐藏态建好、载入 popup.html。
      await pumpFor(tester, const Duration(seconds: 4));

      if (mode == 'shown-first') {
        harness.currentState!.update(visible: true);
        await pumpFor(tester, const Duration(seconds: 1));
        harness.currentState!.update(result: _result('見物'));
      } else {
        harness.currentState!.update(result: _result('見物'));
        await pumpFor(tester, const Duration(seconds: 2));
        debugPrint(
          '[dup-probe] $mode while hidden: '
          '${jsonEncode(await probe(tester, key))} calls=${calls.length}',
        );
        harness.currentState!.update(visible: true);
      }
      await pumpFor(tester, const Duration(seconds: 4));
      final Map<String, dynamic> state = await probe(tester, key);
      debugPrint(
        '[dup-probe] $mode final: ${jsonEncode(state)} '
        'calls=${calls.length}',
      );

      expect(state['buttons'], greaterThan(0), reason: '词条必须真的渲染出来');
      expect(calls, isNotEmpty, reason: '渲染后必须发起查重');
      expect(state['mined'], state['buttons'], reason: '查重答 true，每颗制卡按钮都必须画 ✓');
    });
  }
}
