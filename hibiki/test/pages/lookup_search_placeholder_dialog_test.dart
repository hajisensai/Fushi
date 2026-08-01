import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/test_platform_services.dart';

/// BUG-1364（BUG-797 / BUG-1040 / BUG-1327 同族遗留）：查词浮层子树里「搜索中」的
/// 加载占位卡此前没接 `_popupHidingDialogDepth`。
///
/// 三个走**根 Overlay** 的宿主（视频页 / 首页词典页 / texthooker）与常驻根 builder 的
/// 悬浮歌词 host，整棵浮层子树都排在 `showAppDialog` 推的路由之上；对话框打开期间
/// barrier 与弹窗层都已让位，唯独这张不透明占位卡照画 → 盖住对话框。
///
/// 触发时序真实存在：对话框打开期间再起一次**顶层**查词时，
/// [DictionaryPopupController.beginTop] 会把复用的热槽 / 新目标置 `visible = false`，
/// 于是 `hasVisiblePopup` 变假、`pushNestedPopup` 进搜索占位态。这类查词不需要点到
/// app 本体（对话框模态遮罩挡不住它们）：悬浮歌词是独立系统窗口，texthooker /
/// 全局查词的文本来自 app 外。
///
/// 本测试直接构造「搜索中 → 此时打开对话框」的时序，断言占位卡真的让位（不在树里
/// 渲染），且外层 [Positioned] 槽位仍在（宿主 Stack 子项数与布局不变），对话框关闭
/// 后复原；并覆盖嵌套对话框（计数）不被内层 `finally` 提前复位。
class _PlaceholderTestAppModel extends AppModel {
  _PlaceholderTestAppModel({this.results = const <DictionaryEntry>[]})
      : super(testPlatformServices());

  final List<DictionaryEntry> results;

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
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

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

/// 复刻三个根 Overlay 宿主的浮层 Stack 构成（占位卡 + 弹窗层），不牵扯 media_kit /
/// 真实页面。
class _PlaceholderHostPage extends ConsumerStatefulWidget {
  const _PlaceholderHostPage({super.key});

  @override
  ConsumerState<_PlaceholderHostPage> createState() =>
      _PlaceholderHostPageState();
}

class _PlaceholderHostPageState extends ConsumerState<_PlaceholderHostPage>
    with DictionaryPageMixin {
  final DictionaryPopupController controller =
      DictionaryPopupController(lowMemory: false);

  @override
  AppModel get mixinAppModel => ref.read(appProvider);

  @override
  ThemeData get mixinTheme => Theme.of(context);

  /// 收尾：把 [DictionaryPopupController.markPendingReveal] 挂的兜底 Timer 落地，
  /// 否则 widget 树 dispose 后仍有 pending timer，测试框架直接判红。
  void settlePendingReveal() {
    setState(() {
      for (final DictionaryPopupEntry entry in controller.entries) {
        controller.revealRendered(entry);
      }
      controller.endSearchUi();
    });
  }

  Future<int> lookup(String term) => pushNestedPopup(
        query: term,
        selectionRect: const Rect.fromLTWH(20, 20, 4, 4),
        controller: controller,
        replaceStack: true,
        autoRead: false,
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size screen = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            if (controller.isSearchingUi && controller.pendingRect != null)
              buildPopupLoadingPlaceholder(
                rect: controller.pendingRect!,
                screen: screen,
              ),
            for (int i = 0; i < controller.entries.length; i++)
              buildNestedPopupLayer(
                index: i,
                screen: screen,
                controller: controller,
                onPush: (String text, Rect rect) async => 0,
                onPop: (int index) {},
              ),
          ],
        );
      },
    );
  }
}

Widget _wrap(AppModel appModel, GlobalKey<_PlaceholderHostPageState> key) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: Scaffold(body: _PlaceholderHostPage(key: key)),
      ),
    ),
  );
}

/// 占位卡「正在画」的判据：外层 [Positioned] 槽位内还有那条进度条。
Finder get _placeholderProgress => find.descendant(
      of: find.byKey(kLookupSearchPlaceholderKey),
      matching: find.byType(LinearProgressIndicator),
    );

void main() {
  setUpAll(installFakeInAppWebViewPlatform);

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('搜索中占位卡在对话框期间让位，对话框关闭后复原', (WidgetTester tester) async {
    final GlobalKey<_PlaceholderHostPageState> key =
        GlobalKey<_PlaceholderHostPageState>();
    await tester.pumpWidget(
      _wrap(
        _PlaceholderTestAppModel(
          results: <DictionaryEntry>[
            DictionaryEntry(word: '語', reading: 'ご', meaning: 'word'),
          ],
        ),
        key,
      ),
    );

    final _PlaceholderHostPageState state = key.currentState!;
    await state.lookup('語');
    await tester.pump();

    // 「搜索中」窗口期：结果已到但还在等 WebView render 信号，占位卡在画。
    expect(state.controller.isSearchingUi, isTrue);
    expect(find.byKey(kLookupSearchPlaceholderKey), findsOneWidget);
    expect(_placeholderProgress, findsOneWidget, reason: '搜索中占位卡本该可见');

    // 此刻打开一个「必须盖住查词弹窗」的对话框。
    final Completer<void> dialog = Completer<void>();
    final Future<void> hidden =
        state.runWithLookupPopupHidden<void>(() => dialog.future);
    await tester.pump();

    expect(state.controller.isSearchingUi, isTrue,
        reason: '对话框不改变搜索状态，占位卡的显示条件仍成立');
    expect(_placeholderProgress, findsNothing,
        reason: 'BUG-1364：浮层子树排在对话框路由之上，占位卡必须与 barrier / 弹窗层'
            '一起让位，否则这张不透明小卡画在对话框上面');
    expect(find.byKey(kLookupSearchPlaceholderKey), findsOneWidget,
        reason: '让位只藏内容：Positioned 槽位保留，宿主 Stack 子项数与布局不变');

    dialog.complete();
    await hidden;
    await tester.pump();

    expect(_placeholderProgress, findsOneWidget, reason: '对话框关闭后占位卡复原');

    state.settlePendingReveal();
    await tester.pump();
  });

  testWidgets('嵌套对话框：内层关闭不提前放出占位卡', (WidgetTester tester) async {
    final GlobalKey<_PlaceholderHostPageState> key =
        GlobalKey<_PlaceholderHostPageState>();
    await tester.pumpWidget(
      _wrap(
        _PlaceholderTestAppModel(
          results: <DictionaryEntry>[
            DictionaryEntry(word: '語', reading: 'ご', meaning: 'word'),
          ],
        ),
        key,
      ),
    );

    final _PlaceholderHostPageState state = key.currentState!;
    await state.lookup('語');
    await tester.pump();
    expect(_placeholderProgress, findsOneWidget);

    final Completer<void> outer = Completer<void>();
    final Completer<void> inner = Completer<void>();
    final Future<void> outerRun =
        state.runWithLookupPopupHidden<void>(() => outer.future);
    final Future<void> innerRun =
        state.runWithLookupPopupHidden<void>(() => inner.future);
    await tester.pump();
    expect(_placeholderProgress, findsNothing);

    inner.complete();
    await innerRun;
    await tester.pump();
    expect(_placeholderProgress, findsNothing,
        reason: '外层对话框还开着，计数未归零，占位卡不得回来');

    outer.complete();
    await outerRun;
    await tester.pump();
    expect(_placeholderProgress, findsOneWidget);

    state.settlePendingReveal();
    await tester.pump();
  });
}
