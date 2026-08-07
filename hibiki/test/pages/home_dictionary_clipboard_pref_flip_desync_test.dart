import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_dictionary_page.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1020 回归守卫：Windows 桌面剪贴板自动查词在「关闭状态下进词典页 → 页内打开
/// 剪贴板监听开关 → 离开词典页」这一顺序后永久失效，重启才恢复。
///
/// 根因：[DesktopLookupService] 是 app 级单例，监听生命周期用共享引用计数
/// `_startRefCount`，有两个 owner——app 级（AppModel.applyDesktopClipboardLifecycle，
/// 开=start/关=stop）与页级（HomeDictionaryPage，initState 按 pref start、dispose 按
/// pref stop）。缺陷在页级：start 门控读 initState 时的 `desktopClipboardEnabled`、stop
/// 门控读 dispose 时的同名可变 pref。当用户在 start 与 dispose 之间翻转开关，两次读到
/// 不同值 → 页级 dispose 的 stop 吞掉 app 级 hold 的 +1 → 计数归 0 → OS watcher 被真正
/// 拆掉，而 pref 仍显示「已开启」→ 剪贴板监听永久哑火直到重启。
///
/// 修法：页级用实例 bool `_desktopLookupStarted` 记录「本页确实 start 过」，dispose 仅
/// 据此 stop，与可变 pref 解耦——页级 owner 恒为严格配对的 +1/-1，pref 怎么翻都不吞别
/// 人的计数。
class _PrefFlipAppModel extends AppModel {
  _PrefFlipAppModel() : super(testPlatformServices());

  /// 可变，模拟用户在词典页内翻转剪贴板监听开关。
  bool clipboardEnabled = false;

  @override
  bool get desktopClipboardEnabled => clipboardEnabled;

  @override
  DesktopClipboardWindowMode get desktopClipboardWindowMode =>
      DesktopClipboardWindowMode.normal;

  @override
  List<DictionarySearchResult> get dictionaryHistory =>
      <DictionarySearchResult>[];

  @override
  List<Dictionary> get dictionaries => <Dictionary>[
        Dictionary(name: 'Test', formatKey: 'test', order: 0),
      ];

  @override
  int get maximumTerms => 10;

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async {
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

/// 挂载/卸载 HomeDictionaryPage 的最小外壳：mounted=false 时换成 SizedBox 触发 dispose。
Widget _wrap(_PrefFlipAppModel appModel, ValueNotifier<bool> mounted) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: ValueListenableBuilder<bool>(
          valueListenable: mounted,
          builder: (BuildContext context, bool isMounted, _) => Scaffold(
            body: isMounted
                ? const HomeDictionaryPage()
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> clipboardWatcherCalls = <String>[];

  void installChannels(WidgetTester tester) {
    final TestDefaultBinaryMessenger m = tester.binding.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (MethodCall call) async {
      if (call.method == 'isFocused') return false;
      if (call.method == 'isMinimized') return false;
      return null;
    });
    m.setMockMethodCallHandler(const MethodChannel('clipboard_watcher'),
        (MethodCall call) async {
      clipboardWatcherCalls.add(call.method);
      return null;
    });
    m.setMockMethodCallHandler(
      const MethodChannel('dev.leanflutter.plugins/hotkey_manager'),
      (MethodCall call) async => null,
    );
    // hotKeyManager.register 首次会 lazily 监听该 EventChannel（receiveBroadcastStream
    // 的 'listen'）；不 mock 会抛 MissingPluginException 到测试 zone 令其失败。
    m.setMockMethodCallHandler(
      const MethodChannel('dev.leanflutter.plugins/hotkey_manager_event'),
      (MethodCall call) async => null,
    );
    m.setMockMethodCallHandler(const MethodChannel('app.fushi/window'),
        (MethodCall call) async => null);
    m.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, Object?>{'text': ''};
      }
      return null;
    });
  }

  void clearChannels(WidgetTester tester) {
    final TestDefaultBinaryMessenger m = tester.binding.defaultBinaryMessenger;
    for (final String name in <String>[
      'window_manager',
      'clipboard_watcher',
      'dev.leanflutter.plugins/hotkey_manager',
      'dev.leanflutter.plugins/hotkey_manager_event',
      'app.fushi/window',
    ]) {
      m.setMockMethodCallHandler(MethodChannel(name), null);
    }
    m.setMockMethodCallHandler(SystemChannels.platform, null);
  }

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    clipboardWatcherCalls.clear();
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = false;
    DesktopForegroundGuard.debugForegroundOwnedByHibikiAppFamily = false;
    DesktopForegroundGuard.debugHiddenWindowsRunner = false;
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    DesktopForegroundGuard.debugForegroundOwnedByCurrentProcess = null;
    DesktopForegroundGuard.debugForegroundOwnedByHibikiAppFamily = null;
    DesktopForegroundGuard.debugHiddenWindowsRunner = null;
    DesktopLookupService.instance.debugReset();
  });

  testWidgets(
      'toggling clipboard ON inside dictionary page then leaving it keeps the '
      'app-level watcher alive (no refcount desync)',
      (WidgetTester tester) async {
    if (!DesktopLookupService.isDesktop) return;
    installChannels(tester);
    addTearDown(() => clearChannels(tester));
    final DesktopLookupService svc = DesktopLookupService.instance;
    final _PrefFlipAppModel appModel = _PrefFlipAppModel();
    final ValueNotifier<bool> mounted = ValueNotifier<bool>(true);
    addTearDown(mounted.dispose);

    // 1) 关闭状态下进入词典页：页级 initState 门控为假，不 start，watcher 未挂。
    await tester.pumpWidget(_wrap(appModel, mounted));
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(svc.isRunning, isFalse, reason: '关状态进页不应 start（页级 initState 门控为假）');
    expect(clipboardWatcherCalls, isNot(contains('start')));

    // 2) 用户在词典页内打开开关：app 级 hold（applyDesktopClipboardLifecycle）真正
    //    start 服务；pref 同步翻成 true。此后页级 dispose 若改读 pref 就会误判「本页
    //    start 过」而 stop——正是被守卫的 desync。
    appModel.clipboardEnabled = true;
    await tester.runAsync(
        () => svc.start(windowMode: DesktopClipboardWindowMode.normal));
    expect(svc.isRunning, isTrue);
    expect(clipboardWatcherCalls, contains('start'),
        reason: 'app 级 hold 0->1 真正启动 OS 剪贴板 watcher');

    // 3) 离开词典页：页级 dispose 触发。修前会读 pref==true → stop → 吞掉 app 级
    //    +1 → 计数归 0 → watcher 被拆死。修后据 _desktopLookupStarted==false 不 stop。
    clipboardWatcherCalls.clear();
    mounted.value = false;
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(svc.isRunning, isTrue,
        reason: '页从未 start 过，其 dispose 不得 stop 掉 app 级 hold（修前此处被拆成 false）');
    expect(clipboardWatcherCalls, isNot(contains('stop')),
        reason: '页级 dispose 不得拆掉 app 级持有的 OS watcher');
  });

  testWidgets(
      'page that DID start still stops exactly once on dispose even if the pref '
      'was flipped OFF while mounted (no leak)', (WidgetTester tester) async {
    if (!DesktopLookupService.isDesktop) return;
    installChannels(tester);
    addTearDown(() => clearChannels(tester));
    final DesktopLookupService svc = DesktopLookupService.instance;
    final _PrefFlipAppModel appModel = _PrefFlipAppModel()
      ..clipboardEnabled = true;
    final ValueNotifier<bool> mounted = ValueNotifier<bool>(true);
    addTearDown(mounted.dispose);

    // 开启状态进入词典页：页级 initState 真正 start（0->1）。
    await tester.pumpWidget(_wrap(appModel, mounted));
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(svc.isRunning, isTrue);
    expect(clipboardWatcherCalls, contains('start'));

    // 用户在页内关闭开关（pref 翻成 false），随后离开页。修前 dispose 门控读 pref==false
    // → 不 stop → 计数泄漏在 1（watcher 该停不停）。修后据 _desktopLookupStarted==true
    // 严格配对 stop（1->0），无泄漏。
    appModel.clipboardEnabled = false;
    clipboardWatcherCalls.clear();
    mounted.value = false;
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(svc.isRunning, isFalse,
        reason: '本页 start 过就必须在 dispose 严格配对 stop（1->0），不因 pref 翻转而泄漏计数');
    expect(clipboardWatcherCalls, contains('stop'),
        reason: '1->0 真正停 OS watcher');
  });
}
