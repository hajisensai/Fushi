import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages  — 测试桩需直接实现该平台接口（flutter_inappwebview 的传递依赖）
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// BUG-712 P1 守卫：每次查词只把结果推进弹窗 WebView 一次。
///
/// 此前 didUpdateWidget 推一遍、宿主可见后一帧的 refreshCurrentResult 又无条件全量
/// 重推一遍——第二遍 stamp 的新 render token 会作废第一遍的 `popupRendered`，内容
/// 可见时刻被推迟到第二遍渲染完成（查词时延翻倍）。修复后 refreshCurrentResult
/// 变成三分支去重状态机：
///  - 当前结果已渲染完成（`identical(_lastRenderedResult, widget.result)`）→ 返回
///    false，宿主必须立即按已渲染处理（撤盖板），不空等 1.8s failsafe；
///  - 当前结果已推出、渲染在途（`identical(_lastPushedResult, widget.result)`）→
///    返回 true 且**不重推**；
///  - 否则（BUG-523 的「didUpdateWidget 未跑到 / 推送被漏掉」场景）→ 真正补推并
///    返回 true（安全网仍在）。
///
/// 既有 helpers/fake_inappwebview_platform.dart 的套件级桩「永不发生命周期回调」
/// （controller 恒 null，推送永远只排队），数不了注入次数；本文件自带一个会真发
/// onWebViewCreated → onLoadStop、并记录 evaluateJavascript 脚本与 JS 处理器的
/// 记录桩，用真实的 _pushResults / popupRendered 往返驱动上述状态机。
void main() {
  late RecordingWebViewHarness harness;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    harness = RecordingWebViewHarness();
    InAppWebViewPlatform.instance = RecordingInAppWebViewPlatform(harness);
  });

  // 归还套件级哑桩（flutter_test_config 装的），不让本文件的记录桩泄漏语义。
  tearDownAll(installFakeInAppWebViewPlatform);

  group('BUG-712 P1 refreshCurrentResult push dedup', () {
    testWidgets(
        'in-flight same result: refreshCurrentResult returns true '
        'without a second renderPopup injection', (WidgetTester tester) async {
      final appModel = PushDedupAppModel();
      await tester.pumpWidget(
        wrapPopup(
          appModel: appModel,
          popup: DictionaryPopupWebView(result: makeResult('語')),
        ),
      );
      await tester.pump(); // post-frame：onWebViewCreated → onLoadStop
      await tester.pump(); // loadStop 的 caret-script then → 初始 _pushResults 落地

      expect(harness.handlers, contains('popupRendered'),
          reason: '记录桩必须已把生产 JS 处理器接进来（生命周期真发出）');
      expect(harness.pushCount, 1, reason: '冷加载完成只有一次初始结果推送');

      final DictionaryPopupWebViewState state =
          tester.state<DictionaryPopupWebViewState>(
              find.byType(DictionaryPopupWebView));

      // 渲染在途（popupRendered 未回）：宿主可见后一帧的兜底探询不得重推——
      // 此前的第二推会用新 token 作废第一遍渲染（BUG-712 P1 的根因）。
      expect(state.refreshCurrentResult(), isTrue,
          reason: '在途结果的渲染信号稍后必到，返回 true 让宿主继续等');
      expect(state.refreshCurrentResult(), isTrue, reason: '重复探询幂等，依旧不重推');
      await tester.pump();

      expect(harness.pushCount, 1, reason: '同一结果在途时零重推（每次查词只推一次）');
      expect(harness.renderPopupCount, 1, reason: 'renderPopup() 注入只出现一次');
    });

    testWidgets(
        'popupRendered with the matching token flips refreshCurrentResult '
        'to false; a stale token does not', (WidgetTester tester) async {
      final appModel = PushDedupAppModel();
      int renderedCount = 0;
      await tester.pumpWidget(
        wrapPopup(
          appModel: appModel,
          popup: DictionaryPopupWebView(
            result: makeResult('語'),
            onRendered: () => renderedCount++,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(harness.pushCount, 1);

      final DictionaryPopupWebViewState state =
          tester.state<DictionaryPopupWebViewState>(
              find.byType(DictionaryPopupWebView));

      // 陈旧 token（被更新推送作废的前一遍渲染）回报：不得记「已渲染」，也不回调
      // onRendered——BUG-523 的 token 次序语义必须保留。
      await harness.firePopupRendered(token: 9999);
      await tester.pump();
      expect(renderedCount, 0, reason: '陈旧 token 不触发 onRendered');
      expect(state.refreshCurrentResult(), isTrue,
          reason: '陈旧 token 不算完成，当前推送仍在途');

      // 命中当前 token → 渲染完成。此后渲染信号不会再来，refreshCurrentResult
      // 必须返回 false，宿主据此立即撤盖板而不是空等 1.8s failsafe。
      await harness.firePopupRendered();
      await tester.pump();
      expect(renderedCount, 1);
      expect(state.refreshCurrentResult(), isFalse,
          reason: '已渲染完成的结果不再有 popupRendered，必须回 false');
      expect(harness.pushCount, 1, reason: 'false 分支自然也零重推');
    });

    testWidgets(
        'a swapped result object IS re-pushed by refreshCurrentResult '
        '(didUpdateWidget-missed safety net stays)',
        (WidgetTester tester) async {
      final appModel = PushDedupAppModel();
      // widget.result 可变替身：换结果对象但不重建 widget → didUpdateWidget 不跑，
      // 精确复现 BUG-523「隐藏/屏外槽的结果推送被漏掉」，refreshCurrentResult 是
      // 唯一安全网。
      final ResultHolder holder = ResultHolder(makeResult('語'));
      await tester.pumpWidget(
        wrapPopup(
          appModel: appModel,
          popup: MutableResultPopupWebView(holder: holder),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(harness.pushCount, 1);
      await harness.firePopupRendered();

      final DictionaryPopupWebViewState state =
          tester.state<DictionaryPopupWebViewState>(
              find.byType(MutableResultPopupWebView));
      expect(state.refreshCurrentResult(), isFalse, reason: '前置：旧结果已渲染完成');

      // 宿主换上了全新结果对象（既没渲染完、也不在途）。
      holder.value = makeResult('別');
      expect(state.refreshCurrentResult(), isTrue,
          reason: '漏推的新结果必须补推，返回 true 等它的 popupRendered');
      await tester.pump();

      expect(harness.pushCount, 2, reason: '安全网必须真正发出第二次注入');
      expect(harness.renderPopupCount, 2);
      expect(harness.scripts.last, contains('別'), reason: '补推注入的是新结果的词条');

      // 新推送 stamp 了新 token；其 popupRendered 回报后本结果彻底完成。
      await harness.firePopupRendered();
      expect(state.refreshCurrentResult(), isFalse);
      expect(harness.pushCount, 2);
    });
  });

  group('BUG-712 ③ static settings payload dedup', () {
    testWidgets(
        'a repeat push with unchanged settings omits the static payload '
        'but still carries the entries + renderPopup',
        (WidgetTester tester) async {
      final appModel = PushDedupAppModel();
      final ResultHolder holder = ResultHolder(makeResult('語'));
      await tester.pumpWidget(
        wrapPopup(
          appModel: appModel,
          popup: MutableResultPopupWebView(holder: holder),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(harness.pushCount, 1);
      // 结果推送脚本以 lookupEntries 为标记定位（push 之后还有 __hasChildPopup
      // 种子等小脚本，scripts.last 不一定是推送本体）。
      String lastPushScript() => harness.scripts
          .lastWhere((String s) => s.contains('window.lookupEntries'));
      // 首推（页面加载后第一次）：静态设置负载必须整体下发（新页面无 window.* 状态）。
      expect(lastPushScript(), contains('window.dictionaryStyles'),
          reason: '首推必须带静态设置负载');
      await harness.firePopupRendered();

      final DictionaryPopupWebViewState state =
          tester.state<DictionaryPopupWebViewState>(
              find.byType(MutableResultPopupWebView));
      // 换新结果触发第二次真实推送（安全网路径，与 P1 组用法一致）。
      holder.value = makeResult('別');
      expect(state.refreshCurrentResult(), isTrue);
      await tester.pump();
      expect(harness.pushCount, 2);

      // 第二推：主题/设置/词典集未变 → 静态段串级比对命中，整段跳过；每次查词
      // 只发词条 + renderPopup（BUG-712 ③——热槽 WebView 的 window.* 跨渲染持久，
      // 真实词典下重复注入是数十 KB 的纯带宽/解析浪费）。
      final String secondPush = lastPushScript();
      expect(secondPush, isNot(contains('window.dictionaryStyles')),
          reason: '静态设置负载未变化时不得重复注入');
      expect(secondPush, isNot(contains('window.customDictCSS')));
      expect(secondPush, contains('別'));
      expect(secondPush, contains('window.renderPopup()'));
    });
  });

  group('BUG-712 P1 host cover release on already-rendered result', () {
    testWidgets(
        'base_source_page post-frame drops the loading cover immediately '
        'when refreshCurrentResult reports already-rendered',
        (WidgetTester tester) async {
      final appModel = PushDedupAppModel(
        results: <DictionaryEntry>[
          DictionaryEntry(
            dictionaryName: 'd',
            word: '語',
            reading: 'ご',
            meaning: '"def"',
          ),
        ],
      );
      final hostKey = GlobalKey<DedupHostPageState>();
      await tester.pumpWidget(
        buildDedupHostApp(appModel: appModel, hostKey: hostKey),
      );
      await tester.pump(); // post-frame：热槽 seed
      await tester.pump(); // 热槽层挂载 WebView；记录桩发出生命周期回调
      await tester.pump(); // loadStop 链路的占位初始推送落地
      expect(harness.handlers, contains('popupRendered'));
      final int seedPushes = harness.pushCount; // 热槽种子（占位空结果）的推送

      // 阅读器 deferDisplay 真实时序：先查词填充（隐藏热槽层 didUpdateWidget 推送
      // 本次结果）……
      await hostKey.currentState!.deferredSearch('語');
      await tester.pump();
      expect(harness.pushCount, seedPushes + 1,
          reason: 'didUpdateWidget 对新结果推送一次（在途）');

      // ……popupRendered 先于盖板架起到达（正是 P1 修的竞态方向：渲染信号早到，
      // 等信号的宿主此前会空等 1.8s failsafe）。
      await harness.firePopupRendered();
      await tester.pump();

      // 再 reveal：_showPopupWaitingForRender 架盖板 + post-frame 探询。
      hostKey.currentState!.showDeferredPopup();
      await tester.pump();
      // 本帧确实架过盖板（渲染进树），post-frame 已拿到 false 并清态……
      expect(find.byType(LinearProgressIndicator), findsOneWidget,
          reason: '盖板在探询帧内确实架起过（结构没被绕开）');
      await tester.pump();

      // ……下一帧（零时长）盖板必须已撤，弹窗可见——不等 1.8s failsafe。
      final stack = hostKey.currentState!.debugPopupStack;
      expect(stack.single.visible, isTrue);
      expect(find.byType(LinearProgressIndicator), findsNothing,
          reason: 'refreshCurrentResult 返回 false（已渲染完成、信号不会再来）时，'
              '宿主必须立即走 rendered 路径撤盖板，而不是空等 failsafe 超时');
      expect(harness.pushCount, seedPushes + 1, reason: '兜底探询对已渲染结果零重推');
      // 全程零时长 pump：若撤盖板路径没取消 1.8s failsafe Timer，testWidgets 会以
      // pending timer 失败——测试干净结束本身就是「不等 failsafe」的证据。
    });
  });
}

// ───────────────────────── 记录桩（可数注入的假 WebView 平台） ─────────────────────────

/// 记录 WebView 往返的测试探针：脚本注入按顺序进 [scripts]，生产代码注册的 JS
/// 处理器进 [handlers]，供测试数推送次数、手动回放 popupRendered。
class RecordingWebViewHarness {
  final List<String> scripts = <String>[];
  final Map<String, JavaScriptHandlerCallback> handlers =
      <String, JavaScriptHandlerCallback>{};

  static final RegExp _tokenPattern =
      RegExp(r'window\.__hibikiRenderToken = (\d+);');

  /// 结果推送次数：只有 _pushResults 的注入会 stamp render token，其它注入
  /// （主题变量 / instant-scroll / hasChildPopup）都不带，天然可数。
  int get pushCount => scripts
      .where((String s) => s.contains('window.__hibikiRenderToken ='))
      .length;

  /// 全量 renderPopup() 注入次数（load-more 走 updatePopupIncremental 不计入）。
  int get renderPopupCount =>
      scripts.where((String s) => s.contains('window.renderPopup();')).length;

  /// 最近一次推送 stamp 的 render token（popup.js 会原样带回 popupRendered）。
  int? get lastRenderToken {
    for (final String s in scripts.reversed) {
      final Match? m = _tokenPattern.firstMatch(s);
      if (m != null) return int.parse(m.group(1)!);
    }
    return null;
  }

  /// 模拟 popup.js 渲染完成回报：
  /// `callHandler('popupRendered', scrollHeight, token)`（args 次序与
  /// assets/popup/popup.js 的 _firePopupRendered 一致）。默认带最近 stamp 的
  /// token（命中）；传 [token] 可模拟被作废的陈旧 token。
  Future<void> firePopupRendered({int? token}) async {
    final JavaScriptHandlerCallback handler = handlers['popupRendered']!;
    await handler(<dynamic>[0, token ?? lastRenderToken]);
  }
}

/// 会真发生命周期回调的 [InAppWebViewPlatform] 桩（对照 helpers 里的哑桩：那个
/// 永不回调，controller 恒 null，测不了推送计数）。
class RecordingInAppWebViewPlatform extends InAppWebViewPlatform {
  RecordingInAppWebViewPlatform(this.harness);
  final RecordingWebViewHarness harness;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
      PlatformInAppWebViewWidgetCreationParams params) {
    return _RecordingWebViewWidget(params, harness);
  }
}

class _RecordingWebViewWidget extends PlatformInAppWebViewWidget {
  _RecordingWebViewWidget(
      PlatformInAppWebViewWidgetCreationParams params, this.harness)
      : super.implementation(params);
  final RecordingWebViewHarness harness;

  @override
  Widget build(BuildContext context) =>
      _RecordingWebViewLifecycle(params: params, harness: harness);

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) {
    throw UnimplementedError(
        'controllerFromPlatform is not used by the recording fake');
  }

  @override
  void dispose() {}
}

class _RecordingWebViewLifecycle extends StatefulWidget {
  const _RecordingWebViewLifecycle(
      {required this.params, required this.harness});
  final PlatformInAppWebViewWidgetCreationParams params;
  final RecordingWebViewHarness harness;

  @override
  State<_RecordingWebViewLifecycle> createState() =>
      _RecordingWebViewLifecycleState();
}

class _RecordingWebViewLifecycleState
    extends State<_RecordingWebViewLifecycle> {
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    // 模拟真实平台视图：挂载后（帧末）才异步回调 onWebViewCreated → onLoadStop，
    // 与生产时序一致（loadStop 之后才允许 evaluateJavascript）。State 跨 rebuild
    // 存活、只发一次——宿主重建不等于换了一个新 WebView。
    WidgetsBinding.instance.addPostFrameCallback((_) => _fireLifecycle());
  }

  void _fireLifecycle() {
    if (!mounted || _fired) return;
    _fired = true;
    final _RecordingPlatformController platformController =
        _RecordingPlatformController(widget.harness);
    // 与真实平台实现一致：经 controllerFromPlatform 包成 app 侧 controller 再回调。
    final dynamic controller =
        widget.params.controllerFromPlatform?.call(platformController) ??
            platformController;
    widget.params.onWebViewCreated?.call(controller);
    widget.params.onLoadStop?.call(controller, null);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _RecordingPlatformController extends PlatformInAppWebViewController {
  _RecordingPlatformController(this.harness)
      : super.implementation(
            const PlatformInAppWebViewControllerCreationParams(id: 0));
  final RecordingWebViewHarness harness;

  @override
  Future<dynamic> evaluateJavascript(
      {required String source, ContentWorld? contentWorld}) async {
    harness.scripts.add(source);
    return null;
  }

  @override
  void addJavaScriptHandler(
      {required String handlerName,
      required JavaScriptHandlerCallback callback}) {
    harness.handlers[handlerName] = callback;
  }

  @override
  void dispose({bool isKeepAlive = false}) {}
}

// ───────────────────────── 测试替身 / 组装 ─────────────────────────

/// 本桩会让推送真正执行到 buildPopupSettingsJs，prefsRepo 未初始化的 late getter
/// 必须全部盖掉（对照既有 base_source_page 测试 fake，只是多盖注入路径的键）。
class PushDedupAppModel extends AppModel {
  PushDedupAppModel({this.results = const <DictionaryEntry>[]})
      : super(testPlatformServices());

  final List<DictionaryEntry> results;

  // ── 弹窗布局 / 搜索路径（照抄既有 base_source_page 测试 fake）──
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
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  // ── _pushResults / buildPopupSettingsJs 真跑到的注入 getter ──
  @override
  double get dictionaryFontSize => 16;
  @override
  bool get popupInstantScroll => false;
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

/// 持有可变结果的盒子（配合 [MutableResultPopupWebView]）。
class ResultHolder {
  ResultHolder(this.value);
  DictionarySearchResult value;
}

/// widget.result 可变的测试替身：换结果对象但不重建 widget（didUpdateWidget 不跑、
/// 不触发它的常规推送），把 refreshCurrentResult 的「补推安全网」分支单独暴露出来。
class MutableResultPopupWebView extends DictionaryPopupWebView {
  MutableResultPopupWebView({required this.holder, super.key})
      : super(result: holder.value);
  final ResultHolder holder;

  @override
  DictionarySearchResult get result => holder.value;
}

DictionarySearchResult makeResult(String term) => DictionarySearchResult(
      searchTerm: term,
      entries: <DictionaryEntry>[
        DictionaryEntry(
          dictionaryName: 'd',
          word: term,
          reading: 'よみ',
          meaning: '"def"',
        ),
      ],
    );

Widget wrapPopup({required AppModel appModel, required Widget popup}) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 320, height: 400, child: popup),
          ),
        ),
      ),
    ),
  );
}

// ───────────────────────── 宿主（base_source_page）harness ─────────────────────────

class DedupHostPage extends BaseSourcePage {
  const DedupHostPage({super.key}) : super(item: null);

  @override
  BaseSourcePageState<DedupHostPage> createState() => DedupHostPageState();
}

class DedupHostPageState extends BaseSourcePageState<DedupHostPage> {
  /// 阅读器查词路径：先查词填充（隐藏），高亮完成后再 showDeferredPopup reveal。
  Future<void> deferredSearch(String term) => searchDictionaryResult(
        searchTerm: term,
        selectionRect: const Rect.fromLTWH(40, 40, 8, 8),
        deferDisplay: true,
      );

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

Widget buildDedupHostApp({
  required AppModel appModel,
  required GlobalKey<DedupHostPageState> hostKey,
}) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => child ?? const SizedBox.shrink(),
        home: Scaffold(body: DedupHostPage(key: hostKey)),
      ),
    ),
  );
}
