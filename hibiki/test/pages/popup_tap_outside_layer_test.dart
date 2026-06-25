import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// TODO-834（反转 TODO-720 / BUG-403）：区分两种「点弹窗外」——
///  (A) 点**所有弹窗矩形外**的真空白（全屏 barrier `onTap`）= 一次性清整栈，触发会话
///      收尾（[onAllPopupsDismissed]），保留隐藏热槽。生产里 reader 的 barrier `onTap`
///      接到 [BaseSourcePageState.clearDictionaryResult]。
///  (B) 点**某层弹窗本体的空白区**（弹窗 `onTapOutside`）= 只关该层衍生的**后代**层，
///      保留本层 + 祖先（不关母代）。生产里接到 `_dismissDescendantsOf(index)`。点最顶层
///      （无后代）= no-op 栈不变。
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

  /// 测试入口 (A)：复刻生产「点所有弹窗外的真空白」（全屏 barrier onTap）= 清整栈。
  void tapBarrier() => clearDictionaryResult();

  /// 测试入口 (B)：复刻生产「点第 [index] 层弹窗本体空白」（弹窗 onTapOutside）=
  /// 只关该层衍生的后代层（保留本层 + 祖先）。
  void tapOutsideLayer(int index) => dismissDescendantsOf(index);

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

/// 建出「N 层都可见」的嵌套栈：seed 热槽 → 逐次查词（首词复用热槽，其余嵌套追加，
/// 空 entries → 立即可见）。返回时栈长度 = [terms].length，全部可见。
Future<void> buildVisibleLayers(
  WidgetTester tester,
  TapOutsideHostPageState host,
  List<String> terms,
) async {
  for (final String term in terms) {
    await host.search(term);
  }
  await tester.pump();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets(
      'tap on a middle layer body closes its descendants (3 -> 2), '
      'keeping that layer + ancestors and NOT ending the session',
      (tester) async {
    final appModel = TapOutsideTestAppModel();
    final hostKey = GlobalKey<TapOutsideHostPageState>();
    await tester.pumpWidget(
      buildTapOutsideTestApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await buildVisibleLayers(tester, host, <String>['a', 'b', 'c']);

    // 三层可见栈（index 0/1/2）。
    final threeStack = host.debugPopupStack;
    expect(threeStack, hasLength(3));
    expect(threeStack.every((e) => e.visible), isTrue);
    expect(host.debugTopVisiblePopupIndex, 2);

    host.allDismissedCalls = 0;
    host.stackChangedCalls = 0;

    // 点 index 1 本体空白 → 只关其后代（index 2），保留本层 (1) + 祖先 (0)。
    host.tapOutsideLayer(1);
    await tester.pump();

    final twoStack = host.debugPopupStack;
    expect(twoStack, hasLength(2), reason: '只关 index 1 的后代（index 2），留 0,1');
    expect(twoStack.every((e) => e.visible), isTrue, reason: '本层 + 祖先仍可见');
    expect(host.debugTopVisiblePopupIndex, 1);
    expect(host.allDismissedCalls, 0, reason: '没清整栈，不触发会话收尾');
    expect(host.stackChangedCalls, 1,
        reason: '关后代调一次 onDictionaryStackChanged');
  });

  testWidgets('tap on the top layer body is a no-op when it has no descendants',
      (tester) async {
    final appModel = TapOutsideTestAppModel();
    final hostKey = GlobalKey<TapOutsideHostPageState>();
    await tester.pumpWidget(
      buildTapOutsideTestApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await buildVisibleLayers(tester, host, <String>['a', 'b']);
    expect(host.debugPopupStack, hasLength(2));

    host.allDismissedCalls = 0;
    host.stackChangedCalls = 0;

    // 点顶层 (index 1) 本体空白 = 无后代 → no-op，栈不变。
    host.tapOutsideLayer(1);
    await tester.pump();

    expect(host.debugPopupStack, hasLength(2), reason: '点顶层无后代，栈不变');
    expect(host.debugTopVisiblePopupIndex, 1);
    expect(host.allDismissedCalls, 0, reason: 'no-op 不收尾');
    expect(host.stackChangedCalls, 0, reason: 'no-op 不触发栈变更钩子');
  });

  testWidgets(
      'barrier tap (true blank outside all popups) clears the whole stack '
      'and ends the session, keeping the hidden warm slot', (tester) async {
    final appModel = TapOutsideTestAppModel();
    final hostKey = GlobalKey<TapOutsideHostPageState>();
    await tester.pumpWidget(
      buildTapOutsideTestApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    final host = hostKey.currentState!;
    await buildVisibleLayers(tester, host, <String>['a', 'b', 'c']);
    expect(host.debugPopupStack, hasLength(3));

    host.allDismissedCalls = 0;

    // 点所有弹窗外真空白（barrier）→ 一次清整栈 + 会话收尾。
    host.tapBarrier();
    await tester.pump();

    expect(host.dictionaryPopupShown, isFalse, reason: '整栈清空，无可见弹窗');
    expect(host.allDismissedCalls, 1, reason: '清整栈触发一次会话收尾');
    // BUG-092：清整栈保留隐藏热槽（index 0，visible=false）而非销毁。
    final after = host.debugPopupStack;
    expect(after, hasLength(1), reason: '保留隐藏热槽');
    expect(after.single.isWarmSlot, isTrue);
    expect(after.single.visible, isFalse, reason: '热槽隐身复用，不可见');
  });
}
