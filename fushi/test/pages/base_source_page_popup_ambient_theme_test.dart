import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/base_source_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';

import '../helpers/popup_mining_target_overrides.dart';
import 'base_source_page_hot_popup_test.dart' show HotPopupTestAppModel;

// 页面在自己的 build 里再套一层主题（音乐歌词页按封面取色）时，查词弹窗必须跟
// 插入点的环境主题走，而不是 State.context 上那份应用主题——否则弹窗被打回应用
// 主题色（音乐页查词框不跟封面取色）。

const Color _kAppSeed = Color(0xFF00897B);
const Color _kCoverSeed = Color(0xFFE65100);

class _ThemedHostPage extends BaseSourcePage {
  const _ThemedHostPage({super.key}) : super(item: null);

  @override
  BaseSourcePageState<_ThemedHostPage> createState() => _ThemedHostPageState();
}

class _ThemedHostPageState extends BaseSourcePageState<_ThemedHostPage> {
  Future<void> search(String term) {
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _kCoverSeed),
      ),
      child: Stack(children: <Widget>[buildDictionary()]),
    );
  }
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('popup inherits the page-local theme at its insertion point', (
    WidgetTester tester,
  ) async {
    final AppModel appModel = HotPopupTestAppModel();
    final GlobalKey<_ThemedHostPageState> hostKey =
        GlobalKey<_ThemedHostPageState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appProvider.overrideWith((ref) => appModel),
          ...popupMiningTargetTestOverrides(),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: _kAppSeed),
            ),
            home: Scaffold(body: _ThemedHostPage(key: hostKey)),
          ),
        ),
      ),
    );

    await hostKey.currentState!.search('term');
    await tester.pump();

    final Finder layer = find.byType(DictionaryPopupLayer);
    expect(layer, findsOneWidget);
    final ColorScheme popupScheme = Theme.of(tester.element(layer)).colorScheme;
    expect(
      popupScheme.primary,
      ColorScheme.fromSeed(seedColor: _kCoverSeed).primary,
    );
    expect(
      popupScheme.primary,
      isNot(ColorScheme.fromSeed(seedColor: _kAppSeed).primary),
    );
  });
}
