// 复习页「评分后空格」的 OS 焦点实测（Windows runner，手动跑，-Visible）。
//
// 种几张 Fushi 卡片 → 打开复习页 → 翻面 → 指针点进释义 WebView（OS 焦点进 WebView2）
// → 数字键评分换卡 → 读这一刻 OS 键盘焦点落在哪个 HWND（GetGUIThreadInfo）→ 向那个
// HWND 真注入一个空格，看卡片有没有翻面。两轮：现行实现 / 把视图焦点请求换成 no-op
// （= 只在 Flutter 内部挪焦点），用来判断「Flutter 认为有焦点但 OS 焦点在原生视图」是否
// 成立、修复是否有效。结果打 `[srs-os-focus]` 行。
//
//   .\tool\run_windows_itest.ps1 -Visible integration_test/srs_review_os_focus_itest.dart
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' show FlutterView;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/srs/srs_card_sample.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final int Function() _getCurrentProcessId = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');

final int Function(int, int, Pointer<Utf16>, Pointer<Utf16>) _findWindowEx =
    _user32.lookupFunction<
      IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
      int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowExW');
final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId = _user32
    .lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)
    >('GetWindowThreadProcessId');
final int Function(int, Pointer<Uint8>) _getGuiThreadInfo = _user32
    .lookupFunction<
      Int32 Function(Uint32, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>)
    >('GetGUIThreadInfo');
final int Function(int, Pointer<Utf16>, int) _getClassName = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, int)
    >('GetClassNameW');
final int Function(int, int) _getAncestor = _user32
    .lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>(
      'GetAncestor',
    );
final int Function() _getForegroundWindow = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
final int Function(int) _setForegroundWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'SetForegroundWindow',
    );
final int Function(int, int) _getWindowLongPtr = _user32
    .lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>(
      'GetWindowLongPtrW',
    );
final int Function(int, int, int) _setWindowLongPtr = _user32
    .lookupFunction<
      IntPtr Function(IntPtr, Int32, IntPtr),
      int Function(int, int, int)
    >('SetWindowLongPtrW');
final void Function(int, int, int, int) _keybdEvent = _user32
    .lookupFunction<
      Void Function(Uint8, Uint8, Uint32, IntPtr),
      void Function(int, int, int, int)
    >('keybd_event');
final int Function(int, int, int, int) _postMessage = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)
    >('PostMessageW');

const int _gwlExStyle = -20;
const int _wsExNoActivate = 0x08000000;
const int _vkSpace = 0x20;
const int _vkMenu = 0x12;
const int _keyeventfKeyUp = 0x0002;
const int _wmKeyDown = 0x0100;
const int _wmKeyUp = 0x0101;

String _className(int hwnd) {
  if (hwnd == 0) return '-';
  final Pointer<Utf16> buf = calloc<Uint16>(256).cast<Utf16>();
  try {
    _getClassName(hwnd, buf, 256);
    return buf.toDartString();
  } finally {
    calloc.free(buf);
  }
}

int _pidOf(int hwnd) {
  final Pointer<Uint32> pid = calloc<Uint32>();
  try {
    _getWindowThreadProcessId(hwnd, pid);
    return pid.value;
  } finally {
    calloc.free(pid);
  }
}

int _threadOf(int hwnd) => _getWindowThreadProcessId(hwnd, nullptr);

/// 本进程的主窗（用户自己开着的 Fushi 窗口同类名，按 pid 过滤）。
int _mainWindow() {
  final int me = _getCurrentProcessId();
  final Pointer<Utf16> cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  try {
    int h = 0;
    while (true) {
      h = _findWindowEx(0, h, cls, nullptr);
      if (h == 0) return 0;
      if (_pidOf(h) == me) return h;
    }
  } finally {
    calloc.free(cls);
  }
}

/// 某线程的 OS 键盘焦点 HWND（GUITHREADINFO.hwndFocus，偏移 16）。
int _focusOfThread(int thread) {
  final Pointer<Uint8> info = calloc<Uint8>(72);
  try {
    info.cast<Uint32>().value = 72;
    if (_getGuiThreadInfo(thread, info) == 0) return -1;
    return (info + 16).cast<IntPtr>().value;
  } finally {
    calloc.free(info);
  }
}

/// 焦点 HWND 的描述：类名 + 所属 pid 是否本进程 + 根窗口类名 + 祖先链。
String _describe(int hwnd) {
  if (hwnd <= 0) return 'hwnd=$hwnd';
  final List<String> chain = <String>[];
  int h = hwnd;
  for (int i = 0; i < 6 && h != 0; i++) {
    chain.add(_className(h));
    h = _getAncestor(h, 1); // GA_PARENT
  }
  final bool own = _pidOf(hwnd) == _getCurrentProcessId();
  return 'hwnd=0x${hwnd.toRadixString(16)} class=${_className(hwnd)} '
      'ownPid=$own chain=${chain.join(" < ")}';
}

/// 探针行同时落盘（flutter test 的 stdout 要到结束才刷出，卡住时看不到进度）。
void _log(String line) {
  debugPrint(line);
  final Directory? docs = fushiTestDirectory('app-documents');
  if (docs == null) return;
  File(
    p.join(docs.path, 'srs_os_focus_probe.txt'),
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('复习页：点进释义 WebView 后评分换卡，OS 焦点与真空格', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    await appModel.setModuleEnabled(ModuleId.srs, true);
    await _pumpFor(tester, const Duration(seconds: 1));

    final BuildContext rootContext = appModel.navigatorKey.currentContext!;
    final ProviderContainer container = ProviderScope.containerOf(rootContext);
    final SrsDbStore store = (await container.read(srsStoreProvider.future))!;
    await store.ensureBuiltins();
    final String uid = store.profileUid;
    for (int i = 0; i < 8; i++) {
      final Map<String, String> fields = <String, String>{
        ...srsSampleCardFields(),
        'Expression': '単語$i',
      };
      await store.createNote(
        noteTypeId: store.fushiCardNoteTypeId,
        createdAt: 1700000000000 + i,
        fieldsById: <String, String>{
          for (final MapEntry<String, String> e in fields.entries)
            srsFushiCardFieldId(uid, e.key): e.value,
        },
      );
    }
    container.read(srsRevisionProvider.notifier).state++;

    final int main = _mainWindow();
    final int thread = _threadOf(main);
    final int previousForeground = _getForegroundWindow();
    _log(
      '[srs-os-focus] main=${_describe(main)} thread=$thread '
      'prevForeground=0x${previousForeground.toRadixString(16)}',
    );
    expect(main, isNot(0), reason: '应找到本进程主窗');

    // runner 的窗口带 WS_EX_NOACTIVATE（永不成前台）；本测试要的是用户真实状态：主窗在前台。
    _setWindowLongPtr(
      main,
      _gwlExStyle,
      _getWindowLongPtr(main, _gwlExStyle) & ~_wsExNoActivate,
    );
    bool ensureForeground() {
      if (_getForegroundWindow() == main) return true;
      _keybdEvent(_vkMenu, 0, 0, 0);
      _keybdEvent(_vkMenu, 0, _keyeventfKeyUp, 0);
      _setForegroundWindow(main);
      return _getForegroundWindow() == main;
    }

    bool flipped() => find.byType(SrsRatingButton).evaluate().isNotEmpty;

    String focusLine(String label) {
      final int f = _focusOfThread(thread);
      final int fg = _getForegroundWindow();
      final FocusNode? primary = FocusManager.instance.primaryFocus;
      final String line =
          '[srs-os-focus] $label os=${_describe(f)} '
          'foreground=${fg == main} fgWin=${_describe(fg)} '
          'flutterPrimary=${primary?.debugLabel} ${primary?.runtimeType} '
          'ctx=${primary?.context?.widget.runtimeType}';
      _log(line);
      return line;
    }

    /// 空格真进 OS：主窗在前台时 keybd_event（走系统输入队列 → 焦点窗）；否则直接投给焦点窗。
    Future<String> injectSpace() async {
      // 主窗在前台才走系统输入队列；否则不碰键盘状态（别把键打进用户正在用的窗口），
      // 直接投给本线程的焦点窗。
      if (_getForegroundWindow() == main) {
        _keybdEvent(_vkSpace, 0x39, 0, 0);
        _keybdEvent(_vkSpace, 0x39, _keyeventfKeyUp, 0);
        return 'keybd_event';
      }
      final int f = _focusOfThread(thread);
      _postMessage(f, _wmKeyDown, _vkSpace, 0x00390001);
      _postMessage(f, _wmKeyUp, _vkSpace, 0xC0390001);
      return 'PostMessage->${_className(f)}';
    }

    final void Function(FlutterView) realRequest =
        SrsReviewPage.requestNativeViewFocus;
    final Map<String, bool> verdicts = <String, bool>{};
    try {
      for (final String mode in <String>['with-view-focus', 'no-view-focus']) {
        int requests = 0;
        SrsReviewPage.requestNativeViewFocus = mode == 'with-view-focus'
            ? (FlutterView v) {
                requests++;
                realRequest(v);
              }
            : (FlutterView _) => requests++;
        unawaited(
          appModel.navigatorKey.currentState!.push(
            MaterialPageRoute<void>(
              builder: (BuildContext _) =>
                  SrsReviewPage(deckId: store.defaultDeckId, deckName: mode),
            ),
          ),
        );
        await _pumpFor(tester, const Duration(seconds: 4));
        _log('[srs-os-focus] $mode foregroundOk=${ensureForeground()}');
        await _pumpFor(tester, const Duration(milliseconds: 500));
        focusLine('$mode 00-front');

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await _pumpFor(tester, const Duration(seconds: 3));
        expect(flipped(), isTrue, reason: '$mode: Flutter 空格应翻面');

        final Finder web = find.byType(InAppWebView);
        _log('[srs-os-focus] $mode onstage webviews=${web.evaluate().length}');
        expect(web, findsWidgets, reason: '$mode: 背面应有释义 WebView');
        final Rect rect = tester.getRect(web.first);
        _log('[srs-os-focus] $mode tap webview at $rect');
        // 点 WebView 底部空白（点在释义文字上会开查词弹窗，弹窗开着时数字键按设计不评分）。
        await tester.tapAt(
          Offset(rect.center.dx, rect.bottom - 40),
        ); // itest-tap-allow: 指针点进平台 WebView，验证 OS 焦点是否被它夺走（没有焦点等价操作）
        await _pumpFor(tester, const Duration(milliseconds: 1500));
        focusLine('$mode 01-after-click-webview');
        await captureFlutterFrame(tester, 'os-focus-$mode-01-back');

        // 评分（3 = 良好）：键盘事件直接给 Flutter，与用户在卡面上按数字键经页内桥交回等价。
        _log('[srs-os-focus] $mode grading');
        await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
        _log('[srs-os-focus] $mode graded');
        await _pumpFor(tester, const Duration(seconds: 2));
        focusLine('$mode 02-after-grade');
        final bool advanced = !flipped();
        _log('[srs-os-focus] $mode advancedAfterGrade=$advanced');
        if (!advanced) {
          verdicts[mode] = false;
          appModel.navigatorKey.currentState!.pop();
          await _pumpFor(tester, const Duration(seconds: 1));
          continue;
        }

        _log('[srs-os-focus] $mode injecting space');
        final String via = await injectSpace();
        _log('[srs-os-focus] $mode injected via $via');
        await _pumpFor(tester, const Duration(milliseconds: 1500));
        final bool ok = flipped();
        verdicts[mode] = ok;
        focusLine('$mode 03-after-os-space');
        _log(
          '[srs-os-focus] $mode RESULT osSpaceFlipped=$ok via=$via '
          'viewFocusRequests=$requests',
        );
        await captureFlutterFrame(tester, 'os-focus-$mode-03-after-space');

        appModel.navigatorKey.currentState!.pop();
        await _pumpFor(tester, const Duration(seconds: 1));
      }
    } finally {
      SrsReviewPage.requestNativeViewFocus = realRequest;
      if (previousForeground != 0) _setForegroundWindow(previousForeground);
    }
    _log('[srs-os-focus] VERDICTS $verdicts');
    expect(verdicts['with-view-focus'], isTrue, reason: '现行实现：评分换卡后真空格应能翻面');
  });
}
