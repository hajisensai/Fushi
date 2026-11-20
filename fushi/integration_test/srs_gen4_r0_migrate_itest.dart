// R0（SRS 协议 4 换代，规划 §6）Windows 实测的「新版本迁移」一步（Windows 离屏 runner，手动跑）：
// 把已发布旧版本（v3.3.0 等）自己建好、制过卡、复习过的数据根播种进隔离根，启动新版本，在复习页上
// 看到迁移提示，用焦点驱动（Tab 找到「开始升级」→ Enter）开始迁移，抓提示 / 进度 / 结论三帧真像素。
// 可选在迁移途中硬结束进程（模拟崩溃 / 断电，R0 矩阵 (c)）。前后库文件的比对、旧版本再打开都在
// tool/srs_old_binary/r0_win.py 里做，本文件只负责「新版本经界面迁移」这一步。
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_gen4_r0_migrate_itest.dart `
//     -DartDefine @('FUSHI_R0_SEED=D:/fushi-r0/A/old-root/app-support')
//   # 途中硬结束：再加 'FUSHI_R0_KILL_AFTER_MS=40'（按下开始后多少毫秒）或 'FUSHI_R0_KILL_AT=translate'（轮询到该步）
//   # 迁移页没出来时改走 controller.start（按钮背后的同一个入口，结论里注明）：再加 'FUSHI_R0_FALLBACK_START=true'
//
// 已知：在本 itest 的 binding 下，未迁移的库让复习页一直转圈（srsStorageProvider / srsStoreProvider 已是 AsyncError，
// 它们的 `.future` 却不完成，错误日志里有 UncaughtZone 的 SrsStoreNotMigrated）。判别步骤见下面「假设」一段：在帧回调
// 里走一次「重试」同一条作废，看迁移页出不出来。见 docs/specs/2026-11-15-srs-gen4-r0-windows.md §4.1。
//
// 种子目录：旧版本数据根的 app-support/（fushi.db、srs.db 连 -wal / -shm、srs_media/ 等），原样拷进隔离根，
// 不改种子。
import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_generation_view.dart';
import 'package:fushi/src/srs/srs_gen4_migration_controller.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _seed = String.fromEnvironment('FUSHI_R0_SEED');
const String _killAt = String.fromEnvironment('FUSHI_R0_KILL_AT');
const bool _fallbackStart = bool.fromEnvironment('FUSHI_R0_FALLBACK_START');
const int _killAfterMs = int.fromEnvironment(
  'FUSHI_R0_KILL_AFTER_MS',
  defaultValue: -1,
);

void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity e in from.listSync(recursive: true)) {
    final String rel = p.relative(e.path, from: from.path);
    if (e is Directory) {
      Directory(p.join(to.path, rel)).createSync(recursive: true);
    } else if (e is File) {
      e.copySync(p.join(to.path, rel));
    }
  }
}

/// 探针行同时写进隔离根里的文件：进程被硬结束时 stdout 会丢。
void _log(String line) {
  debugPrint(line);
  final Directory? docs = fushiTestDirectory('app-documents');
  if (docs == null) return;
  File(
    p.join(docs.path, 'srs_r0_probe.txt'),
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

/// 当前屏上可见的文字（证据：迁移提示 / 结论的原文）。
String _visibleText() {
  final List<String> out = <String>[];
  for (final Element e in find.byType(Text).evaluate()) {
    final Text t = e.widget as Text;
    final String? s = t.data ?? t.textSpan?.toPlainText();
    if (s != null && s.trim().isNotEmpty) out.add(s.trim());
  }
  return out.join(' | ');
}

/// 键盘焦点落在 [target] 上或它的子树里（同 FocusDriver 的判据：scope 与 skipTraversal 的整页键事件 sink 不算）。
bool _focusInside(Finder target) {
  final FocusNode? f = FocusManager.instance.primaryFocus;
  if (f == null || f is FocusScopeNode || f.skipTraversal) return false;
  final BuildContext? ctx = f.context;
  final List<Element> els = target.evaluate().toList();
  if (ctx == null || els.isEmpty) return false;
  if (ctx == els.first) return true;
  bool inside = false;
  ctx.visitAncestorElements((Element el) {
    if (el == els.first) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('R0：旧版本数据根经界面迁移到协议 4', (WidgetTester tester) async {
    expect(
      _seed,
      isNotEmpty,
      reason: '要 --dart-define=FUSHI_R0_SEED=<旧数据根的 app-support>',
    );
    final Directory support = fushiTestDirectory('app-support')!;
    _copyTree(Directory(_seed), support);
    _log(
      '[r0] seeded ${support.path}: '
      '${support.listSync().map((FileSystemEntity e) => p.basename(e.path)).join(',')}',
    );

    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel appModel = await readyAppModel(tester);
    HomePage.debugSelectTab?.call(HomeTab.srs);
    final Finder start = find.byKey(SrsGenerationView.startKey);
    // 复习页先转圈开库、开库报「要迁移」后才换成迁移页；本机负载高时 debug 构建要几十秒。每 15 秒记一次屏上文字。
    final Stopwatch wait = Stopwatch()..start();
    while (start.evaluate().isEmpty &&
        wait.elapsed < const Duration(seconds: 90)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (wait.elapsedMilliseconds % 15000 < 260) {
        _log('[r0] waiting ${wait.elapsed.inSeconds}s: ${_visibleText()}');
        final ProviderContainer c = ProviderScope.containerOf(
          appModel.navigatorKey.currentContext!,
        );
        _log(
          '[r0]   storage=${c.read(srsStorageProvider)} '
          'store=${c.read(srsStoreProvider)} '
          'decks=${c.read(srsDeckListProvider)}',
        );
      }
    }
    bool viaButton = start.evaluate().isNotEmpty;
    if (!viaButton) {
      // R0 实测：开库已报「要迁移」（srsStorageProvider / srsStoreProvider 都是 AsyncError）而牌组列表一直
      // AsyncLoading、复习页一直转圈。记下各 provider 的状态与 `.future` 是否完成，作废列表再等一轮。
      final ProviderContainer c = ProviderScope.containerOf(
        appModel.navigatorKey.currentContext!,
      );
      Future<String> settle(Future<Object?> f) => f
          .then<String>((Object? v) => 'value $v')
          .catchError((Object e) => 'error ${e.runtimeType}')
          .timeout(const Duration(seconds: 5), onTimeout: () => 'timeout');
      final AsyncValue<Object?> store = c.read(srsStoreProvider);
      _log(
        '[r0] store isLoading=${store.isLoading} isRefreshing=${store.isRefreshing} '
        'revision=${c.read(srsRevisionProvider)}',
      );
      _log(
        '[r0] storage.future: ${await settle(c.read(srsStorageProvider.future))}',
      );
      _log(
        '[r0] store.future: ${await settle(c.read(srsStoreProvider.future))}',
      );
      _log(
        '[r0] decks.future: ${await settle(c.read(srsDeckListProvider.future))}',
      );
      // 假设（第一轮复核要求证实）：存储 / store 两层是 app 启动时在 main.dart 的 runZonedGuarded 里（错误 zone A，
      // 常驻装配 srsAppRuntimeProvider 的 readStore）先建的，它们缓存的 `.future` 落在 A；本 itest 的 binding 在测试
      // 文件 main 里初始化，帧回调（复习页 / 牌组列表的 build）跑在另一个错误 zone。Dart 的错误不跨错误 zone 投递：
      // 帧 zone 里 await 那个已失败的 future 永远等不到，错误按 A 的未捕获错误记进 error_log（UncaughtZone）。正式
      // 版只有一个错误 zone（binding 在 A 里初始化），不存在这个错位。
      // 判别：走复习页错误态「重试」同一条作废（retrySrsStoreOpen：只作废失败了的那一层），并且放在帧回调里做，
      // 重建出的 future 就落在帧 zone。假设成立 → 迁移页随即出现、`.future` 不再超时；不成立 → 照旧转圈。
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _log('[r0] retry in frame zone (invalidate failed storage/store)');
        if (c.read(srsStorageProvider).hasError) {
          c.invalidate(srsStorageProvider);
        }
        if (c.read(srsStoreProvider).hasError) c.invalidate(srsStoreProvider);
      });
      for (int i = 0; i < 240 && start.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      viaButton = start.evaluate().isNotEmpty;
      _log(
        '[r0] after frame-zone retry: found=$viaButton '
        'storage=${c.read(srsStorageProvider)} '
        'decks=${c.read(srsDeckListProvider)}',
      );
    }
    _log('[r0] prompt text: ${_visibleText()}');
    await captureFlutterFrame(tester, 'r0-01-prompt', settle: false);
    final ProviderContainer container = ProviderScope.containerOf(
      appModel.navigatorKey.currentContext!,
    );
    final SrsGen4MigrationController controller = container.read(
      srsGen4MigrationProvider,
    );
    final Stopwatch clock;
    if (viaButton) {
      // 进场动画走完再遍历（有界 pump，屏上可能有不停的动画）。
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      // 焦点驱动（Tab 遍历 + Enter，同 FocusDriver，不用坐标）。每一步都记日志、按键带超时：上一轮在这一步停了 18 分钟没有任何输出，要知道停在哪。
      Future<bool> key(LogicalKeyboardKey k) => tester
          .sendKeyEvent(k)
          .then((_) => true)
          .timeout(const Duration(seconds: 10), onTimeout: () => false);
      bool reached = _focusInside(start);
      for (int i = 0; i < 12 && !reached; i++) {
        final bool sent = await key(LogicalKeyboardKey.tab);
        for (int j = 0; j < 2; j++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        reached = _focusInside(start);
        _log(
          '[r0] tab #$i sent=$sent focus=${FocusManager.instance.primaryFocus} '
          'onStart=$reached',
        );
        if (!sent) break;
      }
      if (!reached) {
        // 复核轮实测（r0-a-zone2）：Tab 60 次焦点一直停在同一个无标签 Focus 上，遍历不动。这里不让 expect 失败
        // （live binding 下失败后的收尾会挂住整条用例），记下来，改用 FocusDriver 的焦点兜底：把焦点交给按钮自己
        // 的 Focus 节点（纯焦点操作，不是坐标点击），再按 Enter。遍历不到按钮的原因见 R0 文档 §4.1。
        _log(
          '[r0] TAB TRAVERSAL NEVER REACHED START; requesting its focus node',
        );
        reached = await FocusDriver(tester).requestFocusInside(start);
        for (int j = 0; j < 4; j++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        reached = reached && _focusInside(start);
        _log(
          '[r0] requestFocusInside -> onStart=$reached '
          'focus=${FocusManager.instance.primaryFocus}',
        );
      }
      final Finder button = find.descendant(
        of: start,
        matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton),
      );
      final ButtonStyleButton? b = button.evaluate().isEmpty
          ? null
          : tester.widget<ButtonStyleButton>(button.first);
      final List<String> owners = <String>[];
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
        Element e,
      ) {
        owners.add(e.widget.runtimeType.toString());
        return owners.length < 12;
      });
      _log(
        '[r0] diag: button=${b?.runtimeType} enabled=${b?.enabled} '
        'canStart=${controller.canStart} dbOpen=${appModel.isDatabaseOpen} '
        'focusOwners=${owners.join(' < ')}',
      );
      clock = Stopwatch()..start();
      if (reached) {
        _log('[r0] start button focused; pressing Enter');
        _log('[r0] enter sent=${await key(LogicalKeyboardKey.enter)}');
      } else if (b != null && b.enabled) {
        // 焦点进不去（见上面 diag）：按钮本身可用，改调它的 onPressed（与 Enter 激活同一个回调，不是坐标点击），结论里注明。
        _log('[r0] FOCUS FALLBACK: invoking the enabled button onPressed');
        b.onPressed!();
      } else {
        _log('[r0] start button disabled; giving up');
        return;
      }
    } else if (_fallbackStart) {
      // 迁移页没出来（上面记了原因）：按钮背后就是 controller.start，直接调它把迁移本身测完，结论里注明。
      _log(
        '[r0] FALLBACK: start button never appeared; calling controller.start()',
      );
      clock = Stopwatch()..start();
      unawaited(controller.start());
    } else {
      fail('旧库应当让复习页给出迁移提示（FUSHI_R0_FALLBACK_START=true 可改走 controller.start）');
    }

    bool shotProgress = false;
    String lastStep = '';
    while (clock.elapsed < const Duration(minutes: 5)) {
      await tester.pump(const Duration(milliseconds: 10));
      final SrsGen4MigrationProgress? pr = controller.progress;
      final String step = pr == null
          ? controller.phase.name
          : '${pr.step.wire} ${pr.done}/${pr.total}';
      if (step != lastStep) {
        _log(
          '[r0] @${clock.elapsedMilliseconds}ms phase=${controller.phase.name} step=$step',
        );
        lastStep = step;
      }
      final bool killNow =
          (_killAfterMs >= 0 && clock.elapsedMilliseconds >= _killAfterMs) ||
          (_killAt.isNotEmpty && pr != null && pr.step.wire == _killAt);
      if (killNow) {
        _log(
          '[r0] HARD KILL pid=$pid @${clock.elapsedMilliseconds}ms step=$step',
        );
        Process.killPid(pid, ProcessSignal.sigkill);
        await Future<void>.delayed(const Duration(seconds: 30));
      }
      if (!shotProgress && controller.phase == SrsGen4MigrationPhase.running) {
        shotProgress = true;
        await captureFlutterFrame(tester, 'r0-02-progress', settle: false);
      }
      if (controller.phase != SrsGen4MigrationPhase.running &&
          clock.elapsedMilliseconds > 200) {
        break;
      }
    }
    _log(
      '[r0] finished @${clock.elapsedMilliseconds}ms phase=${controller.phase.name} '
      'outcome=${controller.outcome?.verdict.name} error=${controller.error}',
    );
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    _log('[r0] after text: ${_visibleText()}');
    await captureFlutterFrame(tester, 'r0-03-after', settle: false);
    final SrsGen4MigrationStatus status = SrsGen4Migration.status(
      appModel.srsStorage.directory,
    );
    _log(
      '[r0] status after: state=${status.state.name} running=${status.running}',
    );
    expect(controller.phase, SrsGen4MigrationPhase.committed);
  });
}
