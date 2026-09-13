import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
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

// BUG-2493 iOS 实测：AnkiMobile `infoForAdding` 往返在**真 iOS 进程**上跑一遍
// ——真 URL scheme 跨 app 跳转、真系统剪贴板、真 SceneDelegate → EventChannel →
// main.dart → AppDelegate 读剪贴板。对手是同目录 support/fake_ankimobile/ 里的
// 替身 app（AnkiMobile 装不进模拟器），它按第 N 次请求切换三种回跳形态：
//   r1 没写：不写剪贴板 + x-success（用户没同意）
//   r2 正常：写剪贴板 + x-success
//   r3 只回前台：写剪贴板 + 打开一条不是 ankiFetch 的 fushi:// URL（模拟 x-success 没送达）
// 「没写」排第一：模拟器上跨 app 读剪贴板会弹系统「允许粘贴」提示，没法自动点；
// r1 不碰剪贴板内容（只查类型元数据）所以不弹，先把它跑完。
// 跑法见 docs/bugs/BUG-2493-*.md（Mac 上 `flutter test -d <sim>`，先 build_install.sh）。

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  String Function()? describe,
  int polls = 240,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (condition()) return;
  }
  fail(describe == null ? reason : '$reason / 实际状态：${describe()}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS AnkiMobile infoForAdding round trip reports an empty pasteboard, '
    'lands decks via x-success, and via plain foreground return',
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'ios-ankimobile-info-return',
        body: () async {
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue, reason: 'home must render');
          await readyAppModel(tester);
          final ProviderContainer container = ProviderScope.containerOf(
            tester.element(find.byType(MaterialApp).first),
          );
          final AnkiViewModel vm =
              container.read(ankiViewModelProvider.notifier);
          AnkiUiState state() => container.read(ankiViewModelProvider);
          List<String> deckNames() =>
              state().availableDecks.map((d) => d.name).toList();
          String describeState() =>
              'errorMessage=${state().errorMessage} isFetching=${state().isFetching} '
              'decks=${deckNames()} awaiting=${AnkiMobileInfoReturnCoordinator.instance.awaitingReturn}';

          final BaseAnkiRepository providedRepo =
              container.read(ankiRepositoryProvider);
          expect(
            resolveAnkiMobileRepository(providedRepo),
            isNotNull,
            reason: 'iOS 默认后端必须解析到 AnkiMobileRepository，实际拿到 '
                '${providedRepo.runtimeType}'
                '${providedRepo is AutoRepositionAnkiRepository ? " → ${providedRepo.inner.runtimeType}" : ""}'
                '${providedRepo is RemoteMiningAnkiRepository ? " → ${providedRepo.local.runtimeType}" : ""}',
          );
          final AnkiMobileInfoReturnCoordinator coordinator =
              AnkiMobileInfoReturnCoordinator.instance;

          final String expectedOpened = AnkiViewModel.localizeAnkiFetchError(
            '',
            AnkiErrorCode.ankiMobileOpened,
          );
          final String expectedEmpty = AnkiViewModel.localizeAnkiFetchError(
            '',
            AnkiErrorCode.ankiMobilePasteboardEmpty,
          );

          // ── r1：AnkiMobile 没写（用户没同意），x-success 照常回跳 ──
          await vm.fetchConfiguration();
          expect(
            state().errorMessage,
            expectedOpened,
            reason: '打开 AnkiMobile 后先写中间态',
          );
          expect(coordinator.awaitingReturn, isTrue);
          await _pumpUntil(
            tester,
            () => state().errorMessage == expectedEmpty,
            reason: 'r1：没写剪贴板时必须报「没有回传配置」，而不是挂着中间态',
            describe: describeState,
          );
          expect(deckNames(), isEmpty);
          expect(state().isFetching, isFalse);
          expect(coordinator.awaitingReturn, isFalse);
          // BUG-2459：回跳不得再压出第二个 HomePage。
          expect(find.byType(HomePage), findsOneWidget);

          // ── r2：正常往返（写剪贴板 + x-success 送达）──
          await vm.fetchConfiguration();
          expect(state().errorMessage, expectedOpened);
          await _pumpUntil(
            tester,
            () => deckNames().contains('FakeDeck r2'),
            reason: 'r2：x-success 回跳后牌组必须落地（60 s 内）',
            describe: describeState,
          );
          expect(state().errorMessage, isNull, reason: '中间态必须被清掉');
          expect(state().isFetching, isFalse);
          expect(
            state().availableNoteTypes.map((n) => n.name),
            contains('FakeBasic r2'),
          );
          expect(
            state().selectedNoteType?.fields,
            containsAll(<String>['Front', 'Back', 'Audio']),
          );
          expect(coordinator.awaitingReturn, isFalse);
          expect(find.byType(HomePage), findsOneWidget);
          // 回到前台的兜底路径随后也会触发，但同一次往返只读一次：牌组不能被
          // 一条「AnkiMobile 没有回传配置」盖掉。
          await tester.pump(const Duration(seconds: 2));
          expect(state().errorMessage, isNull);
          expect(deckNames(), contains('FakeDeck r2'));

          // ── r3：x-success 没送达，只是回到了前台 ──
          await vm.fetchConfiguration();
          await _pumpUntil(
            tester,
            () => deckNames().contains('FakeDeck r3'),
            reason: 'r3：没有 ankiFetch 回调、仅回到前台也必须取回牌组',
            describe: describeState,
          );
          expect(state().errorMessage, isNull);
          expect(coordinator.awaitingReturn, isFalse);
          expect(find.byType(HomePage), findsOneWidget);
        },
      );
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
