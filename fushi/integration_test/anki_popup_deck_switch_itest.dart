// BUG-3682 / BUG-3683 原始路径（Android 模拟器 / 真机 + AnkiDroid，手动跑，配合宿主脚本）：
//
// 主进程（本测试）里：拉 AnkiDroid 配置 → 选非 Lapis 笔记类型「Basic」（看默认映射是否非空，
// BUG-3682）→ 选牌组 FushiA → 打 `[anki-popup] READY1` 后等宿主放行。宿主脚本在 `:popup`
// 进程（PROCESS_TEXT 应用外查词）里经「制卡目标」切到 FushiB 并制一张卡，然后放行；本测试
// 读设置看主进程是否看到 FushiB（跨进程），再在主进程把牌组改成 FushiC，打 READY2；宿主在
// 仍然活着的 popup 进程里再制一张卡（应进 FushiC），放行后本测试结束。卡落在哪个牌组由宿主
// 拉 AnkiDroid 库核对。
//
// 放行文件：`<应用文档目录>/anki_popup_go<N>`（宿主 `run-as <pkg> touch app_flutter/...`）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/popup_main.dart' as popup_entrypoint;
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 应用外查词窗口（`:popup` 进程）的 Dart 入口：原生侧按名字在**根库**里找它，测试 APK 的
/// 根库是本文件（不是 lib/main.dart），所以这里照 main.dart 同样转发一次。
@pragma('vm:entry-point')
void popupMain() => popup_entrypoint.popupMain();

void _log(String line) => debugPrint('[anki-popup] $line');

Future<void> _waitGo(WidgetTester tester, int n) async {
  final Directory docs = await getApplicationDocumentsDirectory();
  final File go = File('${docs.path}/anki_popup_go$n');
  _log('READY$n docs=${docs.path}');
  final Stopwatch sw = Stopwatch()..start();
  while (!go.existsSync()) {
    if (sw.elapsed > const Duration(minutes: 8)) fail('宿主 8 分钟内没放行 go$n');
    await tester.pump(const Duration(milliseconds: 250));
  }
  _log('GO$n after ${sw.elapsed.inSeconds}s');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('应用外查词切牌组 + 主进程改牌组后应用外用新牌组', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel appModel = await readyAppModel(tester);
    expect(await seedDictionary(tester), isTrue, reason: '测试词典应已导入');
    final ProviderContainer container = ProviderScope.containerOf(
      appModel.navigatorKey.currentContext!,
    );
    final AnkiViewModel vm = container.read(ankiViewModelProvider.notifier);

    // 宿主装完包后才授 AnkiDroid API 权限：轮询直到拉取成功。
    final Stopwatch sw = Stopwatch()..start();
    while (true) {
      await vm.fetchConfiguration();
      final AnkiUiState s = container.read(ankiViewModelProvider);
      if (s.settings.availableDecks.isNotEmpty) break;
      if (sw.elapsed > const Duration(minutes: 3)) {
        fail('3 分钟内没拉到 AnkiDroid 配置：${s.errorMessage}');
      }
      await tester.pump(const Duration(seconds: 2));
    }
    AnkiSettings settings = container.read(ankiViewModelProvider).settings;
    _log(
      'decks=${settings.availableDecks.map((AnkiDeck d) => d.name).toList()} '
      'noteTypes=${settings.availableNoteTypes.map((AnkiNoteType t) => '${t.name}${t.fields}').toList()}',
    );

    // BUG-3682：选非 Lapis 笔记类型，映射不应为空。
    final AnkiNoteType basic = settings.availableNoteTypes.firstWhere(
      (AnkiNoteType t) => t.name == 'Basic',
    );
    await vm.selectNoteType(basic);
    settings = container.read(ankiViewModelProvider).settings;
    _log('BUG-3682 Basic mappings=${settings.fieldMappings}');
    expect(
      settings.fieldMappings.values.where((String v) => v.trim().isNotEmpty),
      isNotEmpty,
      reason: 'BUG-3682：选 Basic 后默认映射不应为空',
    );

    AnkiDeck deck(String name) =>
        settings.availableDecks.firstWhere((AnkiDeck d) => d.name == name);
    await vm.selectDeck(deck('FushiA'));
    _log(
      'main selected=${container.read(ankiViewModelProvider).settings.selectedDeckName}',
    );

    await _waitGo(tester, 1);
    // 宿主已在 popup 进程切到 FushiB 并制卡：主进程直读存储（不靠本进程视图模型的缓存）。
    final AnkiSettings afterPopup = await AnkiRepository().loadSettings();
    _log(
      'BUG-3683 main sees after popup switch: deck=${afterPopup.selectedDeckName} '
      '(${afterPopup.selectedDeckId})',
    );

    await vm.selectDeck(deck('FushiC'));
    final AnkiSettings afterMain = await AnkiRepository().loadSettings();
    _log('main switched to deck=${afterMain.selectedDeckName}');
    await _waitGo(tester, 2);
    _log('DONE');
    expect(afterPopup.selectedDeckName, 'FushiB', reason: '主进程应看到 popup 里切的牌组');
  });
}
