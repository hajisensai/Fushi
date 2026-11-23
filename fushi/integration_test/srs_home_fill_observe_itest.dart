// 复习首页宽屏首行「今日 / 正在背 / 连续天数」三块等高时内容是否填满（手动跑）。
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_home_fill_observe_itest.dart
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('复习首页宽屏首行：今日 / 连续天数块底部贴底填满', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    await appModel.setModuleEnabled(ModuleId.srs, true);
    await tester.pump(const Duration(seconds: 1));

    final ProviderContainer container = ProviderScope.containerOf(
      appModel.navigatorKey.currentContext!,
    );
    final SrsDbStore store = (await container.read(srsStoreProvider.future))!;
    await store.ensureBuiltins();
    final String uid = store.profileUid;
    final String deck = await store.createDeck('正在背');
    final List<String> notes = <String>[];
    for (int i = 0; i < 30; i++) {
      final Map<String, String> fields = <String, String>{
        ...srsSampleCardFields(),
        'Expression': '通う$i',
      };
      notes.add(
        await store.createNote(
          noteTypeId: store.fushiCardNoteTypeId,
          deckId: deck,
          createdAt: 1700000000000 + i,
          fieldsById: <String, String>{
            for (final MapEntry<String, String> e in fields.entries)
              srsFushiCardFieldId(uid, e.key): e.value,
          },
        ),
      );
    }
    for (int i = 0; i < 12; i++) {
      final String card = (await store.cardsOfNote(notes[i])).first.id;
      await store.answer(card, 3, durationMs: 6000);
    }
    container.read(srsRevisionProvider.notifier).state++;

    HomePage.debugSelectTab?.call(HomeTab.srs);
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // 首次进复习页的「复习同步已升级」说明框：Esc 关掉，免得挡住首行。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    Rect? rectOf(String key) {
      final Finder f = find.byKey(ValueKey<String>(key));
      return f.evaluate().isEmpty ? null : tester.getRect(f.first);
    }

    debugPrint('[srs-home-fill] today=${rectOf('srs-home-today-poster')}');
    debugPrint('[srs-home-fill] recent=${rectOf('srs-home-today-recent')}');
    debugPrint('[srs-home-fill] deck=${rectOf('srs-home-deck-poster')}');
    debugPrint('[srs-home-fill] heat=${rectOf('srs-home-heatmap')}');
    debugPrint('[srs-home-fill] totals=${rectOf('srs-home-heatmap-totals')}');
    final ObserveShot shot = await captureFlutterFrame(tester, '01-srs-home');
    expect(shot.saved, isTrue);
  });
}
