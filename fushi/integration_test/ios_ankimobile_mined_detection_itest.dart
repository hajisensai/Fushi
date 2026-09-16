import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankimobile_mined_ledger.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi/src/anki/auto_reposition_anki_repository.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/pages/implementations/home_page.dart' show HomePage;
import 'package:fushi_anki/fushi_anki.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart' show readyAppModel;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

// BUG-2532 iOS 实测：「已制卡」✓ 在**真 iOS 进程**上从无到有跑一遍——真
// `anki://x-callback-url/addnote` 跨 app 跳转、真回跳、真 SceneDelegate →
// EventChannel → main.dart → 账本 → `isDuplicate`。
//
// 对手仍是 support/fake_ankimobile/ 里的替身（真 AnkiMobile 是付费 App Store app，
// 装不进模拟器），本轮它多受理两条路径，与手册逐字对齐：
//   /addnote → 收下卡，**然后**才开 x-success（手册：after the note is added）
//   /search  → 记下 query 并把 Fushi 拉回前台（手册里 search 没有 x-success）
//
// 这里刻意**不**走 infoForAdding 取配置：那条要跨 app 读剪贴板、会弹系统「允许粘贴」，
// 与本 bug 无关却会把失败原因搅浑。牌组/笔记类型直接写进设置，测的是制卡回跳这一段。
// 跑法见 docs/bugs/BUG-2532-*.md（Mac 上 run_sim_itest.sh，需要 alert tapper 放行
// 「"Fushi" 想要打开 "FakeAnki"」）。

const String _minedWord = '見物';
const String _minedReading = 'けんぶつ';
const String _neverMinedWord = '未制卡';

Future<void> _pumpUntil(
  WidgetTester tester,
  Future<bool> Function() condition, {
  required String reason,
  Future<String> Function()? describe,
  int polls = 240,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (await condition()) return;
  }
  fail(describe == null ? reason : '$reason / 实际状态：${await describe()}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS AnkiMobile addnote round trip lands the mined word in the ledger, '
    'so isDuplicate flips to true and ↗ opens the search endpoint',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'ios-ankimobile-mined-detection',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue, reason: 'home must render');
          await readyAppModel(tester);
          final ProviderContainer container = ProviderScope.containerOf(
            tester.element(find.byType(MaterialApp).first),
          );

          // 走 provider 给出的那个仓库（生产链路：恒带自动重排包装层，开了「制卡到
          // 已配对设备」还会再包一层），而不是剥开后的裸仓库——BUG-2493 的教训就是
          // 包装层会把整条链默默切断。
          final BaseAnkiRepository repo = container.read(ankiRepositoryProvider);
          expect(
            resolveAnkiMobileRepository(repo),
            isNotNull,
            reason:
                'iOS 默认后端必须解析到 AnkiMobileRepository，实际拿到 '
                '${repo.runtimeType}'
                '${repo is AutoRepositionAnkiRepository ? " → ${repo.inner.runtimeType}" : ""}'
                '${repo is RemoteMiningAnkiRepository ? " → ${repo.local.runtimeType}" : ""}',
          );

          // 牌组 / 笔记类型 / 字段映射直接写进设置（见文件头：本轮不走 infoForAdding）。
          await repo.saveSettings(
            const AnkiSettings(
              selectedDeckId: 1,
              selectedDeckName: 'FakeDeck',
              selectedNoteTypeId: 1,
              selectedNoteTypeName: 'FakeBasic',
              availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'FakeDeck')],
              availableNoteTypes: <AnkiNoteType>[
                AnkiNoteType(
                  id: 1,
                  name: 'FakeBasic',
                  fields: <String>['Front', 'Back'],
                ),
              ],
              fieldMappings: <String, String>{
                'Front': '{expression}',
                'Back': '{glossary}',
              },
              tagIncludeHibiki: false,
              tagIncludeCategory: false,
            ),
          );

          // ── 改前的状态：iOS 上恒 false，✓ 永远画不出来 ──
          expect(
            await repo.isDuplicate(_minedWord, _minedReading),
            isFalse,
            reason: '还没制过卡，账本必须是空的',
          );
          expect(
            await repo.openWordInAnki(_minedWord, _minedReading),
            AnkiOpenWordOutcome.noMatch,
            reason: '账本不认得就不该去开 AnkiMobile',
          );

          // ── 真制卡：addnote 跨 app → 替身收下 → x-success 回跳 → 落账 ──
          final MineOutcome outcome = await repo.mineEntry(
            rawPayloadJson: jsonEncode(<String, String>{
              'expression': _minedWord,
              'reading': _minedReading,
              'glossary': 'sightseeing',
              'sentence': '休みに $_minedWord に行く。',
            }),
            context: const AnkiMiningContext(
              sentence: '',
              source: AnkiMiningSource.book,
            ),
          );
          expect(
            outcome.result,
            MineResult.success,
            reason:
                'addnote URL 必须真的打开'
                '（实际 ${outcome.result} / ${outcome.errorDetail}）',
          );

          await _pumpUntil(
            tester,
            () => repo.isDuplicate(_minedWord, _minedReading),
            reason:
                'x-success 回跳后「已制卡」必须转真（60 s 内）——这正是此前被 '
                'main.dart 一句 `return true;` 丢掉的那条回调',
          );
          // BUG-2459：回跳不得再压出第二个 HomePage。
          expect(find.byType(HomePage), findsOneWidget);

          // 落账要穿到持久层，不是只活在这次会话的内存里。
          expect(
            await AnkiMobileMinedLedger().contains(_minedWord),
            isTrue,
            reason: '新实例（≈下次启动）必须仍认得这个词',
          );

          // reading 不参与匹配，与 AnkiConnect 的 isDuplicate 同口径。
          expect(await repo.isDuplicate(_minedWord, ''), isTrue);
          expect(await repo.isDuplicate(_minedWord, 'べつのよみ'), isTrue);

          // 没制过的词不能被连坐。
          expect(await repo.isDuplicate(_neverMinedWord, ''), isFalse);
          expect(
            await repo.openWordInAnki(_neverMinedWord, ''),
            AnkiOpenWordOutcome.noMatch,
          );

          // ── ↗「在 Anki 中打开」：popup 只在 ✓ 亮着时显示它，必须真能开 ──
          expect(
            await repo.openWordInAnki(_minedWord, _minedReading),
            AnkiOpenWordOutcome.opened,
            reason: 'search 端点必须真的把 AnkiMobile 拉起来',
          );
          await _pumpUntil(
            tester,
            () async => find.byType(HomePage).evaluate().length == 1,
            reason: '替身把 Fushi 拉回前台后仍应只有一个 HomePage',
          );
        },
      );
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
