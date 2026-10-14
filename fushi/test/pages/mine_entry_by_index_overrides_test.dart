import 'dart:convert';

import 'package:material_ui/material_ui.dart';
// ignore: depend_on_referenced_packages  — 测试桩需直接实现该平台接口（flutter_inappwebview 的传递依赖）
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi_anki/fushi_anki.dart';

import '../helpers/fake_inappwebview_platform.dart';
import 'dictionary_popup_push_dedup_test.dart'
    show PushDedupAppModel, makeResult, wrapPopup;

/// 「高级制卡」往返：[DictionaryPopupWebViewState.mineEntryByIndex] 带上的
/// [MiningRequestOverrides] 只并进**这一次**回点触发的制卡桥调用（mineEntry /
/// minedCardAction / updateEntry），往返结束即清——普通点「+」绝不带。
///
/// 记录桩模拟 popup.js 的回点：`callAsyncJavaScript` 收到
/// `fushiPopupMineEntryByIndex` 时，按当前模式同步调用生产代码注册的那个制卡桥
/// handler（真实 popup.js 里那颗「+」的 onclick 做的正是这件事），再回 true。
void main() {
  late _MineHarness harness;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    harness = _MineHarness();
    InAppWebViewPlatform.instance = _MinePlatform(harness);
  });

  tearDownAll(installFakeInAppWebViewPlatform);

  const MiningRequestOverrides overrides = MiningRequestOverrides(
    deckName: 'Mining::Novel',
    omitAudio: true,
    audioStartDeltaMs: -250,
  );

  Future<DictionaryPopupWebViewState> pumpPopup(
    WidgetTester tester, {
    required List<Map<String, String>> mined,
    required List<Map<String, String>> actions,
    required List<(int, Map<String, String>)> updated,
  }) async {
    await tester.pumpWidget(
      wrapPopup(
        appModel: PushDedupAppModel(),
        popup: DictionaryPopupWebView(
          result: makeResult('語'),
          onMineEntry: (Map<String, String> fields) async {
            mined.add(fields);
            return const MinePopupResult(ankiConnect: true, noteId: 1);
          },
          onMinedCardAction: (Map<String, String> fields) async {
            actions.add(fields);
            return const MinePopupResult(ankiConnect: true, noteId: 2);
          },
          onUpdateEntry: (int noteId, Map<String, String> fields) async {
            updated.add((noteId, fields));
            return MinePopupResult(ankiConnect: true, noteId: noteId);
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return tester.state<DictionaryPopupWebViewState>(
      find.byType(DictionaryPopupWebView),
    );
  }

  testWidgets('mineEntry：带覆盖项的往返把它并进 fields，之后的普通「+」不带', (
    WidgetTester tester,
  ) async {
    final List<Map<String, String>> mined = <Map<String, String>>[];
    final DictionaryPopupWebViewState state = await pumpPopup(
      tester,
      mined: mined,
      actions: <Map<String, String>>[],
      updated: <(int, Map<String, String>)>[],
    );
    harness.mode = _ClickMode.mineEntry;

    final bool clicked =
        await tester.runAsync(
              () => state.mineEntryByIndex(
                0,
                releaseWhenPayloadConsumed: false,
                overrides: overrides,
              ),
            )
            as bool;
    expect(clicked, isTrue);
    expect(mined, hasLength(1));
    expect(mined.single['expression'], '語', reason: '原有字段原样保留');
    final MiningRequestOverrides? read = MiningRequestOverrides.readFrom(
      mined.single,
    );
    expect(read, isNotNull);
    expect(read!.deckName, 'Mining::Novel');
    expect(read.omitAudio, isTrue);
    expect(read.audioStartDeltaMs, -250);
    // 后端读同一份 fields（AnkiMiningPayload.fromJson）也认得出来。
    expect(
      AnkiMiningPayload.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(mined.single)) as Map),
      ).overrides?.deckName,
      'Mining::Novel',
    );

    // 往返结束：用户再普通点一次「+」（popup.js 直接 callHandler mineEntry），不得带。
    await tester.runAsync(
      () => harness.handlers['mineEntry']!(<dynamic>[harness.entryFields]),
    );
    expect(mined, hasLength(2));
    expect(mined.last.containsKey(MiningRequestOverrides.wireKey), isFalse);
  });

  testWidgets('不带覆盖项（或覆盖项为空）的往返不留键', (WidgetTester tester) async {
    final List<Map<String, String>> mined = <Map<String, String>>[];
    final DictionaryPopupWebViewState state = await pumpPopup(
      tester,
      mined: mined,
      actions: <Map<String, String>>[],
      updated: <(int, Map<String, String>)>[],
    );
    harness.mode = _ClickMode.mineEntry;
    await tester.runAsync(
      () => state.mineEntryByIndex(0, releaseWhenPayloadConsumed: true),
    );
    await tester.runAsync(
      () => state.mineEntryByIndex(
        0,
        releaseWhenPayloadConsumed: true,
        overrides: const MiningRequestOverrides(),
      ),
    );
    expect(mined, hasLength(2));
    for (final Map<String, String> fields in mined) {
      expect(fields.containsKey(MiningRequestOverrides.wireKey), isFalse);
    }
  });

  testWidgets('minedCardAction：覆盖项进 fields，mineNew / overwrite 两条分支都带着', (
    WidgetTester tester,
  ) async {
    final List<Map<String, String>> actions = <Map<String, String>>[];
    final DictionaryPopupWebViewState state = await pumpPopup(
      tester,
      mined: <Map<String, String>>[],
      actions: actions,
      updated: <(int, Map<String, String>)>[],
    );
    harness.mode = _ClickMode.minedCardAction;
    final bool clicked =
        await tester.runAsync(
              () => state.mineEntryByIndex(
                0,
                releaseWhenPayloadConsumed: false,
                overrides: overrides,
              ),
            )
            as bool;
    expect(clicked, isTrue);
    expect(actions, hasLength(1));
    final Map<String, String> fields = actions.single;
    // 宿主（base_source_page / dictionary_page_mixin 的 onMinedCardAction*）两条分支
    // 都从这一份 fields 出发：mineNew 走 withAllowDuplicate 展开，overwrite 原样转交。
    final Map<String, String> mineNew = AnkiMiningPayload.withAllowDuplicate(
      fields,
    );
    expect(MiningRequestOverrides.readFrom(mineNew)?.deckName, 'Mining::Novel');
    expect(MiningRequestOverrides.readFrom(fields)?.omitAudio, isTrue);
  });

  testWidgets('updateEntry（绿 ✓ 覆写）：覆盖项同样并进 fields', (
    WidgetTester tester,
  ) async {
    final List<(int, Map<String, String>)> updated =
        <(int, Map<String, String>)>[];
    final DictionaryPopupWebViewState state = await pumpPopup(
      tester,
      mined: <Map<String, String>>[],
      actions: <Map<String, String>>[],
      updated: updated,
    );
    harness.mode = _ClickMode.updateEntry;
    await tester.runAsync(
      () => state.mineEntryByIndex(
        0,
        releaseWhenPayloadConsumed: false,
        overrides: overrides,
      ),
    );
    expect(updated, hasLength(1));
    expect(updated.single.$1, 42);
    expect(
      MiningRequestOverrides.readFrom(updated.single.$2)?.audioStartDeltaMs,
      -250,
    );
  });
}

enum _ClickMode { mineEntry, minedCardAction, updateEntry }

class _MineHarness {
  final Map<String, JavaScriptHandlerCallback> handlers =
      <String, JavaScriptHandlerCallback>{};
  _ClickMode mode = _ClickMode.mineEntry;
  late PlatformInAppWebViewWidgetCreationParams params;
  dynamic controller;

  /// popup.js 那颗「+」交给制卡桥的字段（应用内桥：JS 对象，值是字符串）。
  final Map<String, Object?> entryFields = <String, Object?>{
    'expression': '語',
    'reading': 'ご',
    'glossary': 'word',
  };

  void attach(PlatformInAppWebViewWidgetCreationParams p) {
    params = p;
    final _MineController platform = _MineController(this);
    controller = p.controllerFromPlatform?.call(platform) ?? platform;
    p.onWebViewCreated?.call(controller);
    p.onLoadStart?.call(controller, null);
    p.onLoadStop?.call(controller, null);
  }

  /// 模拟 `fushiPopupMineEntryByIndex`：点那颗按钮 → 按模式调对应的制卡桥。
  Future<CallAsyncJavaScriptResult> click() async {
    switch (mode) {
      case _ClickMode.mineEntry:
        await handlers['mineEntry']!(<dynamic>[entryFields]);
      case _ClickMode.minedCardAction:
        await handlers['minedCardAction']!(<dynamic>[entryFields]);
      case _ClickMode.updateEntry:
        await handlers['updateEntry']!(<dynamic>[
          <String, Object?>{'noteId': 42, 'fields': entryFields},
        ]);
    }
    return CallAsyncJavaScriptResult(value: true, error: null);
  }
}

class _MinePlatform extends InAppWebViewPlatform {
  _MinePlatform(this.harness);
  final _MineHarness harness;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _MineWebViewWidget(params, harness);
}

class _MineWebViewWidget extends PlatformInAppWebViewWidget {
  _MineWebViewWidget(super.params, this.harness) : super.implementation();
  final _MineHarness harness;

  @override
  Widget build(BuildContext context) =>
      _MineLifecycle(params: params, harness: harness);

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) {
    throw UnimplementedError('not used by the fake');
  }

  @override
  void dispose() {}
}

class _MineLifecycle extends StatefulWidget {
  const _MineLifecycle({required this.params, required this.harness});
  final PlatformInAppWebViewWidgetCreationParams params;
  final _MineHarness harness;

  @override
  State<_MineLifecycle> createState() => _MineLifecycleState();
}

class _MineLifecycleState extends State<_MineLifecycle> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.harness.attach(widget.params);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _MineController extends PlatformInAppWebViewController {
  _MineController(this.harness)
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 0),
      );
  final _MineHarness harness;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async => null;

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const <String, dynamic>{},
    ContentWorld? contentWorld,
  }) async {
    if (functionBody.contains('fushiPopupMineEntryByIndex')) {
      return harness.click();
    }
    return null;
  }

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  }) {
    harness.handlers[handlerName] = callback;
  }

  @override
  void dispose({bool isKeepAlive = false}) {}
}
