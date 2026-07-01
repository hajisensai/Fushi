import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/anki/anki_mined_card_action_sheet.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart' show t;

import 'package:hibiki_anki/hibiki_anki.dart';

import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

/// 设备验收 itest（TODO-1007 / TODO-1008）。
///
/// 验证「点查词弹窗内已制卡 ✓ 弹操作选择单（覆写 / 新增重复卡 / 查看·在 Anki 打开）
/// + note viewer」这条 WebView→Flutter 桥行为的**宿主端 UI**在真引擎里真弹出、三项
/// 可达、且「查看」真打开只读 note viewer。
///
/// 桥的完整链路是：popup.js 点 ✓（mined 态）→ callHandler('minedCardAction') →
/// dictionary_popup_webview handler → onMinedCardAction / onMinedCardActionFromPopup
/// → runAnkiMinedCardAction → repo.findMatchingNotes 命中 → showAnkiMinedCardActionSheet。
/// 离屏 Windows 无实时 Anki 后端，findMatchingNotes 走真桥会返回空（→ 直接按新卡制、
/// 不弹单），无法端到端触发单子。故这里用与生产**同一** showAnkiMinedCardActionSheet /
/// runAnkiMinedCardAction 入口，喂一个合成命中卡 + stub repo（只覆写 note viewer 需要
/// 的 noteFields/openNoteInAnki），在真运行的 app 里 pump 出宿主 UI，断言：
///   1. 操作单弹出，含「覆写」「查看」「新增重复卡」三项可达（真 widget 树）。
///   2. 焦点驱动到「查看」并 Enter/Activate → 真打开只读 note viewer（_AnkiNoteViewerDialog）。
/// 这是 ✓ 点击最终落地的宿主行为级证据（不是源码 grep）。端到端「popup.js ✓ 经真桥
/// 弹单」需真 Anki 后端有同词卡，属可见窗 + 装 Anki 的目视，标 PARTIAL。
///
/// Run (PowerShell, from hibiki/)：
///   flutter test integration_test/anki_mined_card_action_sheet_verify_itest.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-1007: mined-card action sheet surfaces overwrite/add/view + note viewer',
    timeout: const Timeout(Duration(minutes: 6)),
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[verify] FlutterError: ${details.exceptionAsString()}');
      };

      try {
        app.main();
        expect(await waitForHome(tester), isTrue, reason: 'Home must render');
        await tester.pump(const Duration(seconds: 2));

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(appModel.isInitialised, isTrue);

        final _StubAnkiRepo repo = _StubAnkiRepo();
        // 合成两张命中卡（命中多张 → 每张列出 + 底部「新增重复卡」）。
        final List<MinedNoteRef> matches = <MinedNoteRef>[
          const MinedNoteRef(noteId: 1700000000001, preview: '猫 — ねこ (card A)'),
          const MinedNoteRef(noteId: 1700000000002, preview: '猫 — ねこ (card B)'),
        ];

        final BuildContext ctx =
            tester.element(find.byType(MaterialApp).first);

        // 与生产同一入口：直接调 showAnkiMinedCardActionSheet（runAnkiMinedCardAction
        // 命中后调的正是它）。mineNew / overwrite 用可观测的假 mutation。
        bool mineNewCalled = false;
        int? overwrittenNoteId;
        final Future<AnkiMinedCardActionResult> future =
            showAnkiMinedCardActionSheet(
          context: ctx,
          matches: matches,
          repo: repo,
          mineNew: () async {
            mineNewCalled = true;
            return (ankiConnect: false, noteId: null);
          },
          overwrite: (int noteId) async {
            overwrittenNoteId = noteId;
            return (ankiConnect: true, noteId: noteId);
          },
        );
        // 让 bottom sheet 弹出并布局。
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 150));
          if (find.text(t.anki_mined_action_add_duplicate).evaluate().isNotEmpty) {
            break;
          }
        }

        // ── 断言 1：操作单三项可达 ──
        // 标题（卡已在 Anki）。
        expect(find.text(t.anki_mined_card_title), findsOneWidget,
            reason: 'TODO-1007: action sheet title must show');
        // 「新增重复卡」ListTile（底部恒有）。
        final Finder addDup = find.text(t.anki_mined_action_add_duplicate);
        expect(addDup, findsOneWidget,
            reason: 'TODO-1007: "add duplicate" option must be present');
        // 「覆写」IconButton（每张命中卡一枚，edit_outlined）。
        final Finder overwriteBtns = find.byIcon(Icons.edit_outlined);
        expect(overwriteBtns, findsWidgets,
            reason: 'TODO-1007: per-card "overwrite" action must be present');
        // 「查看·在 Anki 打开」IconButton（open_in_new）。
        final Finder viewBtns = find.byIcon(Icons.open_in_new);
        expect(viewBtns, findsWidgets,
            reason: 'TODO-1007: per-card "view/open in Anki" action must be '
                'present');
        // 命中多张 → 副标题用 multiple-matches。
        expect(find.text(t.anki_mined_multiple_matches(count: matches.length)),
            findsOneWidget,
            reason: 'TODO-1007: multiple matches must be listed');
        debugPrint('[verify][1007] action sheet: title+addDup+overwrite('
            '${overwriteBtns.evaluate().length})+view('
            '${viewBtns.evaluate().length}) all present');

        // ── 断言 2：焦点驱动到「查看」→ Activate → 打开只读 note viewer ──
        final FocusDriver driver = FocusDriver(tester);
        // 焦点落到第一枚 open_in_new 按钮所在的 IconButton 子树。
        final Finder firstView = viewBtns.first;
        final bool focusedView = await driver.focusWidget(firstView) ||
            await driver.requestFocusInside(firstView);
        expect(focusedView, isTrue,
            reason: 'TODO-1007: "view" action must be focus-reachable (no tap)');
        // Enter 确认（App 中和裸空格，确认统一 Enter）。若物理键无效回退 Activate 意图。
        await driver.activate();
        await tester.pump(const Duration(milliseconds: 300));
        if (find.text(t.anki_note_viewer_title).evaluate().isEmpty) {
          await driver.activateIntent();
          await tester.pump(const Duration(milliseconds: 300));
        }
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 150));
          if (find.text(t.anki_note_viewer_title).evaluate().isNotEmpty) break;
        }
        expect(find.text(t.anki_note_viewer_title), findsOneWidget,
            reason: 'TODO-1007: activating "view" must open the read-only '
                'note viewer dialog');
        expect(repo.noteFieldsCalled, isTrue,
            reason: 'TODO-1007: note viewer must load existing fields via '
                'repo.noteFields');
        // note viewer 展示了 stub 返回的字段值。
        expect(find.textContaining('stub-front'), findsWidgets,
            reason: 'TODO-1007: note viewer must render existing field values');
        // 「在 Anki 打开」入口可见。
        expect(find.text(t.anki_note_viewer_open_in_anki), findsOneWidget,
            reason: 'TODO-1007: note viewer must offer "open in Anki"');
        debugPrint('[verify][1007] note viewer opened; noteFieldsCalled='
            '${repo.noteFieldsCalled} mineNewCalled=$mineNewCalled '
            'overwrittenNoteId=$overwrittenNoteId');

        // 收口：关掉 note viewer + 操作单（避免悬挂 future 卡 test）。
        final NavigatorState nav =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        nav.pop(); // note viewer
        await tester.pump(const Duration(milliseconds: 300));
        if (find.text(t.anki_mined_action_add_duplicate).evaluate().isNotEmpty) {
          nav.pop(); // action sheet
          await tester.pump(const Duration(milliseconds: 300));
        }
        await future.timeout(const Duration(seconds: 5),
            onTimeout: () => const AnkiMinedCardActionResult.unchanged());

        assertStrictErrors(errors);
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}

/// 最小 stub Anki repo：只为 note viewer 提供 noteFields / openNoteInAnki，
/// 其余抽象方法给编译能过的降级实现（本 itest 不触发它们）。
class _StubAnkiRepo extends BaseAnkiRepository {
  bool noteFieldsCalled = false;
  bool openCalled = false;

  @override
  Future<Map<String, String>?> noteFields(int noteId) async {
    noteFieldsCalled = true;
    return <String, String>{
      'Front': 'stub-front-$noteId',
      'Back': 'stub-back',
    };
  }

  @override
  Future<bool> openNoteInAnki(int noteId) async {
    openCalled = true;
    return true;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('stub');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('stub');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => true;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}
