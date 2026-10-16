import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// BUG-3425：串流页的查词弹窗必须拿到查词源（host）的词典资源，否则
/// `window.dictionaryStyles` 读的是本机（iPad 上为空），渲染与导出的 Glossary
/// 都没有词典自带样式。
void main() {
  setUpAll(installFakeInAppWebViewPlatform);
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('the popup layer receives the host resource source', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _HostLookup lookup = _HostLookup();
    final GameStreamLookupController controller =
        GameStreamLookupController(
          lookupClient: lookup,
          streamClient: FushiGameStreamClient(transport: _Transport()),
          clientId: 'ipad',
        )..applyTextEvent(
          GameStreamTextEvent(
            sessionId: 's1',
            lineId: 'line-1',
            text: '猫がいる',
            timestampMs: 1,
          ),
        );
    addTearDown(controller.dispose);
    final GameStreamInputComposer composer = GameStreamInputComposer(
      sessionId: 's1',
      clientId: 'ipad',
      sender: (_) async => null,
    );
    addTearDown(composer.dispose);
    final _PopupAppModel app = _PopupAppModel();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((Ref ref) => app)],
        child: TranslationProvider(
          child: MaterialApp(
            home: GameStreamPage(
              sessionId: 's1',
              clientId: 'ipad',
              inputComposer: composer,
              lookupController: controller,
              videoPlaceholder: const Text('frame'),
            ),
          ),
        ),
      ),
    );
    await controller.lookup('猫がいる');
    await tester.pump();

    final DictionaryPopupLayer layer = tester.widget<DictionaryPopupLayer>(
      find.byType(DictionaryPopupLayer),
    );
    expect(identical(layer.resourceSource, lookup.resources), isTrue);
    // 冷建 WebView 的翻可见兜底计时在测试里没有 popupRendered 来收。
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 弹窗 WebView 构建时读的那几项偏好；本测试不查本机词典。
class _PopupAppModel extends AppModel {
  _PopupAppModel() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  double get dictionaryFontSize => 16;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  List<String> get enabledAudioSources => const <String>[];
}

class _StubResources implements DictionaryPopupResourceSource {
  @override
  Map<String, String> get dictionaryStyles => const <String, String>{
    '明鏡': '.gloss{}',
  };
  @override
  Future<DictionaryPopupMedia?> mediaFile(String d, String p) async => null;
  @override
  Future<String?> wordAudioRef(String e, String r) async => null;
}

class _HostLookup implements GameStreamDictionaryLookup {
  final _StubResources resources = _StubResources();

  @override
  DictionaryPopupResourceSource get popupResources => resources;

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => DictionarySearchResult(
    searchTerm: term,
    bestLength: 1,
    entries: <DictionaryEntry>[
      DictionaryEntry(dictionaryName: '明鏡', word: '猫', meaning: 'cat'),
    ],
  );
}

class _Transport implements GameStreamTransport {
  @override
  Future<GameStreamPostResult> post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async => const GameStreamPostResult(json: null);
}
