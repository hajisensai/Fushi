import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_dictionary_page.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// TODO-376 返工回归守卫：默认用户（剪贴板监听**关**、桌面悬浮字幕点词**开**）。
///
/// 悬浮字幕点词由 `floatingLyricClickLookup` 控制，与 `desktopClipboardEnabled`
/// 无关：reader 路由的 `_lookupFromFloatingLyric` 先把待查词排进
/// [DesktopLookupService.pendingText]（[triggerLookup]），再请主窗切到查词 tab。等
/// [HomeDictionaryPage] 真正挂载时，那次设 pending 的 notify 早已发生（在本页
/// addListener 之前），故必须在**挂载时无条件消费一次已存在的 pending**，否则查词
/// 静默丢失。
///
/// 复核退回的高问题 1：上一轮把消费门控在 `desktopClipboardEnabled` 分支里，关了
/// 剪贴板监听的默认用户点词后 pending 卡死。本测试钉「挂载即消费已存在 pending（不
/// 受剪贴板开关门控）」；撤掉 initState 的无条件消费即红。
class _PendingOnMountAppModel extends AppModel {
  _PendingOnMountAppModel() : super(testPlatformServices());

  final List<String> searchedTerms = <String>[];

  // 关键：默认用户关掉了剪贴板监听（只开悬浮字幕点词）。
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

Widget _wrap(_PendingOnMountAppModel appModel) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (BuildContext context, Widget? child) => Spacing(
          dataBuilder: (BuildContext context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: const Scaffold(body: HomeDictionaryPage()),
      ),
    ),
  );
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

  testWidgets(
      'default user (clipboard off): pending set BEFORE mount is consumed on '
      'mount and searched', (WidgetTester tester) async {
    final _PendingOnMountAppModel appModel = _PendingOnMountAppModel();

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) {
        if (call.method == 'isFocused') return Future<bool>.value(true);
        return Future<void>.value();
      },
    );

    // 悬浮字幕点词在切到查词 tab 之前就把待查词排进 pendingText（reader 的
    // _lookupFromFloatingLyric 调 triggerLookup）。此刻 HomeDictionaryPage 尚未挂载。
    DesktopLookupService.instance.triggerLookup(' floatingword ');
    expect(DesktopLookupService.instance.pendingText, 'floatingword');

    // 现在请求切到查词 tab → HomeDictionaryPage 挂载。
    await tester.pumpWidget(_wrap(appModel));
    // 挂载后帧：无条件消费已存在的 pending（不受 desktopClipboardEnabled 门控）。
    await tester.pump();
    await tester.pump();

    expect(
      DesktopLookupService.instance.pendingText,
      isNull,
      reason: '挂载时必须消费挂载前已排入的 pending（清空表示已消费）。',
    );
    expect(
      appModel.searchedTerms,
      <String>['floatingword'],
      reason: '默认用户（剪贴板关）点悬浮字幕也必须在查词 tab 真正发起查询。',
    );
  });

  testWidgets('no pending on mount → no spurious search (边界：不乱消费)',
      (WidgetTester tester) async {
    final _PendingOnMountAppModel appModel = _PendingOnMountAppModel();

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) {
        if (call.method == 'isFocused') return Future<bool>.value(true);
        return Future<void>.value();
      },
    );

    await tester.pumpWidget(_wrap(appModel));
    await tester.pump();
    await tester.pump();

    expect(
      appModel.searchedTerms,
      isEmpty,
      reason: '无 pending 时挂载不得发起任何查询（不乱消费）。',
    );
  });
}
