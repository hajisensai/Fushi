import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// TODO-720 / BUG-403: 点查词弹窗外面只关**最顶层一层**（逐层退回父层），不一次
/// 清掉整个嵌套栈。生产里 reader 的 barrier `onTap` 与弹窗 `onTapOutside` 都接到
/// [BaseSourcePageState.dismissTopPopup]，这里直接驱动该入口断言逐层关语义：两层
/// 可见栈 → 点外一次 → 2→1 保留父层、`onAllPopupsDismissed` 未触发；再点一次 → 关
/// 到最后一层触发会话收尾。
///
/// 真实 [DictionaryPopupWebView] 在单测 harness 起不来，故经 `debugPopupStack` 断言
/// 栈生命周期（宿主不渲染 buildDictionary）。
class TapOutsideTestAppModel extends AppModel {
  TapOutsideTestAppModel() : super(testPlatformServices());

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
    // 空 entries → searchDictionaryResult 走 revealImmediately（不依赖 WebView
    // 渲染回调即可翻可见），让嵌套层在单测里也能成为「可见层」。
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

class TapOutsideHostPage extends BaseSourcePage {
  const TapOutsideHostPage({super.key}) : super(item: null);

  @override
  BaseSourcePageState<TapOutsideHostPage> createState() =>
      TapOutsideHostPageState();
}

class TapOutsideHostPageState extends BaseSourcePageState<TapOutsideHostPage> {
  int allDismissedCalls = 0;
  int stackChangedCalls = 0;

  @override
  void onAllPopupsDismissed() {
    allDismissedCalls++;
  }

  @override
  void onDictionaryStackChanged() {
    stackChangedCalls++;
  }

  Future<void> search(String term) {
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
    );
  }

  /// 测试入口：复刻生产「点弹窗外」的接线（barrier onTap / onTapOutside 都调
  /// [dismissTopPopup]）。
  void tapOutside() => dismissTopPopup();

  /// 撤修复对照：旧行为是点外直接清整栈（会话级路径）。
  void tapOutsideOldBehavior() => clearDictionaryResult();

  /// 转发受保护的 [topVisiblePopupIndex]，供测试断言（直接读会报
  /// invalid_use_of_protected_member）。
  int get debugTopVisiblePopupIndex => topVisiblePopupIndex;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Widget buildTapOutsideTestApp({
  required AppModel appModel,
  required GlobalKey<TapOutsideHostPageState> hostKey,
}) {
  return ProviderScope(
    overrides: [
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => Spacing(
          dataBuilder: (context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: TapOutsideHostPage(key: hostKey),
        ),
      ),
    ),
  );
}

/// 建出「两层都可见」的嵌套栈：seed 热槽 → 查 first（复用热槽，可见）→ 查 second
/// （嵌套追加，空 entries → 立即可见）。
Future<void> buildTwoVisibleLayers(
  WidgetTester tester,
  TapOutsideHostPageState host,
) async {
  await host.search('first');
  await host.search('second');
  await tester.pump();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
      'tap-outside on a nested stack closes only the top layer (2 -> 1), '
      'keeping the parent and NOT ending the session', (tester) async {
    final appModel = TapOutsideTestAppModel();
    final hostKey = GlobalKey<TapOutsideHostPageState>();
    await tester.pumpWidget(
      buildTapOutsideTestApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await buildTwoVisibleLayers(tester, host);

    // 两层可见栈。
    final twoStack = host.debugPopupStack;
    expect(twoStack, hasLength(2));
    expect(twoStack.every((e) => e.visible), isTrue);
    expect(host.debugTopVisiblePopupIndex, 1);

    host.allDismissedCalls = 0;
    host.stackChangedCalls = 0;

    // 点弹窗外一次 → 只关最顶层（index 1），保留父层（index 0 仍可见）。
    host.tapOutside();
    await tester.pump();

    final oneStack = host.debugPopupStack;
    expect(oneStack, hasLength(1), reason: '只关最顶层一层，父层应保留');
    expect(oneStack.single.visible, isTrue, reason: '父层仍可见');
    expect(host.debugTopVisiblePopupIndex, 0);
    expect(host.allDismissedCalls, 0, reason: '还没关到最后一层，不触发会话收尾');
    expect(host.stackChangedCalls, 1, reason: '关子层走 onDictionaryStackChanged');
  });

  testWidgets(
      'tapping outside again on the last layer ends the session '
      '(onAllPopupsDismissed fires)', (tester) async {
    final appModel = TapOutsideTestAppModel();
    final hostKey = GlobalKey<TapOutsideHostPageState>();
    await tester.pumpWidget(
      buildTapOutsideTestApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await buildTwoVisibleLayers(tester, host);
    expect(host.debugPopupStack, hasLength(2));

    host.allDismissedCalls = 0;

    // 第一次点外：2 -> 1（保留父层），不收尾。
    host.tapOutside();
    await tester.pump();
    expect(host.dictionaryPopupShown, isTrue);
    expect(host.allDismissedCalls, 0);

    // 第二次点外：关到最后一层 → 触发会话收尾。
    host.tapOutside();
    await tester.pump();
    expect(host.dictionaryPopupShown, isFalse, reason: '最后一层关掉，无可见弹窗');
    expect(host.allDismissedCalls, 1, reason: '关到最后一层触发会话收尾');
  });

  testWidgets(
      'regression contrast: old whole-stack clear ends the session immediately '
      'even with a parent layer present', (tester) async {
    final appModel = TapOutsideTestAppModel();
    final hostKey = GlobalKey<TapOutsideHostPageState>();
    await tester.pumpWidget(
      buildTapOutsideTestApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await buildTwoVisibleLayers(tester, host);
    expect(host.debugPopupStack, hasLength(2));

    host.allDismissedCalls = 0;

    // 旧行为（清整栈）：一次就清掉两层并立即收尾——正是 BUG-403 要避免的。
    host.tapOutsideOldBehavior();
    await tester.pump();
    expect(host.dictionaryPopupShown, isFalse);
    expect(host.allDismissedCalls, 1, reason: '清整栈一次就收尾（与逐层关相反），用于对照确认修复改了行为');
  });
}
