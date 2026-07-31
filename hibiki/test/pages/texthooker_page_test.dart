import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/pages/implementations/texthooker_page.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_platform_services.dart';

/// 健康卡 Anki 行接真实配置状态（BUG-1007）后，页面 watch AnkiViewModel →
/// ankiRepositoryProvider → platformServicesProvider，测试需注入 fake 平台服务。
Widget _wrapPage(Widget home) {
  return ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(testPlatformServices()),
    ],
    child: MaterialApp(home: home),
  );
}

void main() {
  setUp(() {
    // AnkiViewModel.loadSettings 走 SharedPreferences——测试环境需 mock 初始值。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TexthookerService.instance.clear();
  });
  tearDown(() => TexthookerService.instance.clear());

  testWidgets('renders incoming lines reactively', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrapPage(const TexthookerPage()),
    );
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

  testWidgets('clear button empties the list', (WidgetTester tester) async {
    TexthookerService.instance.appendLine('行X');
    await tester.pumpWidget(
      _wrapPage(const TexthookerPage()),
    );
    await tester.pump();
    expect(find.textContaining('行'), findsWidgets);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(find.textContaining('行'), findsNothing);
  });

  testWidgets('Luna-style text thread selector filters mixed hook output',
      (WidgetTester tester) async {
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
    TexthookerService.instance.applyTextThreadPreviews(
      const <TexthookerThreadPreview>[
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
      ],
    );
    await tester.pumpWidget(
      _wrapPage(const TexthookerPage()),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
      findsOneWidget,
    );
    // v12 契约（BUG-1193）：带线程身份的行在用户显式选中之前一行都不发布。
    // 两条行仍在诊断 buffer 里（它们正是选择器的原材料），但工作台此刻
    // 必须是空的。旧断言在这里期望「干净台词」已经可见，那是 v12 之前
    // 「不选 = 全部线程」的旧语义。
    expect(
      TexthookerService.instance.lines,
      contains('坏线程文本'),
    );
    expect(
      TexthookerService.instance.lines,
      contains('干净台词'),
    );
    expect(find.textContaining('干'), findsNothing,
        reason: 'v12：未显式选线程时带线程身份的行一行也不得发布');
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
    await tester.tap(
      cleanThreadItem,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('干'), findsWidgets);
    expect(find.textContaining('坏'), findsNothing);
  });

  testWidgets('BUG-1309：无线程身份的行不受线程选择门控，未选线程也必须发布',
      (WidgetTester tester) async {
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
    await tester.pumpWidget(
      _wrapPage(const TexthookerPage()),
    );
    await tester.pump();

    expect(find.textContaining('ソ'), findsWidgets,
        reason: '无线程身份的行不归属任何候选线程，必须无条件进入工作台');
    expect(find.textContaining('詞'), findsNothing,
        reason: 'v12：带线程身份的行未被显式选中就不发布（BUG-1193 契约不得松动）');
  });

  testWidgets('thread selector lists discovered TextRender before any output',
      (WidgetTester tester) async {
    TexthookerService.instance.registerTextThread(
      key: 'luna:textrender',
      label: 'TextRender · 0xf94600',
      hookCode: 'HS932@f94600',
      nativeThreadId: 0x9,
    );
    await tester.pumpWidget(
      _wrapPage(const TexthookerPage()),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('TextRender · 0xf94600 · 0'), findsWidgets);
  });

  testWidgets('inactive workbench keeps audio tracks out of overflow menu',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrapPage(const TexthookerPage()),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('game-toolbar-more')));
    await tester.pumpAndSettle();
    expect(find.text('Health status'), findsOneWidget);
    expect(find.text('Manage audio tracks'), findsNothing,
        reason: 'PR #455 将会话音轨改为仅在活动会话显示的工具栏直达入口');
    expect(find.byKey(const ValueKey<String>('game-toolbar-tracks')),
        findsNothing);
    // 降级策略入口取代了旧的 bool 开关项，菜单项上直接显示当前档位（默认 full）。
    expect(find.text('Audio fallback · Allow mixed audio'), findsOneWidget,
        reason: '三档策略入口必须显示当前档位，否则用户不知道自己在哪一档');
    expect(find.text('Allow audio fallback'), findsNothing,
        reason: '旧的 bool「允许音频降级」开关已被三档策略取代');
    // BUG-1191：超分改成**每游戏一档**后，入口挪到了游戏库卡片的右键菜单
    // （`games_library_page.dart` 的 `_menuItems`）——这里不该再有它。工作台是
    // 「当前会话」的界面，而档位是「这个游戏」的属性，放这儿只会诱使人以为改的是
    // 全局值。守卫用 `textContaining`：档位后缀（「· 关闭」）变了也照样红。
    expect(find.textContaining('Game window upscaling'), findsNothing,
        reason: '超分档位是每游戏属性，入口在游戏库卡片菜单，不在捕获工作台');
  });

  testWidgets('embedded mode reuses parent scaffold and exposes back action',
      (WidgetTester tester) async {
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

    expect(find.byType(Scaffold), findsOneWidget,
        reason: '嵌入工作台不得再创建第二层 Scaffold');
    expect(find.byType(AppBar), findsNothing);
    expect(find.textContaining('嵌'), findsWidgets);

    await tester.tap(find.byIcon(Icons.arrow_back));
    expect(returned, isTrue);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(find.textContaining('嵌'), findsNothing);
  });

  for (final Size size in <Size>[
    const Size(520, 760),
    const Size(1000, 760),
    const Size(1440, 850),
  ]) {
    testWidgets('capture console lays out at ${size.width.toInt()}px',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TexthookerService.instance.appendLine('レスポンシブ確認');
      await tester.pumpWidget(
        _wrapPage(const TexthookerPage()),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Live lines'), findsOneWidget);
      // 右栏常驻面板已从「最新台词 + 健康状态」两张只读卡换成逐句音轨面板
      // （排除 BGM 要按本句时刻判断，见 _LineTracksCard）；健康状态移入工具栏
      // 「更多」菜单的对话框，不再常驻。
      expect(find.text('Health status'), findsNothing);
      if (size.width >= 840) {
        expect(find.text('Tracks for this line'), findsOneWidget);
        expect(find.byType(ExpansionTile), findsNothing);
      } else {
        // 窄屏不丢弃面板：折叠为可展开区（默认收起，仅标题可见）。
        expect(find.byType(ExpansionTile), findsOneWidget);
        expect(find.text('Tracks for this line'), findsOneWidget);
      }
    });
  }

  testWidgets('选中线程被行上限淘汰后重建下拉不触发断言（BUG-952）', (WidgetTester tester) async {
    // 把 session 选到一个 service 里并不存在的线程 key —— 等价于该线程被 500 行上限
    // 淘汰/清空后 value 落在 items 之外。修复前 DropdownButton 会断言红屏。
    await GalHookSessionController.instance
        .selectTextThread(0x1, threadKey: 'luna:evicted');
    addTearDown(
      () => GalHookSessionController.instance
          .selectTextThread(null, threadKey: null),
    );
    TexthookerService.instance.appendLine(
      '别的线程行',
      textThreadKey: 'luna:other',
      textThreadLabel: 'Other 0x2',
      textHookCode: 'HS932@2',
    );
    await tester.pumpWidget(
      _wrapPage(const TexthookerPage()),
    );
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: '选中线程被淘汰后 value 应回退占位「全部」，不得触发 DropdownButton 断言');
    expect(
      find.byKey(const ValueKey<String>('game-text-thread-selector')),
      findsOneWidget,
    );
  });

  testWidgets('保活 tab 被 TickerMode 隐藏时查词浮层置 inert，恢复可见时复原（BUG-953）',
      (WidgetTester tester) async {
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
    expect(inert(), isTrue,
        reason: 'tab 隐藏时必须把 root Overlay 里的查词浮层收起，防跨 tab 残留遮挡');

    visible.value = true;
    await tester.pump();
    expect(inert(), isFalse, reason: '重新可见时恢复浮层');
  });

  group('injectActiveSentence（BUG-954：fallback 制卡带上活跃台词）', () {
    test('fields 无 sentence + 有活跃台词 → 注入活跃台词，其它字段不变', () {
      final Map<String, String> r = injectActiveSentence(
        <String, String>{'expression': '語'},
        'これは台詞です。',
      );
      expect(r['sentence'], 'これは台詞です。');
      expect(r['expression'], '語');
    });

    test('fields 已有非空 sentence → 不覆盖调用方句子', () {
      final Map<String, String> r = injectActiveSentence(
        <String, String>{'sentence': '既存の文'},
        '活跃台詞',
      );
      expect(r['sentence'], '既存の文');
    });

    test('无活跃台词 / 空串 → 原样返回', () {
      expect(injectActiveSentence(<String, String>{'a': 'b'}, null),
          <String, String>{'a': 'b'});
      expect(injectActiveSentence(<String, String>{'a': 'b'}, ''),
          <String, String>{'a': 'b'});
    });
  });
}
