import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_dictionary_page.dart';
import 'package:hibiki/src/sync/desktop_foreground_guard.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// BUG-700 / TODO-1385 回归守卫：桌面剪贴板自动查词在窗口跨 600px 尺寸断点后失效。
///
/// 根因：DesktopLookupService 是 app 级单例，其唯一 owner HomeDictionaryPage 会在窗口
/// 物理宽跨 600px 断点（home_page 的 compact<->medium 布局切换，两套结构不同的 Scaffold）
/// 时被 Flutter dispose+重建。Flutter 先挂新元素（initState->start）、帧末才卸旧元素
/// （dispose->stop），同一帧内短暂存在两个 owner。改前用裸 bool：新页 start 短路 no-op、
/// 旧页 stop 把 watcher 拆掉 -> watcher 死、静默不查。改后用引用计数（isRunning==计数>0），
/// 断点期计数 1->2->1 恒 >0，watcher 存活。
class _ClipboardWatcherAppModel extends AppModel {
  _ClipboardWatcherAppModel() : super(testPlatformServices());

  final List<String> searchedTerms = <String>[];

  // 关键：开着剪贴板监听，HomeDictionaryPage 才会在 initState 真正 start() 服务。
  @override
  bool get desktopClipboardEnabled => true;

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
    searchedTerms.add(searchTerm);
    return DictionarySearchResult(searchTerm: searchTerm);
  }
}

Widget _wrap(_ClipboardWatcherAppModel appModel, ValueNotifier<bool> wide) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        navigatorKey: appModel.navigatorKey,
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: ValueListenableBuilder<bool>(
          valueListenable: wide,
          builder: (BuildContext context, bool isWide, _) {
            if (isWide) {
              // >=600 桌面布局：Row + 侧栏 + Expanded 内容（对应 _buildDesktopLayout）。
              // HomeDictionaryPage 从 Scaffold.body 直挂移到 Row>Expanded 下 -> 树位置变、
              // 类型不可 reconcile -> 旧元素 dispose、新元素重建（复现断点重建）。
              return Scaffold(
                body: Row(
                  children: const <Widget>[
                    SizedBox(width: 80),
                    VerticalDivider(width: 1),
                    Expanded(child: HomeDictionaryPage()),
                  ],
                ),
              );
            }
            // <600 移动布局：底栏 Scaffold（对应 _buildMobileLayout）。
            return const Scaffold(
              body: HomeDictionaryPage(),
              bottomNavigationBar: SizedBox(height: 56),
            );
          },
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> clipboardWatcherCalls = <String>[];
  String clipboardText = '';

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
    m.setMockMethodCallHandler(const MethodChannel('app.hibiki/window'),
        (MethodCall call) async => null);
    m.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, Object?>{'text': clipboardText};
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
      'app.hibiki/window',
    ]) {
      m.setMockMethodCallHandler(MethodChannel(name), null);
    }
    m.setMockMethodCallHandler(SystemChannels.platform, null);
  }

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    clipboardWatcherCalls.clear();
    clipboardText = '';
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

  // 引用计数直接语义：断点期「双 start 后单 stop」必须保持 watcher 存活，只有最后一个
  // 引用释放才真正拆；计数已 0 再 stop 是钳制 no-op（防下溢）。
  testWidgets(
      'start/stop reference-counted: transient double-start survives one stop',
      (WidgetTester tester) async {
    if (!DesktopLookupService.isDesktop) return;
    installChannels(tester);
    addTearDown(() => clearChannels(tester));
    final DesktopLookupService svc = DesktopLookupService.instance;

    await svc.start(windowMode: DesktopClipboardWindowMode.normal);
    expect(svc.isRunning, isTrue);
    expect(clipboardWatcherCalls, contains('start'),
        reason: '首个 owner 0->1 真正启动 OS 剪贴板 watcher');

    clipboardWatcherCalls.clear();
    // 复现断点：新页 initState.start（1->2）后旧页 dispose.stop（2->1）。
    await svc.start(windowMode: DesktopClipboardWindowMode.normal);
    await svc.stop();
    expect(svc.isRunning, isTrue,
        reason: 'refcount 仍 >0，watcher 必须存活（这正是断点后失效的根因）');
    expect(clipboardWatcherCalls, isNot(contains('stop')),
        reason: '仍被持有时绝不能拆 OS watcher');

    // 最后一个引用释放（1->0）才真正拆。
    await svc.stop();
    expect(svc.isRunning, isFalse);
    expect(clipboardWatcherCalls, contains('stop'),
        reason: '1->0 才真正停 OS watcher');

    // 计数已 0 再 stop 是钳制 no-op（防下溢），不再重复停 watcher。
    clipboardWatcherCalls.clear();
    await svc.stop();
    expect(svc.isRunning, isFalse);
    expect(clipboardWatcherCalls, isEmpty);
  });

  // 行为守卫：真 HomeDictionaryPage 跨 600px 断点 dispose+重建后，剪贴板 watcher 仍活，
  // 自动查词仍触发（修前：旧页 dispose.stop 会把 watcher 拆死 -> isRunning=false / OS
  // watcher 被 stop）。
  testWidgets(
      'dictionary page survives 600px breakpoint rebuild: watcher stays alive '
      'and auto-lookup still fires', (WidgetTester tester) async {
    if (!DesktopLookupService.isDesktop) return;
    installChannels(tester);
    addTearDown(() => clearChannels(tester));
    final DesktopLookupService svc = DesktopLookupService.instance;
    final _ClipboardWatcherAppModel appModel = _ClipboardWatcherAppModel();
    final ValueNotifier<bool> wide = ValueNotifier<bool>(false);
    addTearDown(wide.dispose);

    await tester.pumpWidget(_wrap(appModel, wide));
    await tester.pump();
    // 页面 initState 的 start() 是 unawaited；isRunning 在计数自增（首个 await 前）即为真。
    expect(svc.isRunning, isTrue);
    // 让 fire-and-forget 的 start() 跑完通道调用（clipboardWatcher.start）。
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(clipboardWatcherCalls, contains('start'));

    // 跨断点：<600 底栏布局 -> >=600 侧栏布局，强制 HomeDictionaryPage dispose+重建。
    clipboardWatcherCalls.clear();
    wide.value = true;
    // 本帧内：新页 initState.start（1->2，只重配窗口模式）+ 帧末旧页 dispose.stop（2->1，不拆）。
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(svc.isRunning, isTrue,
        reason: '跨断点重建后 watcher 必须仍活（修前此处会被旧页 stop 拆死）');
    expect(clipboardWatcherCalls, isNot(contains('stop')),
        reason: '断点重建期绝不能停 OS 剪贴板 watcher');

    // 端到端：模拟外部复制日文，断言重建后的页面仍自动查词。
    clipboardText = 'こんにちは';
    svc.onWindowBlur(); // 失焦=用户在别的 app 复制 -> 应触发被动查词
    await tester.runAsync(() async {
      svc.onClipboardChanged();
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
    await tester.pump();
    expect(appModel.searchedTerms, contains('こんにちは'),
        reason: '跨断点后被动剪贴板变化仍必须驱动自动查词');
  });
}
