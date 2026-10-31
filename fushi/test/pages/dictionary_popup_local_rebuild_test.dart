import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/popup_mining_target_overrides.dart';
import '../helpers/test_platform_services.dart';

/// P1-A / P1-D（2026-10-20，用户：查词卡手）：mixin 家族（视频页 / 首页词典 /
/// texthooker …）的查词弹窗层直接订阅 controller（[DictionaryPopupEntryBinding]）。
///
/// 旧链路：结果到达 → **宿主整页** setState → 宿主 build 尾部 post-frame 回调
/// markNeedsBuild 根 Overlay → 下一帧才推结果；自适应高度每次渲染信号也整页 setState
/// 两次。这里钉住：结果回填、挂起翻出、自适应高度都**不重建宿主**，弹窗层当帧拿到新
/// 状态；以及热槽复用下慢回来的旧查词结果不覆盖新词（代次门）。
class _SpeedAppModel extends AppModel {
  _SpeedAppModel() : super(testPlatformServices());

  /// 每个查询词一个 completer：测试控制返回顺序（模拟远程查词真异步）。
  final Map<String, Completer<DictionarySearchResult>> pending =
      <String, Completer<DictionarySearchResult>>{};

  @override
  int get maximumTerms => 10;

  @override
  double get popupMaxWidth => 360;

  @override
  double get dictionaryFontSize => 16;

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
  }) {
    return pending
        .putIfAbsent(searchTerm, Completer<DictionarySearchResult>.new)
        .future;
  }

  void complete(String term) {
    pending[term]!.complete(
      DictionarySearchResult(
        searchTerm: term,
        entries: <DictionaryEntry>[
          DictionaryEntry(word: term, reading: term, meaning: 'def of $term'),
        ],
      ),
    );
  }
}

class _HostPage extends ConsumerStatefulWidget {
  const _HostPage({super.key});

  @override
  ConsumerState<_HostPage> createState() => _HostPageState();
}

class _HostPageState extends ConsumerState<_HostPage> with DictionaryPageMixin {
  final DictionaryPopupController controller = DictionaryPopupController(
    lowMemory: false,
  );

  /// 宿主 build 次数：结果回填 / 翻出 / 自适应高度都不应让它增长。
  int builds = 0;

  @override
  AppModel get mixinAppModel => ref.read(appProvider);

  @override
  ThemeData get mixinTheme => Theme.of(context);

  void seedWarmSlot() => setState(() => controller.seedWarmSlot());

  Future<void> lookup(String term) => pushNestedPopup(
    query: term,
    selectionRect: const Rect.fromLTWH(20, 20, 4, 4),
    controller: controller,
    replaceStack: true,
    reuseWarmSlot: true,
  );

  @override
  Widget build(BuildContext context) {
    builds++;
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
                onPush: (String text, Rect rect, List<FushiRubySpan> _) async => 0,
                onPop: (int index) {},
              ),
          ],
        );
      },
    );
  }
}

Widget _wrap(AppModel appModel, GlobalKey<_HostPageState> key) {
  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      ...popupMiningTargetTestOverrides(),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: Scaffold(body: _HostPage(key: key)),
      ),
    ),
  );
}

DictionaryPopupLayer _layer(WidgetTester tester) =>
    tester.widget<DictionaryPopupLayer>(find.byType(DictionaryPopupLayer));

Positioned _layerBox(WidgetTester tester) => tester.widget<Positioned>(
  find
      .descendant(
        of: find.byType(DictionaryPopupEntryBinding),
        matching: find.byType(Positioned),
      )
      .first,
);

void main() {
  setUpAll(installFakeInAppWebViewPlatform);
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets(
    'P1-A: result fill + reveal rebuild only the popup layer, not the host',
    (WidgetTester tester) async {
      final _SpeedAppModel model = _SpeedAppModel();
      final GlobalKey<_HostPageState> key = GlobalKey<_HostPageState>();
      await tester.pumpWidget(_wrap(model, key));
      final _HostPageState state = key.currentState!;
      state.seedWarmSlot();
      await tester.pump();

      unawaited(state.lookup('語'));
      await tester.pump(); // beginTop：栈 / 占位态变了，宿主重建这一次省不掉
      final DictionaryPopupEntry entry = state.controller.entries.single;
      final int buildsAfterBegin = state.builds;

      model.complete('語');
      await tester.pump();

      expect(
        state.builds,
        buildsAfterBegin,
        reason: '结果回填只 notify controller，宿主（视频页等）不再整页重建',
      );
      expect(entry.result?.searchTerm, '語');
      expect(
        _layer(tester).result,
        same(entry.result),
        reason: '弹窗层当帧就拿到新结果，不等宿主下一帧的 post-frame markNeedsBuild',
      );
      expect(entry.revealOnRender, isTrue);
      expect(_layer(tester).isSearching, isFalse);

      // 渲染信号翻出：本层立即可见（宿主为撤占位卡仍重建一次，那是 Overlay 里的占位卡）。
      expect(state.controller.revealRendered(entry), isTrue);
      await tester.pump();
      expect(entry.visible, isTrue);
      final Positioned box = _layerBox(tester);
      expect(box.left, lessThan(800), reason: '翻可见后不再停在屏外');
    },
  );

  testWidgets('P1-D: content metrics resize the shell without a host rebuild', (
    WidgetTester tester,
  ) async {
    final _SpeedAppModel model = _SpeedAppModel();
    final GlobalKey<_HostPageState> key = GlobalKey<_HostPageState>();
    await tester.pumpWidget(_wrap(model, key));
    final _HostPageState state = key.currentState!;
    state.seedWarmSlot();
    await tester.pump();

    unawaited(state.lookup('語'));
    await tester.pump();
    model.complete('語');
    await tester.pump();
    final DictionaryPopupEntry entry = state.controller.entries.single;
    final int builds = state.builds;
    expect(_layerBox(tester).height, 360, reason: '未测量前按最大高度布局');

    // WebView 上报：内容 200、视口 360 → 外壳收到 200。
    _layer(tester).onContentMetrics!(200, 360);
    await tester.pump();

    expect(entry.autoFitHeight, 200);
    expect(_layerBox(tester).height, 200, reason: '本层就地按新高度重排');
    expect(state.builds, builds, reason: '自适应高度不再整页 setState');

    // 同一高度再报一次：controller 不 notify，什么都不重建。
    int notified = 0;
    void listener() => notified++;
    state.controller.addListener(listener);
    _layer(tester).onContentMetrics!(200, 360);
    state.controller.removeListener(listener);
    expect(notified, 0);
    await tester.pump(
      DictionaryPopupController.kRevealFailsafeTimeout +
          const Duration(milliseconds: 50),
    );
  });

  testWidgets('stale warm-slot lookup never overwrites the newer word '
      '(same entry reused, slow result arrives last)', (
    WidgetTester tester,
  ) async {
    final _SpeedAppModel model = _SpeedAppModel();
    final GlobalKey<_HostPageState> key = GlobalKey<_HostPageState>();
    await tester.pumpWidget(_wrap(model, key));
    final _HostPageState state = key.currentState!;
    state.seedWarmSlot();
    await tester.pump();

    unawaited(state.lookup('旧'));
    await tester.pump();
    unawaited(state.lookup('新'));
    await tester.pump();
    final DictionaryPopupEntry entry = state.controller.entries.single;
    expect(entry.isWarmSlot, isTrue, reason: '两次查词复用同一个热槽 entry');

    model.complete('新');
    await tester.pump();
    expect(entry.result?.searchTerm, '新');

    // 远程查词真异步：旧词的结果后到。entries.contains(entry) 仍为真（同一个 entry），
    // 只有代次门能拦住它。
    model.complete('旧');
    await tester.pump();
    expect(entry.searchTerm, '新');
    expect(entry.result?.searchTerm, '新', reason: '慢回来的旧结果不得覆盖新词');
    expect(entry.revealOnRender, isTrue, reason: '旧查询的收尾也不得改写新查询的挂起态');
    // 让挂起兜底窗口过去（新查询的 failsafe Timer），不留残留 Timer。
    await tester.pump(
      DictionaryPopupController.kRevealFailsafeTimeout +
          const Duration(milliseconds: 50),
    );
  });
}
