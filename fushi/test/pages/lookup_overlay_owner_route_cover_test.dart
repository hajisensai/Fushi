import 'dart:async';
import 'dart:io';

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

/// BUG-3685（反馈 5yWS2o6U6q）：视频页查词浮层压在之后推入的整页之上。
///
/// 视频页把整棵查词浮层子树（整屏 dismiss barrier + 弹窗层）手动插在**根 Overlay**
/// （为了盖过 media_kit 全屏路由）。`Navigator` 每次 push 都经 `Overlay.rearrange`
/// 把非路由 entry 排回最顶，于是查词时从悬浮球打开反馈中心：
/// ① 反馈页被浮层压住（用户：「会把反馈压住」）；
/// ② 在反馈页上点任何地方都先落到 barrier，被判成「点浮层外面」→ 关栈 → 关栈汇聚点
///    恢复播放（用户：「进入反馈的时候查词取消了，导致视频继续播放了」）。
///
/// 修复：宿主声明浮层跟随的路由（[DictionaryPageMixin.lookupOwnerRoute]），它不是栈顶
/// 时与「对话框期间」同一道门让位——弹窗停靠屏外、barrier 不挂，会话原样保留；宿主路由
/// 里的 [LookupOwnerRouteProbe] 负责在栈顶状态变化时刷新浮层 entry。
///
/// 本文件用与宿主页同构的最小 harness（不拉起真视频页 / media_kit），第一条钉死旧行为
/// （不跟随路由时页面确实点不动、点击被 barrier 吃掉），第二条钉死修复后的行为；最后一组
/// 源码守卫钉视频页的三处接线（这些在 widget 层跑不到：需要真 media_kit 播放器）。
class _CoverTestAppModel extends AppModel {
  _CoverTestAppModel() : super(testPlatformServices());

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
  }) async {
    return DictionarySearchResult(
      searchTerm: searchTerm,
      entries: <DictionaryEntry>[
        DictionaryEntry(word: '語', reading: 'ご', meaning: 'word'),
      ],
    );
  }
}

const Key _kBarrierKey = ValueKey<String>('cover_test_barrier');

/// 与视频页同构：浮层子树手动插在根 Overlay，barrier 门控走
/// [shouldShowLookupDismissBarrier]，弹窗层走 [buildNestedPopupLayer]。
class _CoverHostPage extends ConsumerStatefulWidget {
  const _CoverHostPage({required this.followRoute, super.key});

  /// false = 修复前的宿主（不声明 [lookupOwnerRoute]）。
  final bool followRoute;

  @override
  ConsumerState<_CoverHostPage> createState() => _CoverHostPageState();
}

class _CoverHostPageState extends ConsumerState<_CoverHostPage>
    with DictionaryPageMixin {
  final DictionaryPopupController controller = DictionaryPopupController(
    lowMemory: false,
  );
  OverlayEntry? _entry;
  int barrierTaps = 0;

  @override
  AppModel get mixinAppModel => ref.read(appProvider);

  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  ModalRoute<Object?>? get lookupOwnerRoute =>
      widget.followRoute && mounted ? ModalRoute.of(context) : null;

  Future<void> lookup(String term) async {
    await pushNestedPopup(
      query: term,
      selectionRect: const Rect.fromLTWH(20, 20, 4, 4),
      controller: controller,
      replaceStack: true,
      autoRead: false,
    );
    setState(() {
      for (final DictionaryPopupEntry entry in controller.entries) {
        controller.revealRendered(entry);
      }
      controller.endSearchUi();
    });
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    final OverlayEntry? existing = _entry;
    if (existing != null) {
      existing.markNeedsBuild();
      return;
    }
    final OverlayEntry entry = OverlayEntry(builder: _buildOverlay);
    _entry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry?.dispose();
    super.dispose();
  }

  Widget _buildOverlay(BuildContext _) {
    if (!mounted) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size screen = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            if (shouldShowLookupDismissBarrier(
              hasVisiblePopup: controller.hasVisiblePopup,
              isSearching: controller.isSearchingUi,
              hiddenByDialog: lookupPopupHiddenByDialog,
            ))
              Positioned.fill(
                child: GestureDetector(
                  key: _kBarrierKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: () => barrierTaps++,
                ),
              ),
            for (int i = 0; i < controller.entries.length; i++)
              buildNestedPopupLayer(
                index: i,
                screen: screen,
                controller: controller,
                onPush: (String text, Rect rect, List<FushiRubySpan> _) async =>
                    0,
                onPop: (int index) {},
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return LookupOwnerRouteProbe(
      onChanged: () =>
          WidgetsBinding.instance.addPostFrameCallback((_) => _sync()),
      child: const SizedBox.expand(),
    );
  }
}

class _FeedbackLikePage extends StatelessWidget {
  const _FeedbackLikePage({required this.onSend});

  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(onPressed: onSend, child: const Text('send')),
      ),
    );
  }
}

Future<_CoverHostPageState> _pumpHost(
  WidgetTester tester, {
  required bool followRoute,
}) async {
  final GlobalKey<_CoverHostPageState> key = GlobalKey<_CoverHostPageState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => _CoverTestAppModel()),
        ...popupMiningTargetTestOverrides(),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: _CoverHostPage(key: key, followRoute: followRoute),
          ),
        ),
      ),
    ),
  );
  final _CoverHostPageState state = key.currentState!;
  await state.lookup('語');
  await tester.pump();
  expect(state.controller.hasVisiblePopup, isTrue);
  expect(find.byKey(_kBarrierKey), findsOneWidget);
  return state;
}

/// 弹窗层是否停在屏外（[parkedPopupLayer] 的让位几何：left = screen.width + 8）。
bool _popupParked(WidgetTester tester) {
  final Finder layer = find.byType(DictionaryPopupLayer, skipOffstage: false);
  expect(layer, findsOneWidget);
  return tester.getTopLeft(layer).dx >=
      tester.view.physicalSize.width / tester.view.devicePixelRatio;
}

Future<void> _pushFeedbackLikePage(
  WidgetTester tester,
  _CoverHostPageState state,
  VoidCallback onSend,
) async {
  unawaited(
    Navigator.of(state.context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _FeedbackLikePage(onSend: onSend),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(installFakeInAppWebViewPlatform);

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('不跟随路由（修复前）：后推的整页被浮层压住，点击被 barrier 吃掉（复现）', (
    WidgetTester tester,
  ) async {
    final _CoverHostPageState state = await _pumpHost(
      tester,
      followRoute: false,
    );
    int sends = 0;
    await _pushFeedbackLikePage(tester, state, () => sends++);

    expect(
      find.byKey(_kBarrierKey),
      findsOneWidget,
      reason: 'Overlay.rearrange 把手动 insert 的 entry 排回最顶',
    );
    expect(_popupParked(tester), isFalse, reason: '弹窗仍画在新页面之上');
    await tester.tap(find.text('send'), warnIfMissed: false);
    await tester.pump();
    expect(sends, 0);
    expect(state.barrierTaps, 1, reason: '点到的是浮层 barrier（宿主据此关栈并续播）');
  });

  testWidgets('跟随路由：被整页盖住时浮层让位、会话保留，回到宿主即复原', (WidgetTester tester) async {
    final _CoverHostPageState state = await _pumpHost(
      tester,
      followRoute: true,
    );
    expect(_popupParked(tester), isFalse);
    int sends = 0;
    await _pushFeedbackLikePage(tester, state, () => sends++);

    expect(state.lookupOwnerRouteCovered, isTrue);
    expect(find.byKey(_kBarrierKey), findsNothing);
    expect(_popupParked(tester), isTrue, reason: '弹窗停到屏外，不再压住新页面');
    await tester.tap(find.text('send'));
    await tester.pump();
    expect(sends, 1, reason: '新页面的点击落到它自己身上');
    expect(state.barrierTaps, 0);
    expect(
      state.controller.hasVisiblePopup,
      isTrue,
      reason: '让位不是关栈：查词会话（及宿主的「因查词暂停」）原样保留',
    );

    Navigator.of(state.context).pop();
    await tester.pumpAndSettle();
    expect(state.lookupOwnerRouteCovered, isFalse);
    expect(find.byKey(_kBarrierKey), findsOneWidget);
    expect(_popupParked(tester), isFalse, reason: '回到宿主页，浮层复原');
  });

  group('视频页接线（BUG-3685 源码守卫）', () {
    String read(String path) => File(path).readAsStringSync();
    const String page = 'lib/src/pages/implementations/video_fushi_page.dart';
    const String dir = 'lib/src/pages/implementations/video_fushi';

    test('浮层跟随的路由：窗口 = 本页路由，全屏 = 全屏路由', () {
      final String src = read(page);
      final int at = src.indexOf('get lookupOwnerRoute');
      expect(at, greaterThan(0));
      final String body = src.substring(at, src.indexOf('}', at));
      expect(body, contains('_videoFullscreenActive'));
      expect(body, contains('_videoFullscreenRoute'));
      expect(body, contains('ModalRoute.of(context)'));
    });

    test('窗口与全屏两条路由里都挂了栈顶探针', () {
      expect(read('$dir/layout.part.dart'), contains('LookupOwnerRouteProbe('));
      expect(
        read('$dir/fullscreen.part.dart'),
        contains('LookupOwnerRouteProbe('),
      );
    });

    test('被盖住时不起新查词（_lookupAt 入口门控）', () {
      final String src = read('$dir/lookup_favorite.part.dart');
      final int at = src.indexOf('Future<void> _lookupAt(');
      final int gate = src.indexOf('if (lookupOwnerRouteCovered) return;', at);
      final int pause = src.indexOf('controller.pause()', at);
      final int push = src.indexOf('pushNestedPopup(', at);
      expect(gate, greaterThan(at));
      expect(gate, lessThan(pause), reason: '门控必须在暂停之前');
      expect(gate, lessThan(push), reason: '门控必须在推浮层之前');
    });
  });

  // 首页词典页与 texthooker 的浮层同样手动插在根 Overlay 上，同一机制接上：覆写
  // lookupOwnerRoute 为本页路由 + 挂栈顶探针（探针回调帧后刷新浮层 entry）。
  group('首页词典页 / texthooker 接线（BUG-3685 源码守卫）', () {
    for (final String page in <String>[
      'lib/src/pages/implementations/home_dictionary_page.dart',
      'lib/src/pages/implementations/texthooker_page.dart',
    ]) {
      test(page, () {
        final String src = File(page).readAsStringSync();
        final int at = src.indexOf('get lookupOwnerRoute');
        expect(at, greaterThan(0), reason: '必须覆写 lookupOwnerRoute');
        expect(
          src.substring(at, src.indexOf(';', at)),
          contains('ModalRoute.of(context)'),
        );
        final int build = src.indexOf('Widget build(BuildContext context) {');
        expect(build, greaterThan(0));
        expect(
          src.substring(build, src.indexOf('\n  }', build)),
          contains('LookupOwnerRouteProbe('),
          reason: '探针包住整页',
        );
        final int changed = src.indexOf('void _onLookupOwnerRouteChanged()');
        expect(changed, greaterThan(0));
        expect(
          src.substring(changed, src.indexOf('\n  }', changed)),
          contains('_syncPopupOverlay()'),
        );
      });
    }
  });
}
