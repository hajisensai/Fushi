import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/lookup/lookup_overlay_navigator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/gal_attached_lookup_workbench.dart';
import 'package:fushi/src/pages/implementations/gal_workbench_chrome.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/texthooker_page.dart';
import 'package:fushi/src/pages/implementations/shared_lookup_popup_host.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_inappwebview_platform.dart';
import '../helpers/inert_profile_repository.dart';
import '../helpers/test_platform_services.dart';

/// 健康卡 Anki 行接真实配置状态（BUG-1007）后，页面 watch AnkiViewModel →
/// ankiRepositoryProvider → platformServicesProvider，测试需注入 fake 平台服务。
///
/// 这里的用例讲的都是 Windows 的 hook 捕获工作台：hook 控件受
/// `GamesModuleForm.supportsHookCapture` 门控，不钉平台就会随宿主机变
/// （Linux CI 上隐藏、Windows 开发机上显示）。非 Windows 形态用 [_wrapPageOn]。
Widget _wrapPage(Widget home) {
  return ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(
        testPlatformServices(isWindows: true),
      ),
    ],
    child: MaterialApp(home: home),
  );
}

Widget _wrapPageOn(Widget home, {required bool isWindows}) {
  return ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(
        testPlatformServices(isWindows: isWindows, isDesktop: true),
      ),
    ],
    child: MaterialApp(home: home),
  );
}

/// 点选台词列表第一句：点卡片左上角的「时间 · 来源」元信息行（不点正文——正文逐字
/// 可点，会走查词而不是选句）。
Future<void> _selectFirstLine(WidgetTester tester) async {
  final Finder card = find.byWidgetPredicate((Widget widget) {
    final Key? key = widget.key;
    return widget is FushiCard &&
        key is ValueKey<String> &&
        RegExp(r'^game-line-\d').hasMatch(key.value);
  });
  expect(card, findsWidgets, reason: '台词列表里应至少有一句');
  await tester.tapAt(tester.getTopLeft(card.first) + const Offset(24, 20));
  await tester.pumpAndSettle();
}

/// 「新句自动查词」测试用：查词弹窗要读的显示设置给定值，查词本身只记下查询串
/// （测试环境没有词典库）。其余 getter 照旧走真 [AppModel]。
class _AutoLookupAppModel extends AppModel {
  _AutoLookupAppModel() : super(testPlatformServices(isWindows: true));

  final List<String> searches = <String>[];

  @override
  Future<DictionarySearchResult> searchDictionaryWithRuby({
    required String searchTerm,
    required List<FushiRubySpan> rubySpans,
    bool searchWithWildcards = false,
    int? overrideMaximumTerms,
  }) {
    searches.add(searchTerm);
    // 永不完成：浮层停在「查询中」，不往下渲染要连 Anki / 数据库的结果卡——本组
    // 只验证「新句到达时发起了哪次查词」。
    return Completer<DictionarySearchResult>().future;
  }

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
  double get dictionaryFontSize => 16;
  @override
  double get popupWheelSpeed => 1.0;
  @override
  bool get popupInstantScroll => false;
  @override
  double get popupInstantScrollWheelStep => 0.5;
  @override
  double get popupInstantScrollTouchStep => 0.25;
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
  @override
  bool get collapseDictionaries => false;
  @override
  List<Dictionary> get dictionaries => const <Dictionary>[];
  @override
  Map<String, String> get customDictCSS => const <String, String>{};
  @override
  String get globalDictCSS => '';
}

void main() {
  test(
    'quote-only Hook display uses only the matching active game profile',
    () {
      const String sha =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const GalLookupReferenceClientV1 client = GalLookupReferenceClientV1(
        widthPx: 1920,
        heightPx: 1080,
        dpi: 96,
      );
      final GalLookupSurfaceProfileV1 profile = GalLookupSurfaceProfileV1(
        exePath: r'C:\Games\Test\game.exe',
        exeSha256: sha,
        mode: GalLookupSurfaceMode.auto,
        unsafeLeftClickAccepted: false,
        variants: <GalLookupSurfaceVariantV1>[
          GalLookupSurfaceVariantV1(
            aspectRatio: client.aspectRatio,
            referenceClient: client,
            bodyRect: GalAttachedTextController.defaultBodyRect,
            layout: const GalLookupTextLayoutV1(quotedTextOnly: true),
            slot: GalLookupCalibrationSlotV1.dialogue,
          ),
          GalLookupSurfaceVariantV1(
            aspectRatio: client.aspectRatio,
            referenceClient: client,
            bodyRect: GalAttachedTextController.defaultBodyRect,
            layout: const GalLookupTextLayoutV1(),
            slot: GalLookupCalibrationSlotV1.narration,
          ),
        ],
      );
      const String source = '浜田「第一行。\n第二行」尾注';
      ({String text, int sourceOffset}) visible({
        bool currentSession = true,
        String sessionExecutable = r'C:\Games\Test\game.exe',
        String attachedSha256 = sha,
        GalLookupSurfaceProfileV1? selectedProfile,
        String text = source,
      }) => galLookupVisibleHookLineText(
        source: text,
        currentSession: currentSession,
        sessionExecutable: sessionExecutable,
        attachedExecutable: r'C:\Games\Test\game.exe',
        attachedSha256: attachedSha256,
        profile: selectedProfile ?? profile,
        client: client,
      );

      expect(visible(), (text: '「第一行。\n第二行」', sourceOffset: 2));
      expect(visible(text: '浜田 の説明'), (text: '浜田 の説明', sourceOffset: 0));
      expect(visible(currentSession: false).text, source);
      expect(
        visible(sessionExecutable: r'C:\Games\Other\game.exe').text,
        source,
      );
      expect(visible(attachedSha256: 'b' * 64).text, source);
      expect(
        visible(
          selectedProfile: profile.copyWith(
            variants: <GalLookupSurfaceVariantV1>[profile.variants.last],
          ),
        ).text,
        source,
      );
      expect(
        visible(
          selectedProfile: profile.copyWith(
            variants: <GalLookupSurfaceVariantV1>[profile.variants.first],
          ),
        ).text,
        '「第一行。\n第二行」',
        reason: 'A single calibrated slot is the shared fallback.',
      );
    },
  );

  setUp(() {
    // AnkiViewModel.loadSettings 走 SharedPreferences——测试环境需 mock 初始值。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TexthookerService.instance.clear();
  });
  tearDown(() => TexthookerService.instance.clear());

  group('hook controls by platform', () {
    const List<String> hookOnlyKeys = <String>[
      'game-toolbar-audio-fallback',
      'game-toolbar-health',
      'game-toolbar-hook-overlay',
      'game-toolbar-external-window',
      'game-action-launch',
      'game-action-attach',
    ];

    testWidgets('non-Windows hides hook controls but keeps lines + clear', (
      WidgetTester tester,
    ) async {
      TexthookerService.instance.appendLine('第一行');
      await tester.pumpWidget(
        _wrapPageOn(
          const Scaffold(body: TexthookerPage(embedded: true)),
          isWindows: false,
        ),
      );
      await tester.pump();
      for (final String key in hookOnlyKeys) {
        expect(find.byKey(ValueKey<String>(key)), findsNothing, reason: key);
      }
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.textContaining('第'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('non-Windows empty state uses the external texthooker copy', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrapPageOn(
          const Scaffold(body: TexthookerPage(embedded: true)),
          isWindows: false,
        ),
      );
      await tester.pump();
      expect(find.text(t.texthooker_empty_external_body), findsOneWidget);
      expect(find.text(t.game_capture_empty_body), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('game-empty-launch')),
        findsNothing,
      );
    });

    testWidgets('Windows still shows hook controls', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrapPageOn(
          const Scaffold(body: TexthookerPage(embedded: true)),
          isWindows: true,
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('game-toolbar-health')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('game-action-launch')),
        findsOneWidget,
      );
    });
  });

  testWidgets('renders incoming lines reactively', (WidgetTester tester) async {
    await tester.pumpWidget(_wrapPage(const TexthookerPage()));
    await tester.pump();

    expect(find.text('第'), findsNothing);

    TexthookerService.instance.appendLine('第一行');
    await tester.pump();
    // 分词后可能拆成多个 span，逐字降级时「第」是独立 span。
    expect(find.textContaining('第'), findsWidgets);

    TexthookerService.instance.appendLine('第二行');
    await tester.pump();
    expect(find.textContaining('二'), findsWidgets);
  });

  testWidgets('Hook HTML break displays on the next row', (
    WidgetTester tester,
  ) async {
    final TexthookerLineEntry entry = TexthookerService.instance.appendLine(
      '前<br>後',
    )!;
    expect(entry.text, '前\n後');

    await tester.pumpWidget(_wrapPage(const TexthookerPage()));
    await tester.pump();

    final Finder first = find.text('前');
    final Finder second = find.text('後');
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(
      tester.getTopLeft(second).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );
  });

  testWidgets('BUG-1597 bulk line uses a folded lightweight text widget', (
    WidgetTester tester,
  ) async {
    final String bulkText = '历史台词' * 250;
    TexthookerService.instance.appendLine(bulkText);

    await tester.pumpWidget(_wrapPage(const TexthookerPage()));
    await tester.pump();

    final String lineId = TexthookerService.instance.entries.single.id;
    final Finder textFinder = find.byKey(
      ValueKey<String>('game-line-lightweight-text-$lineId'),
    );
    expect(textFinder, findsOneWidget);
    expect(tester.widget<Text>(textFinder).maxLines, 4);
    expect(
      find.text('Bulk text detected. Character lookup is paused.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(ValueKey<String>('game-line-expand-$lineId')));
    await tester.pump();
    expect(tester.widget<Text>(textFinder).maxLines, isNull);
  });

  testWidgets('clear button empties the list', (WidgetTester tester) async {
    TexthookerService.instance.appendLine('行X');
    await tester.pumpWidget(_wrapPage(const TexthookerPage()));
    await tester.pump();
    expect(find.textContaining('行'), findsWidgets);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(find.textContaining('行'), findsNothing);
  });

  testWidgets('Luna-style text thread selector filters mixed hook output', (
    WidgetTester tester,
  ) async {
    TexthookerService.instance.appendLine(
      '坏线程文本',
      textThreadKey: 'luna:bad',
      textThreadLabel: 'Luna 0x1000',
      textHookCode: 'HS932@1000',
      nativeTextThreadId: 0x1000,
    );
    TexthookerService.instance.appendLine(
      '干净台词',
      textThreadKey: 'luna:clean',
      textThreadLabel: 'SiglusEngine 0x2000',
      textHookCode: 'HS932@2000',
      nativeTextThreadId: 0x2000,
    );
    // v12 的下拉行数来自 native 预览区，而非已发布文本环；补齐真实会话会提供的
    // 预览快照，避免用旧的 DropdownButton 隐藏测宽副本冒充可交互菜单项。
    TexthookerService.instance
        .applyTextThreadPreviews(const <TexthookerThreadPreview>[
          TexthookerThreadPreview(
            nativeThreadId: 0x1000,
            text: '坏线程文本',
            observedLineCount: 1,
            observedArtifactCount: 1,
            isArtifact: true,
          ),
          TexthookerThreadPreview(
            nativeThreadId: 0x2000,
            text: '干净台词',
            observedLineCount: 1,
            observedArtifactCount: 0,
            isArtifact: false,
          ),
        ]);
    await tester.pumpWidget(_wrapPage(const TexthookerPage()));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
      findsOneWidget,
    );
    // v12 契约（BUG-1193）：带线程身份的行在用户显式选中之前一行都不发布。
    // 两条行仍在诊断 buffer 里（它们正是选择器的原材料），但工作台此刻
    // 必须是空的。旧断言在这里期望「干净台词」已经可见，那是 v12 之前
    // 「不选 = 全部线程」的旧语义。
    expect(TexthookerService.instance.lines, contains('坏线程文本'));
    expect(TexthookerService.instance.lines, contains('干净台词'));
    expect(
      find.textContaining('干'),
      findsNothing,
      reason: 'v12：未显式选线程时带线程身份的行一行也不得发布',
    );
    expect(find.textContaining('坏'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
    );
    await tester.pumpAndSettle();
    // 点真实 MenuItemButton，避免 `.last` 落到旧 DropdownMenu 的隐藏测宽副本。
    final Finder cleanThreadItem = find.widgetWithText(
      MenuItemButton,
      'SiglusEngine 0x2000 · 1',
    );
    expect(cleanThreadItem, findsOneWidget);
    await tester.tap(cleanThreadItem);
    await tester.pumpAndSettle();

    expect(find.textContaining('干'), findsWidgets);
    expect(find.textContaining('坏'), findsNothing);
  });

  testWidgets('BUG-1315：无线程身份的行不受线程选择门控，未选线程也必须发布', (
    WidgetTester tester,
  ) async {
    // 带线程身份的行：v12 起未被显式选中就不发布。
    TexthookerService.instance.appendLine(
      'フックした台詞',
      textThreadKey: 'luna:hooked',
      textThreadLabel: 'LunaHook 0x3000',
      textHookCode: 'HS932@3000',
      nativeTextThreadId: 0x3000,
    );
    // WebSocket / Textractor 端点的行不带 textThreadKey，永远进不了线程目录，
    // 也就永远没有下拉项能选中它。拿「有没有选线程」去门控它等于永久丢弃，
    // 而且用户无法自救——下拉里只会有上面那条 hook 线程。
    TexthookerService.instance.appendLine(
      'ソケット行',
      source: TexthookerLineSource.websocket,
      sourceLabel: 'ws://127.0.0.1:6677',
    );
    await tester.pumpWidget(_wrapPage(const TexthookerPage()));
    await tester.pump();

    expect(
      find.textContaining('ソ'),
      findsWidgets,
      reason: '无线程身份的行不归属任何候选线程，必须无条件进入工作台',
    );
    expect(
      find.textContaining('詞'),
      findsNothing,
      reason: 'v12：带线程身份的行未被显式选中就不发布（BUG-1193 契约不得松动）',
    );
  });

  testWidgets('thread selector lists discovered TextRender before any output', (
    WidgetTester tester,
  ) async {
    TexthookerService.instance.registerTextThread(
      key: 'luna:textrender',
      label: 'TextRender · 0xf94600',
      hookCode: 'HS932@f94600',
      nativeThreadId: 0x9,
    );
    await tester.pumpWidget(_wrapPage(const TexthookerPage()));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('TextRender · 0xf94600 · 0'), findsWidgets);
  });

  testWidgets(
    'inactive workbench exposes low-frequency actions without a menu',
    (WidgetTester tester) async {
      // 健康 / 音频降级是 Hook 捕获会话的入口，只在 Windows 出现（非 Windows 的
      // 反向断言见上面「non-Windows hides hook controls」）；钉死平台，免得结果
      // 跟着宿主（CI 是 Linux）走。
      await tester.pumpWidget(
        _wrapPageOn(const TexthookerPage(), isWindows: true),
      );
      await tester.pump();

      // 三点「更多」菜单已删：低频入口直接摊在工具栏上，不再需要先展开菜单。
      expect(
        find.byKey(const ValueKey<String>('game-toolbar-more')),
        findsNothing,
        reason: '工具栏 overflow 菜单已删除，入口必须直接可见',
      );
      // byType 对泛型是精确匹配（PopupMenuButton<X> 不匹配 PopupMenuButton<Object?>），
      // 所以这里用「三点图标」这个用户可见特征做守卫，换个泛型参数绕不过去。
      expect(
        find.byIcon(Icons.more_vert),
        findsNothing,
        reason: '捕获工作台工具栏不得再出现任何 overflow 菜单',
      );
      expect(
        find.byKey(const ValueKey<String>('game-toolbar-health')),
        findsOneWidget,
      );
      expect(find.byTooltip('Health status'), findsOneWidget);
      expect(
        find.byTooltip('Manage audio tracks'),
        findsNothing,
        reason: 'PR #455 将会话音轨改为仅在活动会话显示的工具栏直达入口',
      );
      expect(
        find.byKey(const ValueKey<String>('game-toolbar-tracks')),
        findsNothing,
      );
      // 降级策略入口取代了旧的 bool 开关项，按钮 tooltip 直接显示当前档位（默认 full）。
      expect(
        find.byKey(const ValueKey<String>('game-toolbar-audio-fallback')),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Audio fallback · Allow mixed audio'),
        findsOneWidget,
        reason: '三档策略入口必须显示当前档位，否则用户不知道自己在哪一档',
      );
      expect(
        find.byTooltip('Allow audio fallback'),
        findsNothing,
        reason: '旧的 bool「允许音频降级」开关已被三档策略取代',
      );
      // BUG-1191：超分改成**每游戏一档**后，入口挪到了游戏库卡片的右键菜单
      // （`games/galgame_item_menu.dart` 的 `galgameItemMenuItems`）——这里不该再有它。工作台是
      // 「当前会话」的界面，而档位是「这个游戏」的属性，放这儿只会诱使人以为改的是
      // 全局值。守卫用 `textContaining`：档位后缀（「· 关闭」）变了也照样红。
      expect(
        find.textContaining('Game window upscaling'),
        findsNothing,
        reason: '超分档位是每游戏属性，入口在游戏库卡片菜单，不在捕获工作台',
      );
    },
  );

  testWidgets('embedded mode reuses parent scaffold and exposes back action', (
    WidgetTester tester,
  ) async {
    bool returned = false;
    TexthookerService.instance.appendLine('嵌入行');
    await tester.pumpWidget(
      _wrapPage(
        Scaffold(
          body: TexthookerPage(
            embedded: true,
            onShowLibrary: () => returned = true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byType(Scaffold),
      findsOneWidget,
      reason: '嵌入工作台不得再创建第二层 Scaffold',
    );
    expect(find.byType(AppBar), findsNothing);
    expect(find.textContaining('嵌'), findsWidgets);

    await tester.tap(find.byIcon(Icons.arrow_back));
    expect(returned, isTrue);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(find.textContaining('嵌'), findsNothing);
  });

  testWidgets(
    'embedded header keeps flattened actions without overflow at 520px',
    (WidgetTester tester) async {
      // 低频入口从三点菜单摊平后，嵌入模式页头动作数翻倍。页头动作区靠
      // ConstrainedBox + 横向 SingleChildScrollView 兜底，窄窗必须是「可滚动」而不是
      // RenderFlex overflow，更不能把入口整个丢掉。
      await tester.binding.setSurfaceSize(const Size(520, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _wrapPageOn(
          const Scaffold(body: TexthookerPage(embedded: true)),
          isWindows: true,
        ),
      );
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: '摊平后的页头在窄窗不得 RenderFlex overflow',
      );
      // 页头动作最多的是 Windows（Hook 捕获入口全在），所以钉死 Windows 测最挤的
      // 形态；健康 / 音频降级只在 Hook 捕获平台出现，非 Windows 的反向断言见
      // 「non-Windows hides hook controls」。
      expect(
        find.byKey(const ValueKey<String>('game-toolbar-audio-fallback')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('game-toolbar-health')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.more_vert), findsNothing);
    },
  );

  // BUG（反馈 J4GKVdgo2s）：会话卡里的工具组曾是 FushiToolbar(floating: true)——
  // 浮动顶栏 / 底栏用的带投影胶囊，硬塞进卡内的动作行，又被固定 3:2 比例切出的
  // Flexible 动作区收窄，整组悬在卡片中段、和主操作不在同一视觉层。
  //
  // 2026-11 拼贴改版（PR #3515）后结构换了：起点是状态色块里的两张大动作卡，
  // 会话工具不再与主操作挤同一行，而是带名称的分区——宽屏（≥
  // kGalWorkbenchSideColumnBreakpoint）在侧栏里色块正下方，与色块同宽贴齐。
  // 原「工具组与主操作同一行 / 动作行贴卡片右缘」的断言因此按新布局改写；本 bug
  // 钉的不变式不变：会话区里没有浮动胶囊工具栏、工具组不悬在半空、没有「⋯」。
  testWidgets(
    'session card tools sit inline with the primary action (J4GKVdgo2s)',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _wrapPageOn(
          const Scaffold(body: TexthookerPage(embedded: true)),
          isWindows: true,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final Finder card = find.byKey(
        const ValueKey<String>('game-session-overview'),
      );
      final Finder sessionArea = find.byKey(
        const ValueKey<String>('game-session-actions'),
      );
      final Finder tools = find.byKey(
        const ValueKey<String>('game-session-tools'),
      );
      expect(find.descendant(of: sessionArea, matching: card), findsOneWidget);
      expect(find.descendant(of: sessionArea, matching: tools), findsOneWidget);

      // 会话区内不得再有浮动样式的工具栏。
      expect(
        find.descendant(
          of: sessionArea,
          matching: find.byWidgetPredicate(
            (Widget w) => w is FushiToolbar && w.floating,
          ),
        ),
        findsNothing,
      );

      // 主操作在状态色块里，工具组在色块正下方的工具分区里。
      final Finder launch = find.byKey(
        const ValueKey<String>('game-action-launch'),
      );
      final Finder health = find.byKey(
        const ValueKey<String>('game-toolbar-health'),
      );
      expect(find.descendant(of: card, matching: launch), findsOneWidget);
      expect(find.descendant(of: tools, matching: health), findsOneWidget);
      expect(
        tester.getTopLeft(tools).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(card).dy),
        reason: '工具分区在状态色块下方，不浮在色块上',
      );

      // 工具全部带名称平铺，没有「⋯」。
      expect(
        find.byKey(const ValueKey<String>('game-session-tools-more')),
        findsNothing,
      );

      // 清空台词也在工具分区里；分区与色块左右贴齐，不悬在中段。
      expect(
        find.descendant(of: tools, matching: find.byIcon(Icons.delete_outline)),
        findsOneWidget,
      );
      expect(
        (tester.getTopRight(card).dx - tester.getTopRight(tools).dx).abs(),
        lessThan(20),
        reason: '工具分区应与状态色块右缘贴齐',
      );
      expect(
        (tester.getTopLeft(card).dx - tester.getTopLeft(tools).dx).abs(),
        lessThan(20),
        reason: '工具分区应与状态色块左缘贴齐',
      );
    },
  );

  // 2026-10 工作台重做：「本句音轨」不再常驻占栏——没选中台词时不出现；选中一句后
  // 宽屏（≥ kGalWorkbenchWideBreakpoint）从右侧展开详情侧板，窄屏在底部升起「本句」
  // 条，点「本句音轨」开底部 sheet（同一张音轨卡）。
  for (final Size size in <Size>[
    const Size(520, 760),
    const Size(1000, 760),
    const Size(1440, 850),
  ]) {
    testWidgets('capture console lays out at ${size.width.toInt()}px', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TexthookerService.instance.appendLine('レスポンシブ確認');
      await tester.pumpWidget(_wrapPage(const TexthookerPage()));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Live lines'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('game-session-overview')),
        findsOneWidget,
      );
      // 健康状态是工具组里的图标按钮 + 对话框，不常驻。
      expect(find.text('Health status'), findsNothing);
      // 未选中台词：没有详情侧板，也没有底部本句条。
      expect(find.text('Tracks for this line'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('game-line-detail-pane')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('game-selected-line-bar')),
        findsNothing,
      );

      await _selectFirstLine(tester);

      expect(tester.takeException(), isNull);
      final bool wide = size.width >= kGalWorkbenchWideBreakpoint;
      if (wide) {
        expect(
          find.byKey(const ValueKey<String>('game-line-detail-pane')),
          findsOneWidget,
        );
        expect(find.text('Tracks for this line'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('game-selected-line-bar')),
          findsNothing,
        );
        // 关闭：侧板收起，台词列表拿回全部宽度。
        await tester.tap(
          find.byKey(const ValueKey<String>('game-line-tracks-close')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey<String>('game-line-detail-pane')),
          findsNothing,
        );
      } else {
        expect(
          find.byKey(const ValueKey<String>('game-line-detail-pane')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('game-selected-line-bar')),
          findsOneWidget,
        );
        expect(find.text('Tracks for this line'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey<String>('game-selected-line-open-tracks')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Tracks for this line'), findsOneWidget);
        expect(find.textContaining('レスポンシブ確認'), findsWidgets);
      }
    });
  }

  // BUG-4206（反馈 3drXfc4GFk）：还在「匹配中」的行没有任何资源字节。即使它带着
  // backend=game_resource（修复前的待配对写法 / 折叠进来的旧事件），「本句音轨」面板
  // 也必须报状态「Matching」，不能报 game_resource；资源弹窗（带播放键）只给真配上
  // 原件的行。
  test('BUG-4206 only a paired game resource counts as resource audio', () {
    final TexthookerService service = TexthookerService.test();
    final TexthookerLineEntry line = service.appendLine('配対待ち')!;
    service.updateLineAudio(
      line.id,
      status: TexthookerLineAudioStatus.pending,
      backend: 'game_resource',
    );
    TexthookerLineEntry row = service.entries.single;
    expect(row.hasResourceAudio, isFalse);
    expect(texthookerLineAudioSummary(row), 'Matching');

    service.updateLineAudio(
      line.id,
      status: TexthookerLineAudioStatus.missing,
      backend: 'game_resource',
    );
    row = service.entries.single;
    expect(row.hasResourceAudio, isFalse);
    expect(texthookerLineAudioSummary(row), isNot('game_resource'));

    service.updateLineAudio(
      line.id,
      status: TexthookerLineAudioStatus.matched,
      backend: 'game_resource',
      resourceId: '50000_fushi_textseq42_sgre-voicebody-1-2-3-4.xwma',
    );
    row = service.entries.single;
    expect(row.hasResourceAudio, isTrue);
    expect(texthookerLineAudioSummary(row), 'game_resource');
  });

  testWidgets('BUG-4206 pending line panel shows Matching, not game_resource', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final TexthookerLineEntry line = TexthookerService.instance.appendLine(
      'まだ配対されていない台詞',
    )!;
    TexthookerService.instance.updateLineAudio(
      line.id,
      status: TexthookerLineAudioStatus.pending,
      backend: 'game_resource',
    );
    await tester.pumpWidget(_wrapPage(const TexthookerPage()));
    await tester.pump();
    await _selectFirstLine(tester);

    final Finder pane = find.byKey(
      const ValueKey<String>('game-line-detail-pane'),
    );
    expect(pane, findsOneWidget);
    expect(
      find.descendant(of: pane, matching: find.text('Matching')),
      findsWidgets,
    );
    expect(find.text('game_resource'), findsNothing);
    // 没有音频的行不给行内试听键。
    expect(find.byTooltip("Play this line's audio"), findsNothing);
  });

  // BUG-4206 审查：资源模式下越过配对容差仍没原件的行（多半是无配音旁白）是中性
  // 「无原件」标，不是红色「未匹配 / 无音频」故障标。
  // BUG-4206 审查：资源模式下「匹配中 / 无原件」的行点「本句音轨」不能落进 PCM 轨
  // 列表（PCM 轨与资源模式无关，选了还会把这行算成用户裁决、资源晚到不再升格），
  // 也不能给播放键；只有真配上原件的行走资源弹窗，非资源模式才列 PCM 轨。
  test('BUG-4206 line track view follows resource pairing and backend', () {
    final TexthookerService service = TexthookerService.test();
    final TexthookerLineEntry line = service.appendLine('資源モード')!;
    TexthookerLineEntry row() => service.entries.single;

    service.updateLineAudio(line.id, status: TexthookerLineAudioStatus.pending);
    expect(
      galLineTrackViewFor(row(), GalHookAudioBackend.gameResource),
      GalLineTrackView.resourceUnpaired,
    );
    expect(
      galLineTrackViewFor(row(), GalHookAudioBackend.enginePcm),
      GalLineTrackView.pcmTracks,
    );

    service.updateLineAudio(
      line.id,
      status: TexthookerLineAudioStatus.missing,
      fallbackReason: kGalResourceNotPairedReason,
    );
    expect(
      galLineTrackViewFor(row(), GalHookAudioBackend.gameResource),
      GalLineTrackView.resourceUnpaired,
    );
    // 面板 / 选中句条与行内标签同一句「无原件」，不是红色「未匹配」。
    expect(texthookerLineAudioSummary(row()), 'No original voice');

    service.updateLineAudio(
      line.id,
      status: TexthookerLineAudioStatus.matched,
      backend: 'game_resource',
      resourceId: '50000_fushi_textseq42_sgre-voicebody-1-2-3-4.xwma',
    );
    for (final GalHookAudioBackend backend in GalHookAudioBackend.values) {
      expect(
        galLineTrackViewFor(row(), backend),
        GalLineTrackView.resourceAudio,
        reason: backend.name,
      );
    }
  });

  for (final ({
        String label,
        TexthookerLineAudioStatus status,
        String? reason,
        String summary,
      })
      c
      in <
        ({
          String label,
          TexthookerLineAudioStatus status,
          String? reason,
          String summary,
        })
      >[
        (
          label: 'pending',
          status: TexthookerLineAudioStatus.pending,
          reason: null,
          summary: 'Matching',
        ),
        (
          label: 'not paired',
          status: TexthookerLineAudioStatus.missing,
          reason: kGalResourceNotPairedReason,
          summary: 'No original voice',
        ),
      ]) {
    testWidgets(
      'BUG-4206 unpaired resource-mode line track dialog (${c.label}) has no '
      'play key and no PCM tracks',
      (WidgetTester tester) async {
        final TexthookerService service = TexthookerService.test();
        final TexthookerLineEntry line = service.appendLine('配音待ち')!;
        service.updateLineAudio(
          line.id,
          status: c.status,
          fallbackReason: c.reason,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GalResourceUnpairedLineTrackDialog(
                line: service.entries.single,
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text(t.game_line_track_dialog_title), findsOneWidget);
        expect(find.text(t.game_tracks_resource_mode_hint), findsOneWidget);
        expect(find.text(c.summary), findsOneWidget);
        expect(
          find.text(t.game_line_audio_not_paired_hint),
          c.reason == null ? findsNothing : findsOneWidget,
        );
        expect(find.byIcon(Icons.play_circle_outline), findsNothing);
        expect(find.byIcon(Icons.graphic_eq), findsNothing);
        expect(find.byType(FushiIconButton), findsNothing);
      },
    );
  }

  testWidgets('BUG-4206 resource-not-paired line shows a neutral tag', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final TexthookerLineEntry line = TexthookerService.instance.appendLine(
      '配音のない地の文',
    )!;
    TexthookerService.instance.updateLineAudio(
      line.id,
      status: TexthookerLineAudioStatus.missing,
      fallbackReason: kGalResourceNotPairedReason,
    );
    await tester.pumpWidget(_wrapPage(const TexthookerPage()));
    await tester.pump();

    final Finder chip = find.text('No original voice');
    expect(chip, findsWidgets);
    expect(find.text('No audio'), findsNothing);
    final FushiTag tag = tester.widget<FushiTag>(
      find.ancestor(of: chip.first, matching: find.byType(FushiTag)).first,
    );
    expect(tag.tone, FushiTagTone.neutral);
  });

  testWidgets('empty workbench offers the next step instead of a dead end', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 起点动作卡只在嵌入模式（游戏 › 工作台，唯一的生产入口：HomeGamePage /
    // GameStreamClientPage）的会话状态块里；独立模式的起点在 AppBar 图标里。
    await tester.pumpWidget(
      _wrapPage(const Scaffold(body: TexthookerPage(embedded: true))),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('game-lines-empty')),
      findsOneWidget,
    );
    expect(find.text('Tracks for this line'), findsNothing);
    if (Platform.isWindows) {
      // 未开始捕获：下一步「启动并捕获 / 附着并捕获」必须同屏可点。2026-11 拼贴
      // 改版（PR #3515）把两个起点做成会话状态色块里的大动作卡，空态只留一句指引、
      // 不再重复一套同样的按钮（同屏两套会让人困惑），所以这里改钉状态块里的
      // 起点，并反向钉住空态里不再有重复按钮。
      final Finder card = find.byKey(
        const ValueKey<String>('game-session-overview'),
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey<String>('game-action-launch')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey<String>('game-action-attach')),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('game-empty-launch')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('game-empty-attach')),
        findsNothing,
      );
    }
  });

  test('attached lookup status enum is always localized', () {
    // 此前 `status.name` 原样上屏，界面出现「状态: disabled」。
    final Set<String> labels = <String>{};
    for (final GalAttachedTextStatus status in GalAttachedTextStatus.values) {
      final String label = galAttachedTextStatusLabel(status);
      expect(label.trim(), isNotEmpty, reason: '$status 缺本地化文案');
      expect(label, isNot(status.name), reason: '$status 仍把枚举名原样上屏');
      labels.add(label);
      galAttachedTextStatusTone(status);
      galAttachedTextStatusIcon(status);
    }
    expect(
      labels.length,
      GalAttachedTextStatus.values.length,
      reason: '每个状态的文案应互不相同',
    );
    expect(
      galAttachedTextStatusLabel(GalAttachedTextStatus.disabled),
      t.game_lookup_attached_status_disabled,
    );
  });

  testWidgets('选中线程被行上限淘汰后重建下拉不触发断言（BUG-952）', (WidgetTester tester) async {
    // 把 session 选到一个 service 里并不存在的线程 key —— 等价于该线程被 500 行上限
    // 淘汰/清空后 value 落在 items 之外。修复前 DropdownButton 会断言红屏。
    await GalHookSessionController.instance.selectTextThread(
      0x1,
      threadKey: 'luna:evicted',
    );
    addTearDown(
      () => GalHookSessionController.instance.selectTextThread(
        null,
        threadKey: null,
      ),
    );
    TexthookerService.instance.appendLine(
      '别的线程行',
      textThreadKey: 'luna:other',
      textThreadLabel: 'Other 0x2',
      textHookCode: 'HS932@2',
    );
    await tester.pumpWidget(_wrapPage(const TexthookerPage()));
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason: '选中线程被淘汰后 value 应回退占位「全部」，不得触发 DropdownButton 断言',
    );
    expect(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
      findsOneWidget,
    );
  });

  testWidgets('首页外壳里与查词 tab 共用查词宿主，外壳外私有一个（design-shared-lookup-webview）', (
    WidgetTester tester,
  ) async {
    final SharedLookupPopupHost shared = SharedLookupPopupHost();
    addTearDown(shared.dispose);
    final ValueNotifier<bool> show = ValueNotifier<bool>(true);
    addTearDown(show.dispose);
    await tester.pumpWidget(
      _wrapPage(
        SharedLookupPopupScope(
          host: shared,
          child: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: show,
              builder: (BuildContext context, bool v, _) =>
                  v ? const TexthookerPage() : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final dynamic state = tester.state(find.byType(TexthookerPage));
    expect(
      identical(state.debugPopupHost, shared),
      isTrue,
      reason: '外壳下发的宿主必须被采用，否则两个 tab 各挂一个热槽 WebView',
    );
    expect(shared.debugOwnerCount, 1);
    expect(shared.isRenderOwner(state as SharedLookupPopupOwner), isTrue);

    // 页面销毁只注销，不得把外壳持有的宿主（controller）一并释放。
    show.value = false;
    await tester.pump();
    await tester.pump();
    expect(shared.debugOwnerCount, 0);
    expect(() => shared.controller.hasVisiblePopup, returnsNormally);

    // 外壳外：私有一个。
    show.value = true;
    await tester.pumpWidget(_wrapPage(const Scaffold(body: TexthookerPage())));
    await tester.pump();
    final dynamic standalone = tester.state(find.byType(TexthookerPage));
    expect(identical(standalone.debugPopupHost, shared), isFalse);
  });

  group('反馈 q9Jcu_Zr2_：新句自动查词', () {
    late _AutoLookupAppModel app;

    // 查词浮层会真的建出来：WebView 走假平台，制卡目标菜单读的配置仓库给惰性实现。
    setUpAll(installFakeInAppWebViewPlatform);

    Future<SharedLookupPopupHost> pumpWithSharedHost(
      WidgetTester tester,
    ) async {
      app = _AutoLookupAppModel();
      final SharedLookupPopupHost shared = SharedLookupPopupHost();
      addTearDown(shared.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            platformServicesProvider.overrideWithValue(
              testPlatformServices(isWindows: true),
            ),
            appProvider.overrideWith((ref) => app),
            profileRepositoryProvider.overrideWith(
              (ref) => InertProfileRepository(),
            ),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              home: SharedLookupPopupScope(
                host: shared,
                child: const Scaffold(body: TexthookerPage()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return shared;
    }

    /// 实际发起过的查词：查询串进了查词数据源，且对应的顶层浮层登记在共用宿主上。
    Iterable<String> lookedUp(SharedLookupPopupHost shared) =>
        app.searches.where(
          (String term) => shared.controller.entries.any(
            (DictionaryPopupEntry e) => e.searchTerm == term,
          ),
        );

    Future<void> pumpFrames(WidgetTester tester) async {
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('默认关：新句到达只显示，不弹查词', (WidgetTester tester) async {
      final SharedLookupPopupHost shared = await pumpWithSharedHost(tester);
      final FushiSelectableChip chip = tester.widget<FushiSelectableChip>(
        find.byKey(const ValueKey<String>('game-auto-lookup')),
      );
      expect(chip.selected, isFalse, reason: '自动弹窗挡画面，默认必须关');

      TexthookerService.instance.appendLine('「今日は晴れ」');
      await pumpFrames(tester);
      expect(lookedUp(shared), isEmpty);
    });

    testWidgets('打开后新句到达自动从第一个可查字起查词', (WidgetTester tester) async {
      final SharedLookupPopupHost shared = await pumpWithSharedHost(tester);
      await tester.tap(find.byKey(const ValueKey<String>('game-auto-lookup')));
      await tester.pump();

      TexthookerService.instance.appendLine('「今日は晴れ」');
      await pumpFrames(tester);
      expect(
        lookedUp(shared),
        contains('今日は晴れ」'),
        reason: '跳过开引号，从「今」起把到行尾的一段交给最长匹配，与手点「今」同一查询串',
      );
      final String lineId = TexthookerService.instance.entries.last.id;
      final FushiCard card = tester.widget<FushiCard>(
        find.byKey(ValueKey<String>('game-line-$lineId')),
      );
      expect(card.selected, isTrue, reason: '自动查词与手点一样选中该句，制卡取这句');

      // 每来一句都跟着查最新那句。
      TexthookerService.instance.appendLine('明日は雨');
      await pumpFrames(tester);
      expect(lookedUp(shared), contains('明日は雨'));
    });

    testWidgets('关掉跟随实时（在回看历史）时不自动查词', (WidgetTester tester) async {
      final SharedLookupPopupHost shared = await pumpWithSharedHost(tester);
      await tester.tap(find.byKey(const ValueKey<String>('game-auto-lookup')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('game-follow-live')));
      await tester.pump();

      TexthookerService.instance.appendLine('「今日は晴れ」');
      await pumpFrames(tester);
      expect(lookedUp(shared), isEmpty);
    });

    testWidgets('整句没有可查字时不弹卡', (WidgetTester tester) async {
      final SharedLookupPopupHost shared = await pumpWithSharedHost(tester);
      await tester.tap(find.byKey(const ValueKey<String>('game-auto-lookup')));
      await tester.pump();

      TexthookerService.instance.appendLine('「……」');
      await pumpFrames(tester);
      expect(lookedUp(shared), isEmpty);
    });

    testWidgets('上一句还没弹出就来了不可查的新句：旧目标作废，不弹旧句', (WidgetTester tester) async {
      final SharedLookupPopupHost shared = await pumpWithSharedHost(tester);
      await tester.tap(find.byKey(const ValueKey<String>('game-auto-lookup')));
      await tester.pump();

      // 同一帧内连到两句：前一句可查、后一句整句没有可查字。只查最新那句 = 都不弹。
      TexthookerService.instance.appendLine('今日は晴れ');
      TexthookerService.instance.appendLine('「……」');
      await pumpFrames(tester);
      expect(lookedUp(shared), isEmpty);
    });
  });

  testWidgets('制卡热键只作用于本页在屏上的会话：tab 藏起或栈归查词 tab 时不武装', (
    WidgetTester tester,
  ) async {
    final SharedLookupPopupHost shared = SharedLookupPopupHost();
    addTearDown(shared.dispose);
    final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      _wrapPage(
        SharedLookupPopupScope(
          host: shared,
          child: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (BuildContext context, bool v, _) =>
                  TickerMode(enabled: v, child: const TexthookerPage()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    bool armed() =>
        (tester.state(find.byType(TexthookerPage)) as dynamic)
                .debugPopupMineHotkeyArmed
            as bool;
    void openSession() => shared.controller.beginTop(
      term: '食べる',
      rect: const Rect.fromLTWH(10, 10, 20, 20),
      reuseWarmSlot: false,
      replaceStack: false,
      visible: true,
    );

    // 真实弹窗层要完整初始化的 AppModel 才能建，这里只验热键门：每次开会话、读门、
    // 清栈都在两帧之间做完，不让带着 texthooker 弹窗层的浮层真的建出来。
    void expectArmed(bool expected, String reason) {
      openSession();
      expect(armed(), expected, reason: reason);
      shared.controller.clear();
    }

    expectArmed(true, '本页可见、栈归本页、有可见弹窗');

    // 切到别的 tab：弹窗随 tab 藏起（Offstage），Ctrl+Enter 不能对看不见的弹窗制卡。
    visible.value = false;
    await tester.pump();
    expectArmed(false, 'tab 藏起时热键不得作用于看不见的弹窗');

    visible.value = true;
    await tester.pump();
    expectArmed(true, '切回可见后恢复');

    // 查词 tab 真正查词接管了栈：那是别人的会话，本页的热键不能碰（浮层此时由替身
    // 出空层，可以照常走帧）。
    final _OtherLookupOwner dict = _OtherLookupOwner();
    shared.attach(dict);
    shared.setOwnerVisible(dict, true);
    shared.claimForLookup(dict);
    openSession();
    await tester.pump();
    expect(shared.overlayInert, isFalse);
    expect(shared.controller.hasVisiblePopup, isTrue);
    expect(armed(), isFalse, reason: '栈归查词 tab 时 texthooker 的热键不得武装');
    shared.detach(dict);
    await tester.pump();
  });

  testWidgets('保活 tab 被 TickerMode 隐藏时查词浮层置 inert，恢复可见时复原（BUG-953）', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      _wrapPage(
        Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (BuildContext context, bool v, _) =>
                TickerMode(enabled: v, child: const TexthookerPage()),
          ),
        ),
      ),
    );
    await tester.pump();

    bool inert() =>
        (tester.state(find.byType(TexthookerPage)) as dynamic).debugOverlayInert
            as bool;

    expect(inert(), isFalse, reason: '可见时查词浮层不应 inert');

    visible.value =
        false; // 等价于切到别的 home tab（games 被 Offstage 隐藏 + TickerMode off）
    await tester.pump();
    expect(
      inert(),
      isTrue,
      reason: 'tab 隐藏时必须把 root Overlay 里的查词浮层收起，防跨 tab 残留遮挡',
    );

    visible.value = true;
    await tester.pump();
    expect(inert(), isFalse, reason: '重新可见时恢复浮层');
  });

  testWidgets('mounted lookup overlay survives TickerMode dependency rebuild', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      _wrapPage(
        Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (BuildContext context, bool v, _) =>
                TickerMode(enabled: v, child: const TexthookerPage()),
          ),
        ),
      ),
    );
    await tester.pump();

    final dynamic state = tester.state(find.byType(TexthookerPage));
    state.debugMountPopupOverlayForTesting();
    await tester.pump();

    visible.value = false;
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason:
          'TickerMode changes during build must not synchronously dirty '
          'the root OverlayEntry and corrupt the layout queue',
    );
  });

  testWidgets('tab 藏起时查词浮层留在树上只是 Offstage，切回是同一棵子树（BUG-4896）', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
    addTearDown(visible.dispose);
    await tester.pumpWidget(
      _wrapPage(
        Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (BuildContext context, bool v, _) =>
                TickerMode(enabled: v, child: const TexthookerPage()),
          ),
        ),
      ),
    );
    await tester.pump();

    final dynamic state = tester.state(find.byType(TexthookerPage));
    state.debugMountPopupOverlayForTesting();
    await tester.pump();

    // 浮层子树的根（真实运行时常驻热槽的查词 WebView 就挂在它下面）。
    final Finder onstage = find.byType(LookupOverlayNavigator);
    final Finder mounted = find.byType(
      LookupOverlayNavigator,
      skipOffstage: false,
    );
    expect(onstage, findsOneWidget, reason: '前置：可见时浮层在屏上');
    final State<StatefulWidget> before = tester.state(mounted);

    // 等价于切到别的 home tab（games 被 Offstage 隐藏 + TickerMode off）。
    visible.value = false;
    await tester.pump();
    await tester.pump();
    expect(onstage, findsNothing, reason: 'tab 藏起时浮层不得留在屏上遮挡新 tab（BUG-953）');
    expect(
      mounted,
      findsOneWidget,
      reason:
          '藏起只能 Offstage、不能把子树拆掉：拆掉 = 每次切出游戏 tab 销毁预热好的'
          '查词 WebView，切回再冷建一个',
    );
    expect(
      identical(tester.state(mounted), before),
      isTrue,
      reason: '藏起期间必须是同一个 State',
    );

    visible.value = true;
    await tester.pump();
    await tester.pump();
    expect(onstage, findsOneWidget, reason: '切回后浮层回到屏上');
    expect(
      identical(tester.state(mounted), before),
      isTrue,
      reason: '切回必须复用同一棵子树，而不是重建',
    );
  });

  group('injectActiveSentence（BUG-954：fallback 制卡带上活跃台词）', () {
    test('fields 无 sentence + 有活跃台词 → 注入活跃台词，其它字段不变', () {
      final Map<String, String> r = injectActiveSentence(<String, String>{
        'expression': '語',
      }, 'これは台詞です。');
      expect(r['sentence'], 'これは台詞です。');
      expect(r['expression'], '語');
    });

    test('fields 已有非空 sentence → 不覆盖调用方句子', () {
      final Map<String, String> r = injectActiveSentence(<String, String>{
        'sentence': '既存の文',
      }, '活跃台詞');
      expect(r['sentence'], '既存の文');
    });

    test('无活跃台词 / 空串 → 原样返回', () {
      expect(
        injectActiveSentence(<String, String>{'a': 'b'}, null),
        <String, String>{'a': 'b'},
      );
      expect(
        injectActiveSentence(<String, String>{'a': 'b'}, ''),
        <String, String>{'a': 'b'},
      );
    });
  });
}

/// 共用查词宿主里的「另一个宿主页」（查词 tab）替身：只出空层。
class _OtherLookupOwner implements SharedLookupPopupOwner {
  @override
  List<Widget> buildSharedLookupPopupLayers(
    BuildContext context,
    Size screen,
  ) => const <Widget>[];

  @override
  ThemeData? get sharedLookupPopupTheme => null;

  @override
  bool get sharedLookupPopupOwnerAlive => true;

  @override
  void onSharedLookupPopupClaimed(DictionaryPopupController controller) {}
}
