import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/components/glass/fushi_native_material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
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
  const _Harness({super.key, required this.webViewKey});

  final GlobalKey<DictionaryPopupWebViewState> webViewKey;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  DictionarySearchResult result = DictionarySearchResult(searchTerm: '');

  void update({DictionarySearchResult? result}) {
    setState(() {
      if (result != null) this.result = result;
    });
  }

  static const String _backgroundHtml = '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{margin:0;padding:16px;background:#101014;color:#eee;
font:700 30px/1.5 -apple-system,sans-serif}
.r{color:#ff5a5a}.b{color:#4aa3ff}.y{color:#ffd23f}.g{color:#4ade80}</style>
</head><body>
<p><span class=r>桜の花が咲き始めた頃、</span><span class=b>少年は古い図書館の扉を押し開けた。</span>
<span class=y>埃の匂いと共に、</span><span class=g>木の扉の向こうから光が漏れ出てきた。</span></p>
<p><span class=b>窓から差し込む午後の光が、</span><span class=r>床の上に長い影を落としていた。</span>
<span class=g>誰も近寄らないほど古い本棚の奥で、</span><span class=y>一冊の本が静かに光っていた。</span></p>
<p><span class=y>彼は鍵を握りしめ、</span><span class=r>見覚えのない扉を見つけた。</span>
<span class=b>空は紫色で、二つの月が浮かんでいた。</span></p>
</body></html>''';

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        InAppWebView(
          initialData: InAppWebViewInitialData(data: _backgroundHtml),
        ),
        Center(
          child: SizedBox(
            width: 330,
            height: 380,
            child: DictionaryPopupLayer(
              result: result,
              keepWebViewWarm: true,
              webViewKey: widget.webViewKey,
              onDismiss: () {},
              onTextSelected: (String _, Rect __) {},
              onLinkClick: (String _, Rect __) {},
              onMineEntry: (Map<String, String> _) async =>
                  const MinePopupResult(),
              onDuplicateCheck: (String expression, String reading) async =>
                  false,
            ),
          ),
        ),
      ],
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpFor(WidgetTester tester, Duration d) async {
    final int n = d.inMilliseconds ~/ 100;
    for (int i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('iOS lookup popup sits on a native UIVisualEffectView', (
    WidgetTester tester,
  ) async {
    LocaleSettings.setLocale(AppLocale.en);
    final GlobalKey<DictionaryPopupWebViewState> key =
        GlobalKey<DictionaryPopupWebViewState>();
    final GlobalKey<_HarnessState> harness = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => _ProbeAppModel()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            home: Scaffold(
              body: _Harness(key: harness, webViewKey: key),
            ),
          ),
        ),
      ),
    );
    await pumpFor(tester, const Duration(seconds: 4));
    harness.currentState!.update(result: _result('見物'));
    expect(find.byType(FushiNativeMaterialBackdrop), findsOneWidget);
    debugPrint('[native-mat-ios] PHASE native');
    await pumpFor(tester, const Duration(seconds: 25));

    debugNativeMaterialHostSupported = () => false;
    harness.currentState!.update(result: _result('見物'));
    await tester.pump();
    expect(find.byType(FushiNativeMaterialBackdrop), findsNothing);
    debugPrint('[native-mat-ios] PHASE opaque-control');
    await pumpFor(tester, const Duration(seconds: 25));
    debugPrint('[native-mat-ios] PHASE done');
  });
}
