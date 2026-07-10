// TODO-1268 (BUG-693) - Windows floating-lyric strip word-tap -> a REAL
// host-rendered global lookup card must appear (end-to-end device gate).
//
// User reported four times that tapping a word on the floating subtitle strip
// shows no lookup window. Two of the three earlier fixes (BUG-598 BAL /
// BUG-633 touch slop) only touched the ANDROID native overlay - but the
// user's Android phone (ColorOS, TODO-1227) is denied the overlay permission
// outright, so the strip they tap is the WINDOWS desktop strip
// (floating_lyric_window.cpp). The desktop round (BUG-578 await-hide) only
// addressed the rapid-retap race, yet its own device log showed the FIRST
// isolated tap ALSO getting zero host messages (blank READY-SAFETY reveal) -
// never explained nor re-verified.
//
// This test reproduces the user's full path on the real Windows engine:
//   1. Seed a cue-backed audiobook (seedAudiobook), enable the floating-lyric
//      preference, focus-drive the book open -> AudiobookSession shows the
//      native strip (HibikiFloatingLyricWindow).
//   2. Post REAL WM_LBUTTONDOWN/WM_LBUTTONUP to the native strip over the
//      subtitle text (PostMessageW) - the strip is a bare Win32 window, its
//      word-tap has no Flutter focus equivalent; every Flutter-side action
//      stays focus-driven (FocusDriver, no tester.tap anywhere).
//   3. Assert glog (<systemTemp>/hibiki_glookup.log) gains this tap's
//      'lookupText:' line (native hit-test -> channel -> Dart routing OK) and
//      within the timeout a HOST-driven 'reveal(box)' (WebView2 actually
//      rendered the card and reported overlaySize), plus isShowing(). A
//      READY-SAFETY-only reveal (blank fallback) FAILS the test - that is the
//      exact regression signature the user kept reporting.
//   4. FAULT INJECTION (the mid-session death matching the user's log): kill
//      the overlay's own WebView2 process tree - scoped strictly to this
//      run's isolated LOCALAPPDATA Hibiki/GlobalLookupWebView2 user-data
//      folder, never the user's real instances - then tap the strip again
//      and require the card to be HOST-rendered again. Without the
//      ProcessFailed self-heal in global_lookup_window.cpp the overlay stays
//      dead-but-"ready" forever (zero host messages, blank READY-SAFETY
//      reveal until app restart) - exactly the user's repeated "still no
//      reaction" reports.
//
// Run (PowerShell, from hibiki/):
//   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
//       integration_test/floating_lyric_tap_lookup_itest.dart

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/lookup/global_lookup_channel.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart'
    show ReaderHibikiSource;
import 'package:hibiki/src/models/app_model.dart' show AppModel;
import 'package:hibiki_audio/hibiki_audio.dart' show AudiobookPlayerController;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel, seedAudiobook;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

// -- user32 FFI (only to post messages at the native strip window; the strip
// is a bare Win32 window with no Flutter equivalent) --

typedef _FindWindowNative = IntPtr Function(
    Pointer<Uint16> lpClassName, Pointer<Uint16> lpWindowName);
typedef _FindWindowDart = int Function(
    Pointer<Uint16> lpClassName, Pointer<Uint16> lpWindowName);
typedef _PostMessageNative = Int32 Function(
    IntPtr hWnd, Uint32 msg, IntPtr wParam, IntPtr lParam);
typedef _PostMessageDart = int Function(
    int hWnd, int msg, int wParam, int lParam);
typedef _GetClientRectNative = Int32 Function(IntPtr hWnd, Pointer<Int32> rect);
typedef _GetClientRectDart = int Function(int hWnd, Pointer<Int32> rect);
typedef _IsWindowVisibleNative = Int32 Function(IntPtr hWnd);
typedef _IsWindowVisibleDart = int Function(int hWnd);
typedef _HeapAllocNative = IntPtr Function(
    IntPtr heap, Uint32 flags, IntPtr bytes);
typedef _HeapAllocDart = int Function(int heap, int flags, int bytes);
typedef _HeapFreeNative = Int32 Function(
    IntPtr heap, Uint32 flags, Pointer<NativeType> p);
typedef _HeapFreeDart = int Function(
    int heap, int flags, Pointer<NativeType> p);
typedef _GetProcessHeapNative = IntPtr Function();
typedef _GetProcessHeapDart = int Function();

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final _FindWindowDart _findWindow =
    _user32.lookupFunction<_FindWindowNative, _FindWindowDart>('FindWindowW');
final _PostMessageDart _postMessage = _user32
    .lookupFunction<_PostMessageNative, _PostMessageDart>('PostMessageW');
final _GetClientRectDart _getClientRect = _user32
    .lookupFunction<_GetClientRectNative, _GetClientRectDart>('GetClientRect');
final _IsWindowVisibleDart _isWindowVisible =
    _user32.lookupFunction<_IsWindowVisibleNative, _IsWindowVisibleDart>(
        'IsWindowVisible');
final _HeapAllocDart _heapAlloc =
    _kernel32.lookupFunction<_HeapAllocNative, _HeapAllocDart>('HeapAlloc');
final _HeapFreeDart _heapFree =
    _kernel32.lookupFunction<_HeapFreeNative, _HeapFreeDart>('HeapFree');
final _GetProcessHeapDart _getProcessHeap =
    _kernel32.lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>(
        'GetProcessHeap');

const int _wmLButtonDown = 0x0201;
const int _wmLButtonUp = 0x0202;
const int _mkLButton = 0x0001;
const int _heapZeroMemory = 0x8;

Pointer<T> _alloc<T extends NativeType>(int byteCount) {
  final int addr = _heapAlloc(_getProcessHeap(), _heapZeroMemory, byteCount);
  if (addr == 0) throw StateError('HeapAlloc failed');
  return Pointer<T>.fromAddress(addr);
}

void _free(Pointer<NativeType> p) => _heapFree(_getProcessHeap(), 0, p);

/// UTF-16 encode a Dart string into native memory (caller frees).
Pointer<Uint16> _toNativeUtf16(String s) {
  final List<int> units = s.codeUnits;
  final Pointer<Uint16> ptr = _alloc<Uint16>((units.length + 1) * 2);
  for (int i = 0; i < units.length; i++) {
    ptr[i] = units[i];
  }
  ptr[units.length] = 0;
  return ptr;
}

/// Find a top-level window by class name (0 = not found).
int _findWindowByClass(String className) {
  final Pointer<Uint16> cls = _toNativeUtf16(className);
  try {
    return _findWindow(cls, Pointer<Uint16>.fromAddress(0));
  } finally {
    _free(cls);
  }
}

/// Client-area size (width, height), or null on failure.
(int, int)? _clientSize(int hwnd) {
  final Pointer<Int32> rect = _alloc<Int32>(16);
  try {
    if (_getClientRect(hwnd, rect) == 0) return null;
    return (rect[2] - rect[0], rect[3] - rect[1]);
  } finally {
    _free(rect);
  }
}

/// Post one left-button down+up pair at client coords (x, y) of [hwnd].
void _postClick(int hwnd, int x, int y) {
  final int lparam = ((y & 0xFFFF) << 16) | (x & 0xFFFF);
  _postMessage(hwnd, _wmLButtonDown, _mkLButton, lparam);
  _postMessage(hwnd, _wmLButtonUp, 0, lparam);
}

File _glogFile() => File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}hibiki_glookup.log');

String _glogTail(int fromLength) {
  final File f = _glogFile();
  if (!f.existsSync()) return '';
  final String all = f.readAsStringSync();
  return fromLength <= all.length ? all.substring(fromLength) : all;
}

/// Kills every msedgewebview2.exe whose command line references [udfPath]
/// (the overlay's isolated user-data folder). Returns the number killed.
Future<int> _killOverlayWebViewProcs(String udfPath) async {
  final String escaped = udfPath.replaceAll("'", "''");
  final String script = '\$p=\'$escaped\'; '
      '\$procs = Get-CimInstance Win32_Process '
      '-Filter "Name=\'msedgewebview2.exe\'" '
      '| Where-Object { \$_.CommandLine -like (\'*\'+\$p+\'*\') }; '
      '\$procs | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }; '
      '(\$procs | Measure-Object).Count';
  final ProcessResult result = await Process.run(
      'powershell', <String>['-NoProfile', '-Command', script]);
  debugPrint('[float-tap] kill script stdout=${result.stdout} '
      'stderr=${result.stderr}');
  return int.tryParse(result.stdout.toString().trim()) ?? -1;
}

Future<AudiobookPlayerController?> _waitForActiveAudiobook(
  WidgetTester tester,
  AppModel appModel, {
  int maxPolls = 80,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final AudiobookPlayerController? c = appModel.audiobookSession.controller;
    if (c != null && c.chapterCueCount > 0) return c;
  }
  return appModel.audiobookSession.controller;
}

bool _webViewShown() =>
    find.byKey(const ValueKey<String>('hoshi_webview')).evaluate().isNotEmpty;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-1268 tapping a word on the Windows floating-lyric strip must open '
    'a REAL (host-rendered) global lookup card, not the blank READY-SAFETY '
    'fallback - including after the overlay WebView2 process tree dies',
    (WidgetTester tester) async {
      await runHibikiItest(
        label: 'float-tap-lookup',
        body: () async {
          app.main();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));

          final AppModel appModel = await readyAppModel(tester);
          await appModel.setExperimentalFocusNavigationEnabled(true);
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          // Enable the floating-lyric intent preference FIRST: session start
          // then shows the native strip (the user path: switch on, open book,
          // strip appears automatically).
          await appModel.setShowFloatingLyric(true);

          final String bookKey =
              await seedAudiobook(tester, title: 'TODO-1268 Float Tap');
          final FocusDriver driver = FocusDriver(tester);

          final List<Finder> navTargets = findPrimaryNavigationTargets();
          if (navTargets.isNotEmpty) {
            await driver.focusWidget(navTargets.first);
            await driver.activate();
            await tester.pump(const Duration(seconds: 1));
          }

          final String entryKey =
              'srt_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
          final String altEntryKey =
              'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
          Finder bookEntry = find.byKey(ValueKey<String>(entryKey));
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (bookEntry.evaluate().isNotEmpty) break;
            final Finder alt = find.byKey(ValueKey<String>(altEntryKey));
            if (alt.evaluate().isNotEmpty) {
              bookEntry = alt;
              break;
            }
          }
          expect(bookEntry, findsOneWidget,
              reason: 'seeded audiobook must appear on the shelf');

          expect(await driver.focusWidget(bookEntry), isTrue,
              reason: 'audiobook card must be reachable by focus');
          await driver.activate();
          await tester.pump(const Duration(seconds: 3));
          for (int i = 0; i < 60; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (_webViewShown()) break;
          }
          expect(_webViewShown(), isTrue,
              reason: 'reader WebView must mount after opening the book');

          final AudiobookPlayerController? controller =
              await _waitForActiveAudiobook(tester, appModel);
          expect(controller, isNotNull,
              reason: 'audiobook session controller must attach');

          // Wait for the native strip window to really exist + be visible.
          int stripHwnd = 0;
          for (int i = 0; i < 60; i++) {
            stripHwnd = _findWindowByClass('HibikiFloatingLyricWindow');
            if (stripHwnd != 0 && _isWindowVisible(stripHwnd) != 0) break;
            await tester.pump(const Duration(milliseconds: 500));
          }
          expect(stripHwnd, isNot(0),
              reason: 'native floating-lyric strip window must exist');
          expect(_isWindowVisible(stripHwnd), isNot(0),
              reason: 'native floating-lyric strip window must be visible');

          // Let the first cue text settle on the strip
          // (displayCueForFloatingLyric serves cue 0 even before playback).
          for (int i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 300));
          }

          final (int, int)? size = _clientSize(stripHwnd);
          expect(size, isNotNull, reason: 'strip client rect must resolve');
          final int w = size!.$1;
          final int h = size.$2;
          debugPrint('[float-tap] strip hwnd=$stripHwnd client=${w}x$h');

          // Baseline: only look at the glog delta from here on.
          final int glogBase =
              _glogFile().existsSync() ? _glogFile().lengthSync() : 0;

          // The text block sits below the controls row (~38/96 dip) and is
          // centered both ways. Try a few candidate points; a glyph hit
          // (CharIndexAt is_inside) fires lookupText. Remember the hit point
          // for the phase-2 post-crash tap.
          const List<List<double>> candidates = <List<double>>[
            <double>[0.50, 0.64],
            <double>[0.50, 0.55],
            <double>[0.50, 0.72],
            <double>[0.45, 0.64],
            <double>[0.55, 0.64],
            <double>[0.50, 0.80],
          ];
          bool lookupSeen = false;
          int hitX = (w * 0.5).round();
          int hitY = (h * 0.64).round();
          for (final List<double> c in candidates) {
            hitX = (w * c[0]).round();
            hitY = (h * c[1]).round();
            _postClick(stripHwnd, hitX, hitY);
            for (int i = 0; i < 20; i++) {
              await tester.pump(const Duration(milliseconds: 100));
              if (_glogTail(glogBase).contains('lookupText: ')) {
                lookupSeen = true;
                break;
              }
            }
            if (lookupSeen) break;
          }
          final String tapLog = _glogTail(glogBase);
          debugPrint('[float-tap] glog after tap:\n$tapLog');
          expect(lookupSeen, isTrue,
              reason: 'a strip word tap must reach Dart as a global '
                  'lookupText (native hit-test -> channel -> controller); '
                  'glog delta: $tapLog');

          // Outcome: a HOST-driven reveal(box) (real render) passes; a
          // READY-SAFETY-only reveal (blank fallback) or no reveal at all is
          // exactly the no-reaction the user reported.
          bool hostReveal = false;
          bool safetyReveal = false;
          for (int i = 0; i < 100; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            final String delta = _glogTail(glogBase);
            hostReveal = delta.contains('reveal(box)');
            safetyReveal = delta.contains('reveal: READY-SAFETY (');
            if (hostReveal || safetyReveal) break;
          }
          final String outcomeLog = _glogTail(glogBase);
          debugPrint('[float-tap] glog outcome:\n$outcomeLog');

          final bool overlayShowing = await GlobalLookupChannel.isShowing();
          final int overlayHwnd =
              _findWindowByClass('HibikiGlobalLookupWindow');
          final bool overlayVisibleNative =
              overlayHwnd != 0 && _isWindowVisible(overlayHwnd) != 0;
          debugPrint('[float-tap] overlay isShowing=$overlayShowing '
              'hwnd=$overlayHwnd visibleNative=$overlayVisibleNative '
              'hostReveal=$hostReveal safetyReveal=$safetyReveal');

          expect(hostReveal, isTrue,
              reason: 'the lookup card must be revealed by the HOST '
                  '(overlaySize -> reveal(box)) - a READY-SAFETY-only reveal '
                  'is the blank-card failure the user reported '
                  '(safetyReveal=$safetyReveal); glog delta: $outcomeLog');
          expect(overlayShowing || overlayVisibleNative, isTrue,
              reason: 'the global lookup overlay window must actually be '
                  'visible after the tap');

          // -- Phase 2 (BUG-693 fault injection): the overlay WebView2
          // process tree dies mid-session (runtime update / GPU reset / OOM /
          // crash - the user's AMD box has a documented popup-WebView crash
          // history). Kill it for real, tap again, and require a REAL
          // host-rendered card again. Without the ProcessFailed self-heal the
          // overlay stays dead-but-"ready" until app restart: zero host
          // messages, blank READY-SAFETY reveal - the user's "still nothing".
          await GlobalLookupChannel.hide();
          await tester.pump(const Duration(seconds: 1));

          final String? localAppData = Platform.environment['LOCALAPPDATA'];
          expect(localAppData, isNotNull,
              reason: 'LOCALAPPDATA must exist (isolated by the runner)');
          final String sep = Platform.pathSeparator;
          final String overlayUdf =
              '$localAppData${sep}Hibiki${sep}GlobalLookupWebView2';
          final int killedCount = await _killOverlayWebViewProcs(overlayUdf);
          debugPrint('[float-tap] killed overlay WebView2 procs: '
              '$killedCount (udf=$overlayUdf)');
          expect(killedCount, greaterThan(0),
              reason: 'fault injection must actually kill the overlay '
                  'WebView2 process tree (0 killed = injection was a no-op)');

          // Let ProcessFailed fire + recovery start.
          for (int i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 300));
          }

          final int glogBase2 =
              _glogFile().existsSync() ? _glogFile().lengthSync() : 0;
          _postClick(stripHwnd, hitX, hitY);

          bool lookupSeen2 = false;
          for (int i = 0; i < 30; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            if (_glogTail(glogBase2).contains('lookupText: ')) {
              lookupSeen2 = true;
              break;
            }
          }
          expect(lookupSeen2, isTrue,
              reason: 'post-crash strip tap must still reach Dart; glog: '
                  '${_glogTail(glogBase2)}');

          bool hostReveal2 = false;
          bool safetyReveal2 = false;
          for (int i = 0; i < 200; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            final String delta = _glogTail(glogBase2);
            hostReveal2 = delta.contains('reveal(box)');
            if (hostReveal2) break;
            safetyReveal2 = delta.contains('reveal: READY-SAFETY (');
          }
          final String outcomeLog2 = _glogTail(glogBase2);
          debugPrint('[float-tap] glog outcome after crash:\n$outcomeLog2');
          expect(hostReveal2, isTrue,
              reason: 'after the overlay WebView2 process tree died, a strip '
                  'tap must SELF-HEAL into a real host-rendered card '
                  '(ProcessFailed recovery). READY-SAFETY-only/blank '
                  '(safetyReveal2=$safetyReveal2) or nothing = the exact '
                  'dead-overlay state the user kept reporting; glog delta: '
                  '$outcomeLog2');

          // Cleanup (isolated app data, but stay tidy anyway).
          await GlobalLookupChannel.hide();
          await appModel.audiobookSession
              .toggleFloatingLyric(currentlyOn: true);
          await appModel.setShowFloatingLyric(false);
          await tester.pump(const Duration(milliseconds: 500));
        },
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
