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

import '../helpers/test_platform_services.dart';

/// 「功能模块 → 查词」关掉后 [HomeTab.dictionaries] 从底栏消失，`_selectTab` 会拒绝
/// 切到它。查词是全局能力（桌面查词热键 / 悬浮字幕点词 / 剪贴板 mainTab 分区 / 浏览器
/// 扩展回流都指向它），所以 HomePage 的 `_revealDictionary` 在这种情况下改推一个独立
/// 路由来承载**同一个** [HomeDictionaryPage]（`_StandaloneDictionaryRoute`）。
///
/// 本测试钉那条承载面的两个契约：
/// - 推成路由时页头出现返回箭头，且按下真的把这层路由 pop 掉（tab 承载时没有路由栈，
///   不得画返回箭头）；
/// - 路由挂载同样消费挂载前已排入的 [DesktopLookupService.pendingText] —— 这正是
///   「按热键 → 窗口弹到前台 → 什么也不显示、pending 永远挂着」那条坏路径的判据。
class _StandaloneRouteAppModel extends AppModel {
  _StandaloneRouteAppModel() : super(testPlatformServices());

  final List<String> searchedTerms = <String>[];

  @override
  bool get desktopClipboardEnabled => false;

  @override
  DesktopClipboardWindowMode get desktopClipboardWindowMode =>
      DesktopClipboardWindowMode.normal;

  @override
  List<DictionarySearchResult> get dictionaryHistory =>
      <DictionarySearchResult>[];

  @override
  List<Dictionary> get dictionaries => <Dictionary>[
        Dictionary(name: 'Test', formatKey: 'test', order: 0),
      ];

  @override
  int get maximumTerms => 10;

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

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
    searchedTerms.add(searchTerm);
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

/// 首屏是一个「别的页面」，用它来验证 pop 之后真的退回来了（等价于用户在阅读器 /
/// 视频页按查词热键后再返回）。
Widget _wrap(_StandaloneRouteAppModel appModel) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: const Scaffold(body: Center(child: Text('origin-page'))),
      ),
    ),
  );
}

/// 与 `_HomePageState._revealDictionary` 的隐藏分支同构：推一层 Scaffold 包住
/// 带返回箭头的 [HomeDictionaryPage]。
Future<void> _pushStandaloneLookup(
  WidgetTester tester,
  _StandaloneRouteAppModel appModel,
) async {
  appModel.navigatorKey.currentState!.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => const Scaffold(
        body: SafeArea(child: HomeDictionaryPage(showBackButton: true)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    DesktopLookupService.instance.debugReset();
  });

  void mockWindowManager(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) {
        if (call.method == 'isFocused') return Future<bool>.value(true);
        return Future<void>.value();
      },
    );
  }

  testWidgets('查词 tab 隐藏时推成独立路由：仍消费挂载前排入的 pending 并发起查询',
      (WidgetTester tester) async {
    final _StandaloneRouteAppModel appModel = _StandaloneRouteAppModel();
    mockWindowManager(tester);

    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();

    // 热键 / 悬浮字幕点词先把待查词排进 pending，再请求打开查词面。
    DesktopLookupService.instance.triggerLookup(' hotkeyword ');
    expect(DesktopLookupService.instance.pendingText, 'hotkeyword');

    await _pushStandaloneLookup(tester, appModel);
    await tester.pump();

    expect(
      DesktopLookupService.instance.pendingText,
      isNull,
      reason: '独立路由承载的查词页必须与 tab 承载一样消费已排入的 pending；'
          '否则用户按热键只会看到窗口弹到前台却什么都不显示。',
    );
    expect(
      appModel.searchedTerms,
      <String>['hotkeyword'],
      reason: '查词 tab 被「功能模块」隐藏，隐藏的是导航项而不是查词能力。',
    );
  });

  testWidgets('独立路由承载时页头有返回箭头，按下退回来源页', (WidgetTester tester) async {
    final _StandaloneRouteAppModel appModel = _StandaloneRouteAppModel();
    mockWindowManager(tester);

    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();
    expect(find.text('origin-page'), findsOneWidget);

    await _pushStandaloneLookup(tester, appModel);

    final Finder back =
        find.byKey(const ValueKey<String>('home-dictionary-route-back'));
    expect(back, findsOneWidget, reason: '推成路由的查词页必须给得出返回路径。');

    await tester.tap(back);
    // pop 走 PopScope 的异步判据 + 反向过渡动画，需要跑完微任务再推完整个动画。
    await tester.pumpAndSettle();

    expect(
      find.byType(HomeDictionaryPage),
      findsNothing,
      reason: '返回箭头必须真的 pop 掉这层路由。',
    );
    expect(find.text('origin-page'), findsOneWidget);
  });

  testWidgets('tab 承载（showBackButton 默认 false）不画返回箭头',
      (WidgetTester tester) async {
    final _StandaloneRouteAppModel appModel = _StandaloneRouteAppModel();
    mockWindowManager(tester);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: appModel.navigatorKey,
            builder: (BuildContext context, Widget? child) =>
                child ?? const SizedBox.shrink(),
            home: const Scaffold(body: HomeDictionaryPage()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('home-dictionary-route-back')),
      findsNothing,
      reason: '切 tab 不产生路由栈，画返回箭头没有可返回的目标。',
    );
  });
}
