import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
// ignore: depend_on_referenced_packages  — 测试桩需直接实现该平台接口（flutter_inappwebview 的传递依赖）
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/media/favorites/favorite_lookup_context.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/components/fushi_deferred_loading.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

  group('popup WebView lifecycle', () {
    testWidgets('live viewport injection failure still pushes first results',
        (WidgetTester tester) async {
      harness.failViewportInjection = true;
      await tester.pumpWidget(
        wrapPopup(
          appModel: PushDedupAppModel(),
          popup: DictionaryPopupWebView(result: makeResult('語')),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(harness.pushCount, 1,
          reason: 'viewport sizing is best-effort; lookup content must render');
      expect(tester.takeException(), isNull,
          reason: 'a live platform JS failure must be logged, not unhandled');
    });

    testWidgets(
        'controller teardown during viewport injection does not escape as an '
        'unhandled Flutter error', (WidgetTester tester) async {
      harness.blockViewportInjection = true;
      await tester.pumpWidget(
        wrapPopup(
          appModel: PushDedupAppModel(),
          popup: DictionaryPopupWebView(result: makeResult('語')),
        ),
      );
      await tester.pump(); // onWebViewCreated → onLoadStop
      await tester.pump(); // caret bootstrap → viewport injection starts

      final Completer<dynamic>? viewport = harness.pendingViewportInjection;
      expect(viewport, isNotNull,
          reason: 'the real popup must have started the Flutter-sized viewport '
              'injection before teardown');

      await tester.pumpWidget(const SizedBox.shrink());
      viewport!.completeError(StateError('controller disposed mid-flight'));
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: 'a platform controller can be disposed after the JS call '
              'starts; that lifecycle race must stay inside the popup');
    });
  });

  group('popup document reload', () {
    testWidgets('late loadStop from a replaced controller is ignored', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        wrapPopup(
          appModel: PushDedupAppModel(),
          popup: DictionaryPopupWebView(result: makeResult('語')),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        harness.hasDistinctControllerWrappers,
        isTrue,
        reason: 'Windows creates distinct wrappers around one platform',
      );
      expect(harness.pushCount, 1);
      await harness.firePopupRendered();
      final VoidCallback oldLoadStop = harness.captureLoadStop();

      harness.replaceController();
      harness.fireLoadStart();
      oldLoadStop();
      await tester.pump();
      await tester.pump();
      expect(
        harness.pushCount,
        1,
        reason: 'an old native view cannot complete the replacement load',
      );

      harness.fireLoadStop();
      await tester.pump();
      await tester.pump();
      expect(harness.pushCount, 2);
      await harness.firePopupRendered();
      oldLoadStop();
      await tester.pump();
      await tester.pump();
      expect(
        harness.pushCount,
        2,
        reason: 'a late old loadStop cannot invalidate the current document',
      );
      final DictionaryPopupWebViewState state = tester
          .state<DictionaryPopupWebViewState>(
            find.byType(DictionaryPopupWebView),
          );
      expect(state.refreshCurrentResult(), isFalse);
    });

    testWidgets(
      'rendered result reload sends full entries, static and extras',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          wrapPopup(
            appModel: PushDedupAppModel(),
            popup: DictionaryPopupWebView(result: makeResult('語')),
          ),
        );
        await tester.pump();
        await tester.pump();
        await harness.firePopupRendered();
        expect(harness.pushCount, 1);
        final int? oldToken = harness.lastRenderToken;

        harness.fireLoadStart();
        harness.fireLoadStop();
        await tester.pump();
        await tester.pump();

        expect(
          harness.pushCount,
          2,
          reason: 'the same Dart result belongs to a new, empty document',
        );
        final String script = harness.scripts.lastWhere(
          (String s) => s.contains('window.lookupEntries'),
        );
        for (final String marker in <String>[
          '語',
          'window.dictionaryStyles',
          'window.i18nCtx',
          'window.__fushiResetPopupScroll =',
          'window.renderPopup();',
        ]) {
          expect(script, contains(marker));
        }
        final DictionaryPopupWebViewState state = tester
            .state<DictionaryPopupWebViewState>(
              find.byType(DictionaryPopupWebView),
            );
        await harness.firePopupRendered(token: oldToken);
        expect(
          state.refreshCurrentResult(),
          isTrue,
          reason:
              'the old document render callback cannot complete the new one',
        );
        await harness.firePopupRendered();
        expect(state.refreshCurrentResult(), isFalse);
        expect(harness.pushCount, 2);
      },
    );

    testWidgets('result changes during navigation wait for the new document', (
      WidgetTester tester,
    ) async {
      final GlobalKey<ReorderProbeState> probe = GlobalKey<ReorderProbeState>();
      await tester.pumpWidget(
        wrapPopup(
          appModel: PushDedupAppModel(),
          popup: ReorderProbe(key: probe, initial: makeResult('語')),
        ),
      );
      await tester.pump();
      await tester.pump();
      await harness.firePopupRendered();
      expect(harness.pushCount, 1);

      harness.fireLoadStart();
      probe.currentState!.show(makeResult('途中'));
      await tester.pump();
      probe.currentState!.show(makeResult('最新'));
      await tester.pump();
      expect(
        harness.pushCount,
        1,
        reason: 'no result may be injected into a document being replaced',
      );

      harness.fireLoadStop();
      await tester.pump();
      await tester.pump();
      expect(harness.pushCount, 2);
      final String script = harness.scripts.lastWhere(
        (String s) => s.contains('window.lookupEntries'),
      );
      expect(script, contains('最新'));
      expect(script, isNot(contains('途中')));
      expect(script, contains('window.renderPopup();'));
    });

    for (final bool replaceController in <bool>[false, true]) {
      testWidgets(
        'stale bootstrap after ${replaceController ? "controller replacement" : "navigation"} '
        'cannot ready the new document',
        (WidgetTester tester) async {
          harness.blockViewportInjection = true;
          await tester.pumpWidget(
            wrapPopup(
              appModel: PushDedupAppModel(),
              popup: DictionaryPopupWebView(result: makeResult('語')),
            ),
          );
          await tester.pump();
          await tester.pump();
          final Completer<dynamic>? pending = harness.pendingViewportInjection;
          expect(pending, isNotNull);
          expect(harness.pushCount, 0);

          if (replaceController) harness.replaceController();
          harness.fireLoadStart();
          harness.blockViewportInjection = false;
          pending!.complete();
          await tester.pump();
          expect(
            harness.pushCount,
            0,
            reason: 'a prior bootstrap completion is not the new loadStop',
          );

          harness.fireLoadStop();
          await tester.pump();
          await tester.pump();
          expect(harness.pushCount, 1);
          expect(
            harness.scripts.lastWhere(
              (String s) => s.contains('window.lookupEntries'),
            ),
            contains('window.renderPopup();'),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
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

    testWidgets(
        'BUG-717 ③: the fixed in-app i18n/reset block is sent once, then '
        'omitted; a static-relevant pref flip resends BOTH static + extras',
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
      String lastPushScript() => harness.scripts
          .lastWhere((String s) => s.contains('window.lookupEntries'));
      // 首推：静态段 + in-app 固定块（__fushiResetPopupScroll / i18nCtx）都下发。
      expect(lastPushScript(), contains('window.i18nCtx'),
          reason: '首推必须带 in-app 固定块（新页面无 window.* 状态）');
      expect(lastPushScript(), contains('window.__fushiResetPopupScroll ='));
      await harness.firePopupRendered();

      final DictionaryPopupWebViewState state =
          tester.state<DictionaryPopupWebViewState>(
              find.byType(MutableResultPopupWebView));

      // 第二推（设置未变）：固定块与静态段一起省略——它此前每次查词重发 1-2KB。
      holder.value = makeResult('別');
      expect(state.refreshCurrentResult(), isTrue);
      await tester.pump();
      expect(harness.pushCount, 2);
      final String secondPush = lastPushScript();
      expect(secondPush, isNot(contains('window.i18nCtx')),
          reason: '设置未变时固定 i18n 块不得重复注入（并入静态段失效节奏）');
      expect(secondPush, isNot(contains('window.__fushiResetPopupScroll =')));
      expect(secondPush, contains('window.renderPopup()'));
      await harness.firePopupRendered();

      // 偏好翻转 → builder memo 失效换 revision → 第三推重发静态段 + 固定块。
      appModel.collapseDictionariesValue = true;
      holder.value = makeResult('猫');
      expect(state.refreshCurrentResult(), isTrue);
      await tester.pump();
      expect(harness.pushCount, 3);
      final String thirdPush = lastPushScript();
      expect(thirdPush, contains('window.collapseDictionaries = true'),
          reason: '偏好变化必须随下一次推送重发静态段（新值生效）');
      expect(thirdPush, contains('window.dictionaryStyles'));
      expect(thirdPush, contains('window.i18nCtx'), reason: '固定块随静态段版本一起重发');
      await harness.firePopupRendered();

      // 语言切换 → memo 键含 locale → 第四推重发（i18n 文案不得陈旧）。
      LocaleSettings.setLocale(AppLocale.ja);
      addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
      holder.value = makeResult('犬');
      expect(state.refreshCurrentResult(), isTrue);
      await tester.pump();
      expect(harness.pushCount, 4);
      final String fourthPush = lastPushScript();
      expect(fourthPush, contains('window.dictionaryStyles'),
          reason: '语言切换必须失效静态段（内嵌 i18n 文案）');
      expect(fourthPush, contains('window.i18nCtx'),
          reason: '语言切换必须重发固定 i18n 块，弹窗文案随语言更新');
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
      expect(_activeLoadingCover(), findsOneWidget,
          reason: '盖板在探询帧内确实架起过（结构没被绕开）');
      await tester.pump();

      // ……下一帧（零时长）盖板必须已撤，弹窗可见——不等 1.8s failsafe。
      final stack = hostKey.currentState!.debugPopupStack;
      expect(stack.single.visible, isTrue);
      expect(_activeLoadingCover(), findsNothing,
          reason: 'refreshCurrentResult 返回 false（已渲染完成、信号不会再来）时，'
              '宿主必须立即走 rendered 路径撤盖板，而不是空等 failsafe 超时');
      expect(harness.pushCount, seedPushes + 1, reason: '兜底探询对已渲染结果零重推');
      // 全程零时长 pump：若撤盖板路径没取消 1.8s failsafe Timer，testWidgets 会以
      // pending timer 失败——测试干净结束本身就是「不等 failsafe」的证据。
    });
  });

  group('PR#1913 按句意挑词条：只换顺序，不全量重渲染', () {
    /// 某一刻之后才出现的脚本（重排 / 重置都只看这一段）。
    List<String> scriptsSince(int index) => harness.scripts.sublist(index);

    testWidgets(
        'reorderOf 指向已推送的上一份结果：只发 fushiReorderPopupEntries，'
        '不 renderPopup、不滚回顶、不清已选释义、不归零句子镜像',
        (WidgetTester tester) async {
      final DictionarySearchResult base = makeKigen();
      final GlobalKey<ReorderProbeState> probe = GlobalKey<ReorderProbeState>();
      await tester.pumpWidget(
        wrapPopup(
          appModel: PushDedupAppModel(),
          popup: ReorderProbe(key: probe, initial: base),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(harness.pushCount, 1);
      await harness.firePopupRendered();
      final DictionaryPopupWebViewState state =
          tester.state<DictionaryPopupWebViewState>(
              find.byType(DictionaryPopupWebView));
      expect(state.refreshCurrentResult(), isFalse, reason: '前置：已渲染完成');

      final int mark = harness.scripts.length;
      probe.currentState!.show(swapKigen(base), reorderOf: base);
      await tester.pump();

      expect(harness.pushCount, 1, reason: '换序不得走全量推送');
      expect(harness.renderPopupCount, 1);
      final List<String> after = scriptsSince(mark);
      final List<String> reorders = after
          .where((String s) => s.contains('fushiReorderPopupEntries'))
          .toList();
      expect(reorders, hasLength(1));
      expect(reorders.single.indexOf('機嫌'),
          lessThan(reorders.single.indexOf('期限')),
          reason: '新顺序把 AI 选中的词头排在最前');
      for (final String marker in <String>[
        'resetSentenceContextMirror',
        'resetSelectedDictionaries',
        '__fushiResetPopupScroll()',
        'window.renderPopup()',
      ]) {
        expect(after.any((String s) => s.contains(marker)), isFalse,
            reason: '换序不得触发 $marker');
      }
      expect(state.refreshCurrentResult(), isFalse,
          reason: '换序后的结果视同已渲染：宿主不得因此补推一次全量');
      expect(harness.pushCount, 1);
    });

    testWidgets('reorderOf 不是页面上那一份：照常全量推送（宁可多渲染，不吞内容）',
        (WidgetTester tester) async {
      final DictionarySearchResult base = makeKigen();
      final GlobalKey<ReorderProbeState> probe = GlobalKey<ReorderProbeState>();
      await tester.pumpWidget(
        wrapPopup(
          appModel: PushDedupAppModel(),
          popup: ReorderProbe(key: probe, initial: base),
        ),
      );
      await tester.pump();
      await tester.pump();
      await harness.firePopupRendered();

      final int mark = harness.scripts.length;
      probe.currentState!.show(swapKigen(base), reorderOf: makeKigen());
      await tester.pump();
      expect(harness.pushCount, 2);
      expect(
        scriptsSince(mark)
            .any((String s) => s.contains('fushiReorderPopupEntries')),
        isFalse,
      );
    });

    testWidgets(
        '宿主：AI 选中第 2 个词头后弹窗只挪卡片，层记下 reorderBase，'
        '查词缓存那份结果不动', (WidgetTester tester) async {
      final PushDedupAppModel appModel = PushDedupAppModel(
        results: makeKigen().entries,
      );
      final hostKey = GlobalKey<DedupHostPageState>();
      await tester.pumpWidget(
        buildDedupHostApp(appModel: appModel, hostKey: hostKey),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final DedupHostPageState host = hostKey.currentState!;
      int calls = 0;
      host
        ..debugSentence = 'キゲンの悪いうみな'
        ..debugLookupAiProvider = (() => AiProviderConfig(
              id: 'p',
              presetId: kAiCustomPresetId,
              name: 'p',
              baseUrl: Uri.parse('https://example.com/v1'),
              apiKey: 'k',
              model: 'm',
            ))
        ..debugLookupAiClientFactory = () => AiChatClient(
              client: MockClient((http.Request request) async {
                calls++;
                return http.Response(
                  jsonEncode(<String, Object?>{
                    'choices': <Object?>[
                      <String, Object?>{
                        'message': <String, Object?>{
                          'content': '{"choice": 2}',
                        },
                      },
                    ],
                  }),
                  200,
                  headers: <String, String>{
                    'content-type': 'application/json',
                  },
                );
              }),
            );
      await host.deferredSearch('キゲン');
      await tester.pump();
      await harness.firePopupRendered();
      host.showDeferredPopup();
      await tester.pump();
      await tester.pump();
      final int pushes = harness.pushCount;
      final int mark = harness.scripts.length;

      final DictionaryPopupEntry entry = host.debugPopupEntries.last;
      final DictionarySearchResult before = entry.result!;
      await host.aiPickLookupEntry(entry);
      await tester.pump();

      expect(calls, 1);
      expect(entry.result!.entries.first.word, '機嫌');
      expect(identical(entry.reorderBase, before), isTrue,
          reason: '换序必须走 reorderResult，而不是 fillResult 全量换结果');
      expect(before.entries.first.word, '期限', reason: '查词缓存那份不动');
      expect(harness.pushCount, pushes, reason: '换序零全量推送');
      final List<String> after = scriptsSince(mark);
      expect(after.any((String s) => s.contains('fushiReorderPopupEntries')),
          isTrue);
      expect(after.any((String s) => s.contains('resetSentenceContextMirror')),
          isFalse,
          reason: '句子镜像不归零——宿主制卡草稿没清，两边必须一致（BUG-297）');
    });
  });
}

DictionarySearchResult makeKigen() => DictionarySearchResult(
      searchTerm: 'キゲン',
      bestLength: 3,
      entries: <DictionaryEntry>[
        DictionaryEntry(
            dictionaryName: 'd', word: '期限', reading: 'きげん', meaning: '"a"'),
        DictionaryEntry(
            dictionaryName: 'd', word: '機嫌', reading: 'きげん', meaning: '"b"'),
      ],
    );

/// [base] 的换序（第 2 个词头挪到最前）——与 promoteAiLookupCandidate 产物同形。
DictionarySearchResult swapKigen(DictionarySearchResult base) =>
    DictionarySearchResult(
      searchTerm: base.searchTerm,
      bestLength: base.bestLength,
      entries: <DictionaryEntry>[base.entries[1], base.entries[0]],
    );

/// 可换 result / reorderOf 的宿主（重建 widget，真走 didUpdateWidget）。
class ReorderProbe extends StatefulWidget {
  const ReorderProbe({super.key, required this.initial});
  final DictionarySearchResult initial;

  @override
  State<ReorderProbe> createState() => ReorderProbeState();
}

class ReorderProbeState extends State<ReorderProbe> {
  late DictionarySearchResult _result = widget.initial;
  DictionarySearchResult? _reorderOf;

  void show(DictionarySearchResult result,
      {DictionarySearchResult? reorderOf}) {
    setState(() {
      _result = result;
      _reorderOf = reorderOf;
    });
  }

  @override
  Widget build(BuildContext context) =>
      DictionaryPopupWebView(result: _result, reorderOf: _reorderOf);
}

// ───────────────────────── 记录桩（可数注入的假 WebView 平台） ─────────────────────────

/// 记录 WebView 往返的测试探针：脚本注入按顺序进 [scripts]，生产代码注册的 JS
/// 处理器进 [handlers]，供测试数推送次数、手动回放 popupRendered。
class RecordingWebViewHarness {
  final List<String> scripts = <String>[];
  final Map<String, JavaScriptHandlerCallback> handlers =
      <String, JavaScriptHandlerCallback>{};
  bool blockViewportInjection = false;
  bool failViewportInjection = false;
  Completer<dynamic>? pendingViewportInjection;

  late PlatformInAppWebViewWidgetCreationParams _params;
  dynamic _createdController;
  dynamic _controller;

  bool get hasDistinctControllerWrappers =>
      !identical(_createdController, _controller);

  /// Keep the same platform view while replaying document navigation events.
  void attach(PlatformInAppWebViewWidgetCreationParams params) {
    _params = params;
    replaceController();
    fireLoadStart();
    fireLoadStop();
  }

  void replaceController() {
    final _RecordingPlatformController platformController =
        _RecordingPlatformController(this);
    // Windows caches a wrapper for events in the platform controller, then
    // creates another wrapper for onWebViewCreated. Both own the same platform.
    _controller =
        _params.controllerFromPlatform?.call(platformController) ??
        platformController;
    _createdController =
        _params.controllerFromPlatform?.call(platformController) ??
        platformController;
    _params.onWebViewCreated?.call(_createdController);
  }

  void fireLoadStart() => _params.onLoadStart?.call(_controller, null);

  void fireLoadStop() => _params.onLoadStop?.call(_controller, null);

  VoidCallback captureLoadStop() {
    final dynamic controller = _controller;
    return () => _params.onLoadStop?.call(controller, null);
  }

  static final RegExp _tokenPattern =
      RegExp(r'window\.__fushiRenderToken = (\d+);');

  /// 结果推送次数：只有 _pushResults 的注入会 stamp render token，其它注入
  /// （主题变量 / instant-scroll / hasChildPopup）都不带，天然可数。
  int get pushCount => scripts
      .where((String s) => s.contains('window.__fushiRenderToken ='))
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
    widget.harness.attach(widget.params);
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
    if (harness.blockViewportInjection &&
        source.contains('--fushi-popup-viewport-width')) {
      final Completer<dynamic> pending = Completer<dynamic>();
      harness.pendingViewportInjection = pending;
      return pending.future;
    }
    if (harness.failViewportInjection &&
        source.contains('--fushi-popup-viewport-width')) {
      throw StateError('viewport JS rejected');
    }
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
  // BUG-1026：buildPopupStaticSettingsJs 现注入 popupWheelSpeed；本 fake 的 prefsRepo 为
  // null（记录桩不初始化偏好），须与其它注入 getter 一样直接给常量，否则真 getter 走
  // prefsRepo! 抛 Null check 使整个 _pushResults 中断（pushCount 归零）。
  @override
  double get popupWheelSpeed => 1.0;
  @override
  bool get popupInstantScroll => false;
  @override
  double get popupInstantScrollWheelStep => 0.5;
  @override
  double get popupInstantScrollTouchStep => 0.25;
  // BUG-2284：与 popupInstantScroll 同批新增的注入项；本 fake 的 prefsRepo 为 null，
  // 不覆写就会在 _pushResults 里抛 null check，pushCount 归零。
  @override
  bool get compactGlossaries => false;
  @override
  bool get dictionaryUnifiedStyle => true;
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
  // BUG-717 ③：可变，供「偏好翻转 → 静态段重发」用例驱动 memo 失效。
  bool collapseDictionariesValue = false;
  @override
  bool get collapseDictionaries => collapseDictionariesValue;
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
  /// 查词所在句（null = 走基类默认：读当前媒体源，本 harness 里为空）。
  String? debugSentence;

  @override
  FavoriteLookupContext? get favoriteLookupContext {
    final String? sentence = debugSentence;
    if (sentence == null) return super.favoriteLookupContext;
    return FavoriteLookupContext(sentence: sentence);
  }

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

/// 查词浮层的加载盖板（[FushiDeferredLoading]）当前是否在盖。
Finder _activeLoadingCover() => find.byWidgetPredicate(
  (Widget w) => w is FushiDeferredLoading && w.active,
);
