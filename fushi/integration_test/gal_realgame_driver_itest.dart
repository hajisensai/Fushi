// ignore_for_file: avoid_print
// galgame 真机交互驱动（Windows only）。
//
// 在真实 fushi.exe 测试宿主里启动完整 App，然后轮询 `GALDRIVER_DIR/cmd.txt` 执行指令，
// 把结果追加到 `GALDRIVER_DIR/out.txt`，截图落 `GALDRIVER_DIR/shot_<n>.png`。用于让
// 代理在真游戏上逐引擎走「拉起 → 点字弹卡 → 点外关闭不推进 → Shift 悬浮 → 制卡」。
//
// 指令（一行一条，`#` 开头忽略）：
//   launch <exe路径>            拉起游戏并开始捕获（走与游戏页同一条 launchGame 路径，转区 auto）
//   launchoff <exe路径>         同上但转区档位 off（库里多数游戏的设置）
//   attach <hwnd> <pid> [title]  对已运行的游戏附着捕获
//   thread <id>                 选择文本线程
//   state                       会话状态 + 最近台词 + attached 状态
//   events [n]                  最近 n 条会话事件
//   profile                     attached 表面 profile / 风险确认请求
//   accept                      确认当前 exe 的裸左击风险（同工作台按钮）
//   calibrate <l> <t> <w> <h> [fontPerH] [lineHeight] [align] [valign]
//                               用给定归一化文本框 + 排版直接提交一份 attached 校准
//                               profile（走 handleCalibrationCommitted，跳过三点探针），
//                               让 needsCalibration → activeAttached，从而可点字/悬浮查词。
//                               align∈{left,center,right}，valign∈{top,center,bottom}。
//   mine                        对「当前会话最新台词行」制卡（走与浮窗➕同一条采集链：
//                               封面按 galMiningImageMode/格式偏好、句子音频按会话音频后端），
//                               打印 noteId 与产出的图/音字段，供 AnkiConnect 取证。
//   lines [n]                   最近 n 条台词
//   shot game|card|hwnd:<n>     WGC 抓窗口像素（与制卡截图同一通道）
//   windows                     枚举 FushiGlobalLookupWindow 类窗口的可见性/矩形
//   click <x> <y>               屏幕坐标左键单击（SendInput）
//   move <x> <y>                移动光标
//   shiftmove <x> <y> [ms]      按住 Shift 移到 (x,y) 抖动一下，停 ms 后松开
//   key <vk> [ms]               按下并释放虚拟键
//   wait <ms>
//   stop                        停止捕获
//   quit                        退出测试
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_attached_text_controller.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_helper_installer.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

// ── Win32 ────────────────────────────────────────────────────────────────────

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final int Function(int, int) _setCursorPos = _user32.lookupFunction<
    Int32 Function(Int32, Int32), int Function(int, int)>('SetCursorPos');
final int Function(int, Pointer<Uint8>, int) _sendInput =
    _user32.lookupFunction<Uint32 Function(Uint32, Pointer<Uint8>, Int32),
        int Function(int, Pointer<Uint8>, int)>('SendInput');
final int Function(int, int, Pointer<Utf16>, Pointer<Utf16>) _findWindowEx =
    _user32.lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(
            int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final int Function(int) _isWindowVisible =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'IsWindowVisible');
final int Function(int, Pointer<Int32>) _getWindowRect = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Int32>),
    int Function(int, Pointer<Int32>)>('GetWindowRect');
final int Function() _getForegroundWindow = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');

const int _inputSize = 40; // x64: DWORD type + 4 pad + 32-byte union
const int _inputMouse = 0;
const int _inputKeyboard = 1;
const int _mouseMove = 0x0001;
const int _mouseLeftDown = 0x0002;
const int _mouseLeftUp = 0x0004;
const int _keyUp = 0x0002;

void _sendMouse(int flags, {int dx = 0, int dy = 0}) {
  final Pointer<Uint8> buffer = calloc<Uint8>(_inputSize);
  try {
    final ByteData view = buffer.asTypedList(_inputSize).buffer.asByteData();
    view.setUint32(0, _inputMouse, Endian.little);
    view.setInt32(8, dx, Endian.little);
    view.setInt32(12, dy, Endian.little);
    view.setUint32(16, 0, Endian.little);
    view.setUint32(20, flags, Endian.little);
    _sendInput(1, buffer, _inputSize);
  } finally {
    calloc.free(buffer);
  }
}

void _sendKey(int vk, {required bool up}) {
  final Pointer<Uint8> buffer = calloc<Uint8>(_inputSize);
  try {
    final ByteData view = buffer.asTypedList(_inputSize).buffer.asByteData();
    view.setUint32(0, _inputKeyboard, Endian.little);
    view.setUint16(8, vk, Endian.little);
    view.setUint16(10, 0, Endian.little);
    view.setUint32(12, up ? _keyUp : 0, Endian.little);
    _sendInput(1, buffer, _inputSize);
  } finally {
    calloc.free(buffer);
  }
}

Future<void> _clickAt(int x, int y) async {
  _setCursorPos(x, y);
  await Future<void>.delayed(const Duration(milliseconds: 60));
  _sendMouse(_mouseMove, dx: 1, dy: 0);
  await Future<void>.delayed(const Duration(milliseconds: 60));
  _sendMouse(_mouseLeftDown);
  await Future<void>.delayed(const Duration(milliseconds: 70));
  _sendMouse(_mouseLeftUp);
}

List<int> _rectOf(int hwnd) {
  final Pointer<Int32> rect = calloc<Int32>(4);
  try {
    if (_getWindowRect(hwnd, rect) == 0) return const <int>[];
    return <int>[rect[0], rect[1], rect[2], rect[3]];
  } finally {
    calloc.free(rect);
  }
}

List<({int hwnd, bool visible, List<int> rect})> _lookupWindows() {
  final List<({int hwnd, bool visible, List<int> rect})> out =
      <({int hwnd, bool visible, List<int> rect})>[];
  final Pointer<Utf16> cls = 'FushiGlobalLookupWindow'.toNativeUtf16();
  try {
    int prev = 0;
    for (int i = 0; i < 16; i++) {
      final int h = _findWindowEx(0, prev, cls, nullptr);
      if (h == 0) break;
      out.add((hwnd: h, visible: _isWindowVisible(h) != 0, rect: _rectOf(h)));
      prev = h;
    }
  } finally {
    calloc.free(cls);
  }
  return out;
}

Future<bool> _ensureInjectorFor(WidgetTester tester, bool is32Bit) {
  final BuildContext context = tester.element(find.byType(Navigator).first);
  return GalgameHelperInstaller().ensureInjector(
    is32Bit: is32Bit,
    context: context,
  );
}

// ── driver ───────────────────────────────────────────────────────────────────

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('galgame 真机交互驱动', (WidgetTester tester) async {
    final String? driverDir = Platform.environment['GALDRIVER_DIR'];
    if (driverDir == null || driverDir.isEmpty) {
      print('GALDRIVER SKIP: 缺 GALDRIVER_DIR');
      return;
    }
    final Directory dir = Directory(driverDir)..createSync(recursive: true);
    final File cmdFile = File(p.join(dir.path, 'cmd.txt'));
    final File outFile = File(p.join(dir.path, 'out.txt'));
    int seq = 0;
    int shotSeq = 0;
    void out(String message) {
      outFile.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    }

    await launchFushiTestApp();
    final bool home = await waitForHome(tester);
    out('home=$home');
    final GalHookSessionController session = GalHookSessionController.instance;
    final TexthookerService text = TexthookerService.instance;

    String describeState() {
      final GalHookSessionState s = session.state;
      final StringBuffer sb = StringBuffer()
        ..write('phase=${s.phase.name} ')
        ..write('window=${s.boundWindow?.hwnd}/${s.boundWindow?.title} ')
        ..write('pid=${s.gamePid} audio=${s.audioBackend.name} ')
        ..write('fallback=${s.fallbackReason} err=${s.lastError} ')
        ..write(
            'attached=${GalHookTextOverlayController.instance.attachedText.status.name} ')
        ..write('lines=${text.entries.length}');
      return sb.toString();
    }

    String describeLines(int n) {
      final List<TexthookerLineEntry> entries = text.entries;
      final Iterable<TexthookerLineEntry> tail =
          entries.length > n ? entries.sublist(entries.length - n) : entries;
      return tail
          .map((TexthookerLineEntry e) =>
              '${e.id} audio=${e.audioStatus.name}/${e.audioBackend}/'
              '${e.audioDurationMs}ms reason=${e.fallbackReason} '
              'text=${e.text.replaceAll('\n', '⏎')}')
          .join('\n    ');
    }

    bool quit = false;
    final Stopwatch idle = Stopwatch()..start();
    while (!quit && idle.elapsed < const Duration(minutes: 40)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (!cmdFile.existsSync()) continue;
      idle.reset();
      String raw;
      try {
        raw = cmdFile.readAsStringSync();
        cmdFile.deleteSync();
      } catch (_) {
        continue;
      }
      for (final String line in raw.split('\n')) {
        final String cmd = line.trim();
        if (cmd.isEmpty || cmd.startsWith('#')) continue;
        seq++;
        final List<String> parts = cmd.split(RegExp(r'\s+'));
        final String op = parts.first;
        try {
          switch (op) {
            case 'launch':
            case 'launchoff':
              // launch <exe> 走 auto 转区档；launchoff <exe> 走 off（用户库里除 9-nine
              // 外都是 off，复现原始路径必须按库里的档位来）。
              final bool localeOff = op == 'launchoff';
              final String exe = cmd.substring(op.length).trim();
              final bool is32 =
                  await EngineHookGalAudioSource.exeIs32Bit(exe) ?? false;
              final bool ensured = await _ensureInjectorFor(tester, is32);
              out('#$seq launch ensured=$ensured is32=$is32');
              final GalHookLaunchResult result = await session.launchGame(
                exe,
                workdir: p.dirname(exe),
                gameTitle: p.basenameWithoutExtension(exe),
                japaneseLocaleMode: localeOff
                    ? GalJapaneseLocaleMode.off
                    : kGalDefaultJapaneseLocaleMode,
              );
              out('#$seq launch launched=${result.launched} result=$result');
              out('#$seq ${describeState()}');
            case 'attach':
              // attach <hwnd> <pid> [title]: 对已在运行的游戏附着捕获（同游戏页「捕获窗口」）。
              final int hwnd = int.parse(parts[1]);
              final int pid = int.parse(parts[2]);
              final String title =
                  parts.length > 3 ? parts.sublist(3).join(' ') : 'attached';
              await session.startAttachedCapture(
                ExternalWindowInfo(hwnd: hwnd, pid: pid, title: title),
              );
              out('#$seq attach ${describeState()}');
            case 'events':
              final int n = parts.length > 1 ? int.parse(parts[1]) : 12;
              final List<GalHookEvent> events = session.events;
              final Iterable<GalHookEvent> tail = events.length > n
                  ? events.sublist(events.length - n)
                  : events;
              final String rendered = tail
                  .map((GalHookEvent e) =>
                      '${e.severity.name} ${e.stage}/${e.code} '
                      '${e.summary} ${e.details}')
                  .join('\n    ');
              out('#$seq events:\n    $rendered');
            case 'profile':
              final GalAttachedTextController attached =
                  GalHookTextOverlayController.instance.attachedText;
              out('#$seq profile status=${attached.status.name} '
                  'profile=${attached.profile?.toJson()} '
                  'request=${attached.unsafeRiskAcceptanceRequest?.exePath}/'
                  '${attached.unsafeRiskAcceptanceRequest?.exeSha256}');
            case 'accept':
              final GalAttachedTextController attached =
                  GalHookTextOverlayController.instance.attachedText;
              final GalAttachedUnsafeRiskAcceptanceRequest? request =
                  attached.unsafeRiskAcceptanceRequest;
              if (request == null) {
                out('#$seq accept: no pending request');
                break;
              }
              final bool accepted =
                  await attached.acceptUnsafeRiskAndRetry(request);
              out('#$seq accept=$accepted ${describeState()}');
            case 'calibrate':
              // calibrate <l> <t> <w> <h> [fontPerH] [lineHeight] [align] [valign]
              // 直接提交一份 attached 校准 profile，让 needsCalibration → activeAttached。
              final GalAttachedTextController attached =
                  GalHookTextOverlayController.instance.attachedText;
              final GalAttachedSurfaceTarget? target = attached.target;
              final GalLookupReferenceClientV1? client = attached.currentClient;
              if (target == null || client == null) {
                out('#$seq calibrate: no target/client '
                    '(status=${attached.status.name})');
                break;
              }
              double at(int i, double fallback) => parts.length > i
                  ? (double.tryParse(parts[i]) ?? fallback)
                  : fallback;
              String strAt(int i, String fallback) =>
                  parts.length > i ? parts[i] : fallback;
              final GalLookupNormalizedRectV1 bodyRect =
                  GalLookupNormalizedRectV1(
                left: at(1, 0.08),
                top: at(2, 0.68),
                width: at(3, 0.84),
                height: at(4, 0.24),
              );
              final GalLookupTextLayoutV1 layout = GalLookupTextLayoutV1(
                fontFamily: 'Yu Gothic',
                fontSizePerClientHeight: at(5, 0.045),
                letterSpacingPerClientHeight: 0,
                lineHeight: at(6, 1.6),
                textAlign: strAt(7, 'left'),
                verticalAlign: strAt(8, 'top'),
              );
              await attached.handleCalibrationCommitted(
                GalAttachedCalibrationEvent(
                  target: target,
                  bodyRect: bodyRect,
                  referenceClient: client,
                  layout: layout,
                  riskAccepted: true,
                  calibrationProbeMask: 7,
                ),
              );
              await tester.pump(const Duration(milliseconds: 300));
              out('#$seq calibrate committed rect=$bodyRect '
                  'font=${layout.fontSizePerClientHeight} '
                  'lh=${layout.lineHeight} -> ${describeState()}');
              out('#$seq profile=${attached.profile?.toJson()}');
            case 'mine':
              final ProviderContainer container = ProviderScope.containerOf(
                tester.element(find.byType(MaterialApp).first),
              );
              final AppModel appModel = container.read(appProvider);
              final List<TexthookerLineEntry> lines =
                  session.selectedSessionLines;
              if (lines.isEmpty) {
                out('#$seq mine: no session lines');
                break;
              }
              final TexthookerLineEntry entry = lines.last;
              final BaseAnkiRepository repo =
                  appModel.platformServices.createAnkiRepository();
              final GalHookMiningCoordinator coordinator =
                  GalHookMiningCoordinator();
              final GalHookMiningResult result = await coordinator.mineLine(
                lineId: entry.id,
                fields: <String, String>{'Sentence': entry.text},
                sentenceOverride: entry.text,
                compression: MiningMediaCompression.resolve(
                  imageTier: appModel.miningImageQuality,
                  audioTier: appModel.miningAudioQuality,
                  format: appModel.galMiningAnimatedFormat,
                ),
                repo: repo,
                imageMode: appModel.galMiningImageMode,
                animatedFormat: appModel.galMiningAnimatedFormat,
                stillFormat: appModel.galMiningStillFormat,
              );
              out('#$seq mine lineId=${entry.id} '
                  'imageMode=${appModel.galMiningImageMode.name} '
                  'animated=${appModel.galMiningAnimatedFormat.name} '
                  'result=${result.outcome?.result.name} '
                  'noteId=${result.outcome?.noteId} '
                  'aborted=${result.aborted} success=${result.success} '
                  'audioMissing=${result.sentenceAudioMissing} '
                  'audioWarning=${result.outcome?.audioWarning} '
                  'audioFallbackDisabled=${result.audioFallbackDisabled} '
                  'degradedToStill=${result.degradedToStill} '
                  'failureReason=${result.failureReason} '
                  'text=${entry.text.replaceAll('\n', '⏎')}');
            case 'thread':
              await session.selectTextThread(int.parse(parts[1]));
              out('#$seq thread ok ${describeState()}');
            case 'state':
              out('#$seq ${describeState()}');
            case 'lines':
              final int n = parts.length > 1 ? int.parse(parts[1]) : 5;
              out('#$seq lines:\n    ${describeLines(n)}');
            case 'windows':
              final StringBuffer sb =
                  StringBuffer('#$seq windows fg=${_getForegroundWindow()}');
              for (final w in _lookupWindows()) {
                sb.write(
                    '\n    hwnd=${w.hwnd} visible=${w.visible} rect=${w.rect}');
              }
              out(sb.toString());
            case 'shot':
              final String target = parts.length > 1 ? parts[1] : 'game';
              int? hwnd;
              if (target == 'game') {
                hwnd = session.state.boundWindow?.hwnd;
              } else if (target == 'card') {
                for (final w in _lookupWindows()) {
                  if (w.visible && w.rect.isNotEmpty && w.rect[0] < 3000) {
                    hwnd = w.hwnd;
                  }
                }
              } else if (target.startsWith('hwnd:')) {
                hwnd = int.parse(target.substring(5));
              }
              if (hwnd == null) {
                out('#$seq shot $target: no hwnd');
                break;
              }
              final WindowCaptureResult cap =
                  await WindowCaptureChannel.captureWindow(hwnd);
              if (!cap.ok) {
                out('#$seq shot $target hwnd=$hwnd FAILED ${cap.error}');
                break;
              }
              shotSeq++;
              final File png = File(p.join(dir.path, 'shot_$shotSeq.png'));
              png.writeAsBytesSync(cap.pngBytes!, flush: true);
              out('#$seq shot $target hwnd=$hwnd rect=${_rectOf(hwnd)} -> ${png.path}');
            case 'click':
              await _clickAt(int.parse(parts[1]), int.parse(parts[2]));
              out('#$seq click ${parts[1]},${parts[2]}');
            case 'move':
              _setCursorPos(int.parse(parts[1]), int.parse(parts[2]));
              _sendMouse(_mouseMove, dx: 1);
              out('#$seq move');
            case 'shiftmove':
              final int ms = parts.length > 3 ? int.parse(parts[3]) : 600;
              _sendKey(0x10, up: false);
              await Future<void>.delayed(const Duration(milliseconds: 80));
              _setCursorPos(int.parse(parts[1]), int.parse(parts[2]));
              _sendMouse(_mouseMove, dx: 1);
              await Future<void>.delayed(const Duration(milliseconds: 40));
              _sendMouse(_mouseMove, dx: -1);
              await Future<void>.delayed(Duration(milliseconds: ms));
              _sendKey(0x10, up: true);
              out('#$seq shiftmove ${parts[1]},${parts[2]} held=$ms');
            case 'key':
              final int vk = int.parse(parts[1]);
              final int ms = parts.length > 2 ? int.parse(parts[2]) : 60;
              _sendKey(vk, up: false);
              await Future<void>.delayed(Duration(milliseconds: ms));
              _sendKey(vk, up: true);
              out('#$seq key $vk');
            case 'wait':
              final int ms = int.parse(parts[1]);
              final Stopwatch sw = Stopwatch()..start();
              while (sw.elapsedMilliseconds < ms) {
                await tester.pump(const Duration(milliseconds: 100));
              }
              out('#$seq waited $ms');
            case 'stop':
              await session.stopCapture();
              out('#$seq stopped ${describeState()}');
            case 'quit':
              quit = true;
              out('#$seq quit');
            default:
              out('#$seq unknown: $cmd');
          }
        } catch (error, stack) {
          out('#$seq ERROR $cmd: $error\n$stack');
        }
        File(p.join(dir.path, 'done.txt')).writeAsStringSync('$seq');
      }
    }
    try {
      await session.stopCapture();
    } catch (_) {}
    out('exit');
  }, timeout: const Timeout(Duration(minutes: 45)));
}
