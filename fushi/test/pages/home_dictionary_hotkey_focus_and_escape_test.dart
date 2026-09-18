import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

/// 用户请求（Flow Launcher 式用法）：app 外热键「置顶主窗并打开查词页」
/// （[ShortcutAction.globalExternalOpenLookupPage] → [AppModel.requestHomeDictionaryTab]
/// `focusSearch: true`）的两项体验修正——
///
/// ① 页面弹出来**搜索框直接持焦**（并全选已有文本：直接打字就替换，什么都不打就保留
///    上次结果），不用先点一下搜索框；「已经在查词页上再按热键」同样要聚焦。
///    携带待查词的请求（悬浮字幕点词 / 桌面取词，`focusSearch: false`）**不碰焦点**——
///    它们正要把 pending 的词填进去出词卡。
/// ② 偏好「查词页按返回键最小化窗口」开着时，在查词页按「返回上一级」（默认 Esc）
///    直接把主窗最小化（window_manager `minimize`），一键回到之前的程序；偏好关着时
///    一切照旧（不发 minimize）。
///
/// 挂真的 [HomePage] + 真的 [HomeDictionaryPage]，请求走生产入口
/// [AppModel.requestHomeDictionaryTab]，最小化断言 mock 的 `window_manager` 通道
/// 真收到了 `minimize`。
class _HotkeyAppModel extends AppModel {
  _HotkeyAppModel(this._dir) : super(testPlatformServices());

  final Directory _dir;
  final List<String> searchedTerms = <String>[];

  @override
  PackageInfo get packageInfo => PackageInfo(
        appName: 'Fushi',
        packageName: 'app.hibiki.reader',
        version: '1.0.0',
        buildNumber: '1',
      );

  @override
  Directory get appDirectory => _dir;

  @override
  Directory get temporaryDirectory => _dir;

  @override
  Directory get dictionaryResourceDirectory => _dir;

  @override
  bool get isDatabaseOpen => true;

  @override
  bool get isFirstTimeSetup => false;

  @override
  bool get onboardingCompleted => true;

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

const ValueKey<String> _searchFieldKey =
    ValueKey<String>('home_dictionary_search_field');

/// mock `window_manager` 收到的方法名序列（断言 minimize 发没发）。
final List<String> _windowCalls = <String>[];

Future<_HotkeyAppModel> _pumpHome(WidgetTester tester) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tmpDir =
      Directory.systemTemp.createTempSync('fushi_home_dict_hotkey_');
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final _HotkeyAppModel appModel = _HotkeyAppModel(tmpDir)
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmpDir)
    ..wireDatabaseForTesting(db)
    // 不走 initialise()，注册表得自己装：未装载时 Esc 解析不到 globalBack，
    // 两条通道都成了 no-op，测不出任何东西。
    ..shortcutRegistry.loadDefaults(TargetPlatform.windows);

  _windowCalls.clear();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (MethodCall call) {
      _windowCalls.add(call.method);
      if (call.method == 'isFocused') return Future<bool>.value(true);
      return Future<void>.value();
    },
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
        platformServicesProvider.overrideWithValue(testPlatformServices()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: appModel.navigatorKey,
          home: const HomePage(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(HomePage.debugSelectTab, isNotNull);
  return appModel;
}

/// 有界推帧（整页 HomePage 挂着持续动画与周期定时器，pumpAndSettle 永远等不到静止）。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
  await tester.pump(const Duration(milliseconds: 10));
}

/// 搜索框底下的 EditableText（不绑具体控件类型，与 nav_tap_focus 测试同理）。
EditableText _searchEditable(WidgetTester tester) =>
    tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(_searchFieldKey),
        matching: find.byType(EditableText),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    UpdateChecker.disableAutoCheckForTesting = true;
    DesktopLookupService.instance.debugReset();
    // 本机若以隐藏 runner 环境跑，minimize 出口会被 isHiddenWindowsRunner 早退。
    DesktopForegroundGuard.debugHiddenWindowsRunner = false;
  });

  tearDown(() {
    UpdateChecker.disableAutoCheckForTesting = false;
    DesktopLookupService.instance.debugReset();
    DesktopForegroundGuard.debugHiddenWindowsRunner = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  group('① 热键请求聚焦搜索框', () {
    testWidgets('从别的 tab 按热键：查词页挂载后搜索框直接持焦', (WidgetTester tester) async {
      final _HotkeyAppModel appModel = await _pumpHome(tester);
      expect(find.byType(HomeDictionaryPage), findsNothing);

      appModel.requestHomeDictionaryTab(focusSearch: true);
      await _settle(tester);

      expect(find.byType(HomeDictionaryPage), findsOneWidget);
      expect(
        _searchEditable(tester).focusNode.hasFocus,
        isTrue,
        reason: '热键的意图就是打字；页面弹出来还得先点一下搜索框等于热键只做了一半。',
      );
      await _unmount(tester);
    });

    testWidgets('已在查词页且框里有上次的词：再按热键 → 仍持焦且全选（打字即替换，不打则保留）',
        (WidgetTester tester) async {
      final _HotkeyAppModel appModel = await _pumpHome(tester);
      HomePage.debugSelectTab!(HomeTab.dictionaries);
      await _settle(tester);
      expect(find.byType(HomeDictionaryPage), findsOneWidget);

      await tester.enterText(find.byKey(_searchFieldKey), 'おばさん');
      await _settle(tester);
      // 把焦点挪走，模拟用户切去别的程序 / 点了别处。
      FocusManager.instance.primaryFocus?.unfocus();
      await _settle(tester);
      expect(_searchEditable(tester).focusNode.hasFocus, isFalse);

      appModel.requestHomeDictionaryTab(focusSearch: true);
      await _settle(tester);

      final EditableText editable = _searchEditable(tester);
      expect(editable.focusNode.hasFocus, isTrue,
          reason: '「已经在查词页」的早退分支也必须落地聚焦意图。');
      expect(editable.controller.text, 'おばさん', reason: '不清空：用户可能只是切回来看上次的结果。');
      expect(
        editable.controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 4),
        reason: '全选已有文本：直接打字就替换（浏览器地址栏 Ctrl+L 的模型）。',
      );
      await _unmount(tester);
    });

    testWidgets('携带待查词的请求（focusSearch 默认 false）不碰焦点',
        (WidgetTester tester) async {
      final _HotkeyAppModel appModel = await _pumpHome(tester);

      DesktopLookupService.instance.triggerLookup(' lyricword ');
      appModel.requestHomeDictionaryTab();
      await _settle(tester);

      expect(find.byType(HomeDictionaryPage), findsOneWidget);
      expect(appModel.searchedTerms, <String>['lyricword']);
      expect(
        _searchEditable(tester).focusNode.hasFocus,
        isFalse,
        reason: '悬浮字幕点词 / 桌面取词正要出词卡，抢焦点只会打断它。',
      );
      await _unmount(tester);
    });
  });

  group('② 查词页按「返回上一级」最小化主窗', () {
    testWidgets('偏好开着：搜索框持焦时按 Esc → window_manager 收到 minimize',
        (WidgetTester tester) async {
      final _HotkeyAppModel appModel = await _pumpHome(tester);
      await appModel.setLookupPageEscapeMinimizesWindow(true);
      await _settle(tester);

      appModel.requestHomeDictionaryTab(focusSearch: true);
      await _settle(tester);
      expect(_searchEditable(tester).focusNode.hasFocus, isTrue);
      await tester.enterText(find.byKey(_searchFieldKey), 'おばさん');
      await _settle(tester);
      _windowCalls.clear();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);

      expect(_windowCalls, contains('minimize'),
          reason: '一键收窗：不走「关弹窗 → 清查询」阶梯，直接最小化。');
      expect(
        _searchEditable(tester).controller.text,
        'おばさん',
        reason: '查询原样保留，下次热键回来全选后直接覆写。',
      );
      await _unmount(tester);
    });

    testWidgets('偏好关着（默认）：按 Esc 不发 minimize，仍走原有阶梯（清查询）',
        (WidgetTester tester) async {
      final _HotkeyAppModel appModel = await _pumpHome(tester);
      expect(appModel.lookupPageEscapeMinimizesWindow, isFalse,
          reason: '默认必须关：这是 opt-in 行为。');

      appModel.requestHomeDictionaryTab(focusSearch: true);
      await _settle(tester);
      await tester.enterText(find.byKey(_searchFieldKey), 'おばさん');
      await _settle(tester);
      _windowCalls.clear();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);

      expect(_windowCalls, isNot(contains('minimize')));
      expect(
        _searchEditable(tester).controller.text,
        isEmpty,
        reason: '改动前的行为：globalBack → maybePop → 本页 PopScope 阶梯清掉查询。',
      );
      await _unmount(tester);
    });

    testWidgets('偏好开着但不在查词页：Esc 与本功能无关，不发 minimize',
        (WidgetTester tester) async {
      final _HotkeyAppModel appModel = await _pumpHome(tester);
      await appModel.setLookupPageEscapeMinimizesWindow(true);
      await _settle(tester);
      expect(find.byType(HomeDictionaryPage), findsNothing);
      _windowCalls.clear();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);

      expect(_windowCalls, isNot(contains('minimize')),
          reason: '执行体只挂在查词页子树上，首页别的 tab 不受影响。');
      await _unmount(tester);
    });
  });
}
