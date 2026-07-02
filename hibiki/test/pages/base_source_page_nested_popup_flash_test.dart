import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// TODO-058: the SECOND (nested) dictionary popup must not flash white. The
/// first lookup reuses the pre-warmed WebView (warm slot) so it shows instantly
/// with content; a nested lookup appends a brand-new (cold) WebView, and if it
/// were shown the moment the FFI result arrives it would reveal a blank
/// WebView that has not yet cold-loaded popup.html/JS/CSS — the white flash.
///
/// The fix gates a cold nested layer's visibility on its WebView actually
/// rendering (`popupRendered` -> `onRendered`): it stays hidden (pending) until
/// rendered, the parent stays visible meanwhile, then it reveals. These tests
/// assert that lifecycle via [debugPopupStack] + [debugFirePopupRendered] (the
/// fake test WebView never fires real lifecycle callbacks).
class NestedFlashAppModel extends AppModel {
  NestedFlashAppModel({this.results = const <DictionaryEntry>[]})
      : super(testPlatformServices());

  /// Entries every searchDictionary returns. Non-empty -> the nested cold layer
  /// must wait for render; empty -> the "no results" Flutter placeholder shows
  /// immediately (no WebView render to wait for).
  final List<DictionaryEntry> results;

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 360;

  @override
  double get popupMaxHeight => 360;

  // TODO-108: popupBottomDocked 读 prefsRepo（本 fake 未 wire），与现有
  // popupMaxWidth/Height 同属弹窗布局路径，照例覆写避免 prefsRepo 空指针。
  @override
  bool get popupBottomDocked => false;

  @override
  double get appUiScale => 1.0;

  @override
  List<String> get enabledAudioSources => const <String>[];

  // 该 fake 不跑 initialise()，prefsRepo 是未初始化 late；autoRead 路径读它会抛
  // （被 _autoReadWord 的 try/catch 吞掉，但污染测试日志）→ 直接断空。
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];

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
    return DictionarySearchResult(searchTerm: searchTerm, entries: results);
  }
}

class NestedFlashHostPage extends BaseSourcePage {
  const NestedFlashHostPage({super.key}) : super(item: null);

  @override
  BaseSourcePageState<NestedFlashHostPage> createState() =>
      NestedFlashHostPageState();
}

class NestedFlashHostPageState
    extends BaseSourcePageState<NestedFlashHostPage> {
  Future<void> topSearch(String term) {
    // Top-level lookup mirrors the reader: prune to the warm slot first.
    prunePopupStack(0);
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
    );
  }

  Future<void> deferredTopSearch(String term) async {
    // Reader lookup path: search first, highlight in the source WebView, then
    // reveal the popup via showDeferredPopup.
    prunePopupStack(0);
    await searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
      deferDisplay: true,
    );
    showDeferredPopup(selectionRect: const Rect.fromLTWH(44, 44, 8, 8));
  }

  /// Mimics a nested lookup fired from inside the parent popup
  /// (DictionaryPopupLayer.onTextSelected): keep the parent (index 0) and
  /// append a child.
  Future<void> nestedSearch(String term) {
    prunePopupStack(1);
    return searchDictionaryResult(
      searchTerm: term,
      selectionRect: const Rect.fromLTWH(120, 120, 8, 8),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        const Positioned.fill(child: SizedBox.expand()),
        buildDictionary(),
      ],
    );
  }
}

Widget buildNestedFlashApp({
  required AppModel appModel,
  required GlobalKey<NestedFlashHostPageState> hostKey,
}) {
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => Spacing(
          dataBuilder: (context) => SpacingData.generate(10),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: NestedFlashHostPage(key: hostKey)),
      ),
    ),
  );
}

DictionaryEntry _entry() => DictionaryEntry(
      dictionaryName: 'd',
      word: 'b',
      reading: 'b',
      meaning: '"def"',
    );

void main() {
  setUpAll(installFakeInAppWebViewPlatform);
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets(
      'nested cold popup stays hidden until its WebView renders, '
      'parent stays visible (no white flash)', (WidgetTester tester) async {
    final appModel = NestedFlashAppModel(results: <DictionaryEntry>[_entry()]);
    final hostKey = GlobalKey<NestedFlashHostPageState>();

    await tester.pumpWidget(
      buildNestedFlashApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump(); // post-frame warm-slot seed
    await tester.pump();

    // First lookup reuses the warm slot -> visible immediately (warm WebView).
    await hostKey.currentState!.topSearch('first');
    await tester.pump();
    var stack = hostKey.currentState!.debugPopupStack;
    expect(stack, hasLength(1));
    expect(stack.single.visible, isTrue, reason: '首个查词复用热槽，立即可见');
    expect(stack.single.revealOnRender, isFalse);

    // Nested lookup appends a fresh COLD WebView entry. It must NOT be visible
    // yet (would flash white); it waits for render. Parent stays visible.
    await hostKey.currentState!.nestedSearch('second');
    await tester.pump();
    stack = hostKey.currentState!.debugPopupStack;
    expect(stack, hasLength(2));
    expect(stack[0].visible, isTrue, reason: '父弹窗保持可见，用户不见空窗');
    expect(stack[1].visible, isFalse, reason: '嵌套冷层结果就绪也先不显示，等渲染完成（消除白屏一瞬）');
    expect(stack[1].revealOnRender, isTrue, reason: '挂起等 popupRendered');
    // The child WebView is a NEW cold one, not the parent/warm slot's.
    expect(stack[1].webViewKey, isNot(same(stack[0].webViewKey)));

    // Simulate the child WebView firing popupRendered -> it reveals now.
    hostKey.currentState!.debugFirePopupRendered(1);
    await tester.pump();
    stack = hostKey.currentState!.debugPopupStack;
    expect(stack[1].visible, isTrue, reason: '渲染完成后才翻可见');
    expect(stack[1].revealOnRender, isFalse);
  });

  testWidgets(
      'nested lookup with NO results reveals immediately '
      '(Flutter placeholder, no WebView render to await)',
      (WidgetTester tester) async {
    final appModel = NestedFlashAppModel(results: const <DictionaryEntry>[]);
    final hostKey = GlobalKey<NestedFlashHostPageState>();

    await tester.pumpWidget(
      buildNestedFlashApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    await hostKey.currentState!.topSearch('first');
    await tester.pump();
    await hostKey.currentState!.nestedSearch('second');
    await tester.pump();

    final stack = hostKey.currentState!.debugPopupStack;
    expect(stack, hasLength(2));
    // Empty results render the "no results" Flutter placeholder, not a WebView,
    // so there is nothing to cold-load -> reveal immediately, no pending.
    expect(stack[1].visible, isTrue);
    expect(stack[1].revealOnRender, isFalse);
  });

  testWidgets(
      'reader deferred warm-slot lookup keeps loading cover until popupRendered',
      (WidgetTester tester) async {
    final appModel = NestedFlashAppModel(results: <DictionaryEntry>[_entry()]);
    final hostKey = GlobalKey<NestedFlashHostPageState>();

    await tester.pumpWidget(
      buildNestedFlashApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    await hostKey.currentState!.deferredTopSearch('first');
    await tester.pump();

    var stack = hostKey.currentState!.debugPopupStack;
    expect(stack, hasLength(1));
    expect(stack.single.visible, isTrue,
        reason: 'showDeferredPopup should reveal the shell at the final rect');
    expect(find.byType(LinearProgressIndicator), findsOneWidget,
        reason: 'The body must stay covered until the reused WebView reports '
            'that this lookup has rendered; otherwise macOS can expose a '
            'white empty WebView body.');

    hostKey.currentState!.debugFirePopupRendered(0);
    await tester.pump();

    stack = hostKey.currentState!.debugPopupStack;
    expect(stack.single.visible, isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing,
        reason: 'popupRendered clears the temporary cover.');
  });

  testWidgets(
      'reader deferred warm-slot lookup with no entries shows the '
      'Flutter no-results placeholder immediately',
      (WidgetTester tester) async {
    final appModel = NestedFlashAppModel(results: const <DictionaryEntry>[]);
    final hostKey = GlobalKey<NestedFlashHostPageState>();

    await tester.pumpWidget(
      buildNestedFlashApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    await hostKey.currentState!.deferredTopSearch('missing');
    await tester.pump();

    final stack = hostKey.currentState!.debugPopupStack;
    expect(stack, hasLength(1));
    expect(stack.single.isWarmSlot, isTrue);
    expect(stack.single.visible, isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing,
        reason: 'A completed empty lookup has no WebView content to wait for; '
            'waiting exposes the warm WebView shell as a blank white body.');
    expect(find.text(t.no_search_results), findsOneWidget);
  });

  // ── TODO-058 fail-safe：popupRendered 永不发也不卡死 ──────────────────────
  testWidgets(
      'nested cold popup reveals via timeout fail-safe when popupRendered '
      'never fires (no permanent hidden popup)', (WidgetTester tester) async {
    final appModel = NestedFlashAppModel(results: <DictionaryEntry>[_entry()]);
    final hostKey = GlobalKey<NestedFlashHostPageState>();

    await tester.pumpWidget(
      buildNestedFlashApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    await hostKey.currentState!.topSearch('first');
    await tester.pump();
    await hostKey.currentState!.nestedSearch('second');
    await tester.pump();

    var stack = hostKey.currentState!.debugPopupStack;
    expect(stack, hasLength(2));
    expect(stack[1].visible, isFalse, reason: '挂起期不可见');
    expect(stack[1].revealOnRender, isTrue);

    // 故意永不触发 popupRendered（debugFirePopupRendered）：模拟 WebView 加载失败 /
    // renderPopup 抛异常 / callHandler 失败。超时兜底必须最终把它翻可见。
    await tester.pump(
      DictionaryPopupController.kRevealFailsafeTimeout +
          const Duration(milliseconds: 50),
    );
    stack = hostKey.currentState!.debugPopupStack;
    expect(stack[1].visible, isTrue,
        reason: 'popupRendered 永不发，超时兜底强制翻可见，不卡死「点查词什么都不出」');
    expect(stack[1].revealOnRender, isFalse);
  });

  testWidgets(
      'nested cold popup reveals on load error (onRenderError) before timeout',
      (WidgetTester tester) async {
    final appModel = NestedFlashAppModel(results: <DictionaryEntry>[_entry()]);
    final hostKey = GlobalKey<NestedFlashHostPageState>();

    await tester.pumpWidget(
      buildNestedFlashApp(appModel: appModel, hostKey: hostKey),
    );
    await tester.pump();
    await tester.pump();

    await hostKey.currentState!.topSearch('first');
    await tester.pump();
    await hostKey.currentState!.nestedSearch('second');
    await tester.pump();

    var stack = hostKey.currentState!.debugPopupStack;
    expect(stack[1].visible, isFalse, reason: '挂起等渲染/错误信号');

    // WebView 主框架加载失败 -> onReceivedError -> onRenderError -> 立即翻可见。
    hostKey.currentState!.debugFirePopupRenderError(1);
    await tester.pump();
    stack = hostKey.currentState!.debugPopupStack;
    expect(stack[1].visible, isTrue, reason: '加载失败也显示，不卡死');
    expect(stack[1].revealOnRender, isFalse);

    // 让超时窗口过去：错误已取消 Timer，无残留计时器报「Timer still pending」。
    await tester.pump(
      DictionaryPopupController.kRevealFailsafeTimeout +
          const Duration(milliseconds: 50),
    );
  });
}
