import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:ffi/ffi.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/desktop_drop_reinitializer.dart';
import 'package:fushi/src/media/video/web_video_session.dart'
    show webVideoWindowedEnvironment;
import 'package:fushi/src/models/app_model.dart' show AppModel;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/library_fixture.dart' show readyAppModel;
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUOxDR9WIJ 探针（Windows 离屏 runner）：拖入导入的 OS 注册在哪一步丢。
///
/// `RegisterDragDrop` 把目标挂在窗口属性 `OleDropTargetInterface` 上；本探针在
/// 「基线 → 本地视频页开/关 → composition WebView 开/关 → 窗口宿主 WebView 开/关」
/// 每一步读 Flutter 视图 HWND 与主窗上的该属性，打印出来供判定。
///
/// 跑法（fushi/ 下）：
///   .\tool\run_windows_itest.ps1 integration_test/desktop_drop_registration_probe_itest.dart

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
final int Function(int, Pointer<Utf16>) _getProp = _user32
    .lookupFunction<
      IntPtr Function(IntPtr, Pointer<Utf16>),
      int Function(int, Pointer<Utf16>)
    >('GetPropW');

int _pidOf(int hwnd) {
  final Pointer<Uint32> pid = calloc<Uint32>();
  try {
    _getWindowThreadProcessId(hwnd, pid);
    return pid.value;
  } finally {
    calloc.free(pid);
  }
}

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

int _flutterView(int main) {
  final Pointer<Utf16> cls = 'FLUTTERVIEW'.toNativeUtf16();
  try {
    return _findWindowEx(main, 0, cls, nullptr);
  } finally {
    calloc.free(cls);
  }
}

final int Function(int) _isWindowVisible = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsWindowVisible',
    );
final int Function(int, Pointer<Utf16>, int) _getClassName = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, int)
    >('GetClassNameW');

/// [parent] 的直接子窗口：类名 + 是否可见 + 是否挂着 OLE drop target。
String _children(int parent) {
  if (parent == 0) return '';
  final List<String> out = <String>[];
  final Pointer<Utf16> buf = calloc<Uint16>(256).cast<Utf16>();
  final Pointer<Utf16> prop = 'OleDropTargetInterface'.toNativeUtf16();
  try {
    int h = 0;
    while (true) {
      h = _findWindowEx(parent, h, nullptr, nullptr);
      if (h == 0) break;
      _getClassName(h, buf, 256);
      out.add(
        '${buf.toDartString()}'
        '${_isWindowVisible(h) != 0 ? '(visible)' : ''}'
        '${_getProp(h, prop) != 0 ? '(dropTarget)' : ''}',
      );
    }
  } finally {
    calloc.free(buf);
    calloc.free(prop);
  }
  return out.join(', ');
}

String _dropProps() {
  final int main = _mainWindow();
  final int view = _flutterView(main);
  final Pointer<Utf16> name = 'OleDropTargetInterface'.toNativeUtf16();
  try {
    final int onView = view == 0 ? -1 : _getProp(view, name);
    final int onMain = main == 0 ? -1 : _getProp(main, name);
    return 'main=0x${main.toRadixString(16)} view=0x${view.toRadixString(16)} '
        'viewDropTarget=0x${onView.toRadixString(16)} '
        'mainDropTarget=0x${onMain.toRadixString(16)} '
        'viewChildren=[${_children(view)}] mainChildren=[${_children(main)}]';
  } finally {
    calloc.free(name);
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final DateTime end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<File> _generateVideo() async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory root = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('fushi-drop-probe-')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await root.create(recursive: true);
  final File video = File(
    '${root.path}${Platform.pathSeparator}drop_probe.mkv',
  );
  final FfmpegRunResult result = await resolveFfmpegBackend().run(<String>[
    '-hide_banner',
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc=size=320x180:rate=10:duration=20',
    '-c:v',
    'mpeg4',
    '-pix_fmt',
    'yuv420p',
    video.path,
  ], const Duration(seconds: 60));
  expect(result.isSuccess, isTrue, reason: result.failureSummary);
  return video;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'desktop drop registration probe',
    timeout: const Timeout(Duration(minutes: 10)),
    (WidgetTester tester) async {
      await runFushiItest(
        label: 'drop-probe',
        body: () async {
          final File video = await _generateVideo();
          await launchFushiTestApp();
          expect(await waitForHome(tester), isTrue);
          final AppModel appModel = await readyAppModel(tester);
          await _pumpFor(tester, const Duration(seconds: 2));
          debugPrint(
            '[drop-probe] baseline: ${_dropProps()} status=${await DesktopDropReinitializer.debugStatus()}',
          );

          final NavigatorState navigator = tester.state<NavigatorState>(
            find.byType(Navigator).first,
          );

          // ── 本地视频页 ──
          final VideoBookRepository repo = VideoBookRepository(
            appModel.database,
          );
          await repo.saveVideoBook(
            VideoBooksCompanion(
              bookUid: const Value('video/itest-drop-probe'),
              title: const Value('drop probe'),
              videoPath: Value(video.absolute.path),
            ),
          );
          unawaited(
            navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => VideoFushiPage(
                  bookUid: 'video/itest-drop-probe',
                  repo: repo,
                ),
              ),
            ),
          );
          await _pumpFor(tester, const Duration(seconds: 6));
          debugPrint(
            '[drop-probe] video open: ${_dropProps()} status=${await DesktopDropReinitializer.debugStatus()}',
          );
          navigator.pop();
          await _pumpFor(tester, const Duration(seconds: 4));
          debugPrint(
            '[drop-probe] video closed: ${_dropProps()} status=${await DesktopDropReinitializer.debugStatus()}',
          );

          // ── composition WebView ──
          unawaited(
            navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: InAppWebView(
                    initialData: InAppWebViewInitialData(
                      data: '<html><body>composition probe</body></html>',
                    ),
                  ),
                ),
              ),
            ),
          );
          await _pumpFor(tester, const Duration(seconds: 6));
          debugPrint(
            '[drop-probe] composition webview open: ${_dropProps()} status=${await DesktopDropReinitializer.debugStatus()}',
          );
          navigator.pop();
          await _pumpFor(tester, const Duration(seconds: 4));
          debugPrint(
            '[drop-probe] composition webview closed: ${_dropProps()} status=${await DesktopDropReinitializer.debugStatus()}',
          );

          // ── 窗口宿主 WebView（网页播放器同款环境）──
          final WebViewEnvironment env = await webVideoWindowedEnvironment();
          unawaited(
            navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: InAppWebView(
                    webViewEnvironment: env,
                    initialData: InAppWebViewInitialData(
                      data: '<html><body>windowed probe</body></html>',
                    ),
                  ),
                ),
              ),
            ),
          );
          await _pumpFor(tester, const Duration(seconds: 6));
          debugPrint(
            '[drop-probe] windowed webview open: ${_dropProps()} status=${await DesktopDropReinitializer.debugStatus()}',
          );
          navigator.pop();
          await _pumpFor(tester, const Duration(seconds: 4));
          final List<String> dropLogs = <String>[
            for (final ErrorLogEntry e
                in ErrorLogService.instance.diagnosticEntries)
              if (e.source == 'DesktopDrop') e.error,
          ];
          debugPrint('[drop-probe] DesktopDrop diagnostics: $dropLogs');
          debugPrint(
            '[drop-probe] windowed webview closed: ${_dropProps()} status=${await DesktopDropReinitializer.debugStatus()}',
          );
          final DesktopDropStatus? finalStatus =
              await DesktopDropReinitializer.debugStatus();
          expect(
            finalStatus,
            isNotNull,
            reason: 'vendored desktop_drop must answer the status method',
          );
          expect(
            finalStatus!.healthy,
            isTrue,
            reason: 'drop registration must survive video / WebView2 pages',
          );
          expect(
            dropLogs.where((String l) => l.contains('lost')),
            isEmpty,
            reason: 'no route pop may have found the registration lost',
          );
        },
      );
    },
  );
}
