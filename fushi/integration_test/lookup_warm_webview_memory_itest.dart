import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 游戏 tab 与查词 tab 的预热查词 WebView 内存探针（Windows，本地测量用）。
///
/// 拍板台 design-shared-lookup-webview：两页原先各 seed 一个常驻隐藏的预热 WebView，
/// 两个 tab 都进过后后台挂两个；改成 HomePage 持有一个 [SharedLookupPopupHost] 共用。
/// 本探针依次进首页 → 游戏 → 查词 → 游戏，每步等 WebView 装载完，记下树里挂着的
/// [DictionaryPopupWebView] 个数与本进程派生的 msedgewebview2 进程数 / 私有字节 /
/// 工作集，以 `[lookup-mem]` 前缀打进日志。查词页只在结果区渲染出来之后才把浮层挂上
/// 根 Overlay（热槽 WebView 此时才真正建出来），所以进查词 tab 后先查一个词（生成的测试
/// 词典里的「猫」）。`popupWebViews` 含结果区那一个；修前「查词」一步是结果区 + 两个
/// 热槽，修后是结果区 + 一个热槽。
///
/// 跑法（fushi/ 下）：
///   .\tool\run_windows_itest.ps1 integration_test\lookup_warm_webview_memory_itest.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('warm lookup WebView memory across games / dictionary tabs', (
    WidgetTester tester,
  ) async {
    if (!Platform.isWindows) return;
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    final AppModel appModel = await readyAppModel(tester);
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

    final List<HomeTab> tabs = homeActiveTabs(appModel.moduleVisibility);
    debugPrint(
      '[lookup-mem] tabs=${tabs.map((HomeTab t) => t.name).join(",")}',
    );
    expect(tabs, contains(HomeTab.games), reason: '游戏模块需开启');
    expect(tabs, contains(HomeTab.dictionaries), reason: '查词模块需开启');

    expect(await seedDictionary(tester), isTrue, reason: '需要测试词典才能出结果');

    Future<void> step(
      String label,
      HomeTab? tab, {
      Future<void> Function()? then,
    }) async {
      if (tab != null) homeShellTabNotifier.value = tab;
      if (then != null) {
        await Future<void>.delayed(const Duration(seconds: 2));
        await tester.pump();
        await then();
      }
      // 等页面挂载、热槽 seed、WebView2 装完 popup.html 并稳定下来。
      await Future<void>.delayed(const Duration(seconds: 10));
      await tester.pump();
      final int webViews = find
          .byType(DictionaryPopupWebView, skipOffstage: false)
          .evaluate()
          .length;
      final _WebView2Usage usage = await _webView2Usage();
      debugPrint(
        '[lookup-mem] step=$label popupWebViews=$webViews '
        'webview2Processes=${usage.processes} '
        'privateMB=${(usage.privateBytes / 1048576).toStringAsFixed(1)} '
        'workingSetMB=${(usage.workingSet / 1048576).toStringAsFixed(1)}',
      );
    }

    await step('home', null);
    await step('games', HomeTab.games);
    await step(
      'dictionaries+search',
      HomeTab.dictionaries,
      then: () async {
        final HomeDictionarySearchDebug page =
            tester.state(find.byType(HomeDictionaryPage))
                as HomeDictionarySearchDebug;
        await page.debugSearch('猫');
      },
    );
    await step('games-again', HomeTab.games);
  });
}

typedef _WebView2Usage = ({int processes, int privateBytes, int workingSet});

/// 本进程派生的全部 msedgewebview2.exe（浏览器进程、渲染进程、GPU / 工具进程）的
/// 进程数与内存合计。WebView2 的子进程挂在浏览器进程下，按父子关系广度遍历。
Future<_WebView2Usage> _webView2Usage() async {
  final String script =
      '''
\$all = Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,PrivatePageCount,WorkingSetSize
\$kids = @{}
foreach (\$p in \$all) { \$k = [int]\$p.ParentProcessId; if (-not \$kids.ContainsKey(\$k)) { \$kids[\$k] = @() }; \$kids[\$k] += \$p }
\$q = New-Object System.Collections.Queue
\$q.Enqueue([int]$pid)
\$seen = @{}
\$n = 0; \$priv = [int64]0; \$ws = [int64]0
while (\$q.Count -gt 0) {
  \$id = \$q.Dequeue()
  if (\$seen.ContainsKey(\$id)) { continue }
  \$seen[\$id] = \$true
  if (-not \$kids.ContainsKey(\$id)) { continue }
  foreach (\$c in \$kids[\$id]) {
    \$q.Enqueue([int]\$c.ProcessId)
    if (\$c.Name -eq 'msedgewebview2.exe') { \$n++; \$priv += [int64]\$c.PrivatePageCount; \$ws += [int64]\$c.WorkingSetSize }
  }
}
"\$n \$priv \$ws"
''';
  final ProcessResult result = await Process.run('powershell', <String>[
    '-NoProfile',
    '-Command',
    script,
  ]);
  final List<String> parts = (result.stdout as String).trim().split(
    RegExp(r'\s+'),
  );
  if (parts.length != 3) {
    debugPrint('[lookup-mem] probe failed: ${result.stdout} ${result.stderr}');
    return (processes: -1, privateBytes: 0, workingSet: 0);
  }
  return (
    processes: int.parse(parts[0]),
    privateBytes: int.parse(parts[1]),
    workingSet: int.parse(parts[2]),
  );
}
