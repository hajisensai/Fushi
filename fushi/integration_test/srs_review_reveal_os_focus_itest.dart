// 复习页「空格翻面后键盘失灵」的 OS 焦点实测（Windows runner，手动跑）。
//
// 种 Fushi 原生卡片与整面 WebView 卡片两个牌组 → 打开复习页 → 用**真投递**的空格
// （PostMessage 给本线程 OS 焦点窗，不抢用户前台）翻面、再按空格评「良好」，每一步读
// OS 键盘焦点 HWND（GetGUIThreadInfo）与 Flutter primary focus。结果打 `[srs-reveal]` 行。
//
//   .\tool\run_windows_itest.ps1 integration_test/srs_review_reveal_os_focus_itest.dart
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:fushi/src/focus/main_window_focus_gate.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';

import 'package:ffi/ffi.dart';
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
final int Function(int, int, int, int) _postMessage = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)
    >('PostMessageW');

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

const int _gwlExStyle = -20;
const int _wsExNoActivate = 0x08000000;
const int _vkMenu = 0x12;
const int _keyeventfKeyUp = 0x0002;
const int _vkSpace = 0x20;
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

String _describe(int hwnd) {
  if (hwnd <= 0) return 'hwnd=$hwnd';
  final List<String> chain = <String>[];
  int h = hwnd;
  for (int i = 0; i < 6 && h != 0; i++) {
    chain.add(_className(h));
    h = _getAncestor(h, 1);
  }
  return 'hwnd=0x${hwnd.toRadixString(16)} chain=${chain.join(" < ")}';
}

void _log(String line) {
  debugPrint(line);
  final Directory? docs = fushiTestDirectory('app-documents');
  if (docs == null) return;
  File(
    p.join(docs.path, 'srs_reveal_probe.txt'),
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

/// 0.6 s、440 Hz 的 16-bit 单声道 WAV（卡面自动播放用的真实音频）。
Uint8List _toneWav() {
  const int rate = 8000;
  const int n = 4800;
  final ByteData bd = ByteData(44 + n * 2);
  void ascii(int o, String s) {
    for (int i = 0; i < s.length; i++) {
      bd.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bd.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, rate, Endian.little);
  bd.setUint32(28, rate * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, n * 2, Endian.little);
  for (int i = 0; i < n; i++) {
    final double v = math.sin(2 * math.pi * 440 * i / rate) * 0.05;
    bd.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return bd.buffer.asUint8List();
}

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('复习页：真空格翻面后再按空格评分', (WidgetTester tester) async {
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
    final SrsMediaStore media = (await container.read(
      srsMediaStoreProvider.future,
    ))!;
    final String audio = await media.store('reveal.wav', _toneWav());
    _log('[srs-reveal] audio=$audio');
    final String fushiDeck = await store.createDeck('reveal-fushi');
    final String webDeck = await store.createDeck('reveal-web');
    for (int i = 0; i < 22; i++) {
      final Map<String, String> fields = <String, String>{
        ...srsSampleCardFields(),
        'Expression': '単語$i',
        'ExpressionAudio': '[sound:$audio]',
        'SentenceAudio': '[sound:$audio]',
      };
      await store.createNote(
        noteTypeId: store.fushiCardNoteTypeId,
        deckId: fushiDeck,
        createdAt: 1700000000000 + i,
        fieldsById: <String, String>{
          for (final MapEntry<String, String> e in fields.entries)
            srsFushiCardFieldId(uid, e.key): e.value,
        },
      );
      await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        deckId: webDeck,
        createdAt: 1700000001000 + i,
        fieldsById: <String, String>{
          srsLapisFieldId(uid, 'Expression'): '言葉$i',
          srsLapisFieldId(uid, 'MainDefinition'): 'word $i',
          srsLapisFieldId(uid, 'Sentence'): '<b>言葉$i</b>です',
          srsLapisFieldId(uid, 'ExpressionAudio'): '[sound:$audio]',
        },
      );
    }
    container.read(srsRevisionProvider.notifier).state++;

    final int main = _mainWindow();
    final int thread = _getWindowThreadProcessId(main, nullptr);
    expect(main, isNot(0), reason: '应找到本进程主窗');

    bool flipped() => find.byType(SrsRatingButton).evaluate().isNotEmpty;

    const bool foreground = bool.fromEnvironment('SRS_REVEAL_FOREGROUND');
    final int previousForeground = _getForegroundWindow();
    if (foreground) {
      // 用户真实状态：主窗在前台、焦点闸门按真实前台判据工作（不走隐藏运行器豁免）。
      _setWindowLongPtr(
        main,
        _gwlExStyle,
        _getWindowLongPtr(main, _gwlExStyle) & ~_wsExNoActivate,
      );
      _keybdEvent(_vkMenu, 0, 0, 0);
      _keybdEvent(_vkMenu, 0, _keyeventfKeyUp, 0);
      _setForegroundWindow(main);
      DesktopForegroundGuard.debugHiddenWindowsRunner = false;
      MainWindowForegroundWatcher.instance.sync();
      addTearDown(() {
        DesktopForegroundGuard.debugHiddenWindowsRunner = null;
        if (previousForeground != 0) _setForegroundWindow(previousForeground);
      });
    }

    void focusLine(String label) {
      final int f = _focusOfThread(thread);
      final FocusNode? primary = FocusManager.instance.primaryFocus;
      final int fg = _getForegroundWindow();
      _log(
        '[srs-reveal] $label fgMain=${fg == main} fg=${_describe(fg)} '
        'gateOpen=${mainWindowForegroundNotifier.value} os=${_describe(f)} '
        'flutterPrimary=${primary?.debugLabel} ${primary?.runtimeType} '
        'ctx=${primary?.context?.widget.runtimeType} '
        'pressed=${HardwareKeyboard.instance.logicalKeysPressed.map((LogicalKeyboardKey k) => k.keyLabel).toList()}',
      );
    }

    bool keyLog(KeyEvent e) {
      _log(
        '[srs-reveal]   key ${e.runtimeType} ${e.logicalKey.keyLabel} '
        'synth=${e.synthesized} primary=${FocusManager.instance.primaryFocus?.debugLabel}',
      );
      return false;
    }

    HardwareKeyboard.instance.addHandler(keyLog);
    addTearDown(() => HardwareKeyboard.instance.removeHandler(keyLog));

    String injectSpace() {
      final int f = _focusOfThread(thread);
      _postMessage(f, _wmKeyDown, _vkSpace, 0x00390001);
      _postMessage(f, _wmKeyUp, _vkSpace, 0xC0390001);
      return _className(f);
    }

    final Map<String, String> verdicts = <String, String>{};
    for (final (String mode, String deck, bool hover)
        in <(String, String, bool)>[
          ('fushi', fushiDeck, false),
          ('web', webDeck, false),
          if (!foreground) ...<(String, String, bool)>[
            ('fushi-hover', fushiDeck, true),
            ('web-hover', webDeck, true),
          ],
        ]) {
      TestGesture? mouse;
      unawaited(
        appModel.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) =>
                SrsReviewPage(deckId: deck, deckName: mode),
          ),
        ),
      );
      await _pumpFor(tester, const Duration(seconds: 5));
      focusLine('$mode 00-front');
      final List<String> steps = <String>[];
      if (hover) {
        // 鼠标停在卡面中央（用户读卡时指针常驻卡面），翻面前后不动。
        final Rect card = tester.getRect(
          find.byKey(const ValueKey<String>('srs-card-surface')),
        );
        mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: card.center + const Offset(0, 60));
        await mouse.moveTo(card.center + const Offset(0, 40));
        await _pumpFor(tester, const Duration(milliseconds: 500));
      }
      for (int round = 0; round < (foreground ? 4 : 10); round++) {
        final String via1 = injectSpace();
        await _pumpFor(tester, const Duration(milliseconds: 150));
        focusLine('$mode r$round 01-reveal+150ms');
        await _pumpFor(tester, const Duration(milliseconds: 2000));
        final bool shown = flipped();
        focusLine('$mode r$round 02-reveal+2s shown=$shown via=$via1');
        await captureFlutterFrame(tester, 'reveal-$mode-r$round-back');
        final String via2 = injectSpace();
        await _pumpFor(tester, const Duration(milliseconds: 2500));
        final bool advanced = !flipped();
        focusLine('$mode r$round 03-grade advanced=$advanced via=$via2');
        steps.add('r$round shown=$shown advanced=$advanced');
        if (!shown || !advanced) _log('[srs-reveal] $mode r$round MISS');
      }
      await mouse?.removePointer();
      verdicts[mode] = steps.join(', ');
      appModel.navigatorKey.currentState!.pop();
      await _pumpFor(tester, const Duration(seconds: 1));
    }
    _log('[srs-reveal] VERDICTS $verdicts');
  });
}
