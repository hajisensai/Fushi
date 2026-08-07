import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// 词典页「下拉 = 手动同步」的手势可达性测试。
///
/// 词典页原本**完全没有**下拉刷新：主体要么是查词结果 WebView，要么是 `Center` 包的
/// 空态，要么是历史 `ListView`。后两者加 [RefreshIndicator] 时有个容易翻车的点 ——
/// RefreshIndicator 只对**真实可滚动的**后代生效：裸 `Center` 没有 Scrollable，历史只
/// 有一两条时默认 physics 也不可滚，两种情况下手势会被静默吞掉（widget 树里有
/// RefreshIndicator，下拉却毫无反应）。所以这里不只断言「有 RefreshIndicator」，还断言
/// 它下面挂着能响应下拉的 Scrollable。
class _PullSyncAppModel extends AppModel {
  _PullSyncAppModel({required this.history}) : super(testPlatformServices());

  final List<DictionarySearchResult> history;

  @override
  List<DictionarySearchResult> get dictionaryHistory => history;

  @override
  bool get autoSearchEnabled => false;

  @override
  bool get desktopClipboardEnabled => false;

  @override
  DesktopClipboardWindowMode get desktopClipboardWindowMode =>
      DesktopClipboardWindowMode.normal;

  @override
  List<Dictionary> get dictionaries => <Dictionary>[
        Dictionary(name: 'Test', formatKey: 'test', order: 0),
      ];

  @override
  int get maximumTerms => 10;

  @override
  double get defaultDictionaryFontSize => 26;

  @override
  double get dictionaryFontSize => 26;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];
}

Widget _wrap(_PullSyncAppModel appModel) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: const Scaffold(body: HomeDictionaryPage()),
      ),
    ),
  );
}

DictionarySearchResult _result(String term) => DictionarySearchResult(
      searchTerm: term,
      entries: <DictionaryEntry>[
        DictionaryEntry(
          dictionaryName: 'Test',
          word: term,
          reading: term,
          meaning: '["x"]',
        ),
      ],
    );

/// RefreshIndicator 下面挂着的、真正会响应下拉的 Scrollable 的 physics。
ScrollPhysics? _refreshablePhysics(WidgetTester tester) {
  final Finder scrollable = find.descendant(
    of: find.byType(RefreshIndicator),
    matching: find.byType(Scrollable),
  );
  if (scrollable.evaluate().isEmpty) return null;
  return tester.widget<Scrollable>(scrollable.first).physics;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(installFakeInAppWebViewPlatform);

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    DesktopLookupService.instance.debugReset();
  });

  testWidgets('空历史（空态）也能下拉同步：Center 被撑成可滚动视口', (WidgetTester tester) async {
    final _PullSyncAppModel appModel =
        _PullSyncAppModel(history: <DictionarySearchResult>[]);
    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();

    expect(find.byType(RefreshIndicator), findsOneWidget);
    final ScrollPhysics? physics = _refreshablePhysics(tester);
    expect(
      physics,
      isNotNull,
      reason: '空态若还是裸 Center，RefreshIndicator 找不到 Scrollable，下拉手势被静默吞掉',
    );
    expect(
      physics,
      isA<AlwaysScrollableScrollPhysics>(),
      reason: '内容不满一屏时必须仍能下拉，否则空态永远同步不了',
    );
  });

  testWidgets('历史列表能下拉同步，且只有一条时也可滚', (WidgetTester tester) async {
    final _PullSyncAppModel appModel = _PullSyncAppModel(
      history: <DictionarySearchResult>[_result('猫')],
    );
    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();

    expect(find.byType(RefreshIndicator), findsOneWidget);
    expect(
      _refreshablePhysics(tester),
      isA<AlwaysScrollableScrollPhysics>(),
      reason: '历史只有一条时 ListView 默认不可滚，下拉同步会吃不到手势',
    );
  });

  testWidgets('下拉真的能拉出刷新指示器（手势没被吞）', (WidgetTester tester) async {
    final _PullSyncAppModel appModel = _PullSyncAppModel(
      history: <DictionarySearchResult>[_result('猫')],
    );
    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();

    // 从列表区域往下拖，RefreshIndicator 应当露出进度圈。用 fling 之外的持续拖拽，
    // 避免依赖 fling 速度阈值。
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byType(RefreshProgressIndicator),
      findsOneWidget,
      reason: '下拉没能拉出指示器 —— 手势被吞了',
    );

    // 松手后让指示器回弹收尾，避免 pending timer 泄漏到下一个用例。
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
