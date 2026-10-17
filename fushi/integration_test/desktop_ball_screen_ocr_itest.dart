// 桌面应用外悬浮球「截屏识字」真机端到端（Windows）。
//
// 走用户的真实路径，除了「点球上的按钮」那一下：原生球的按钮是裸 Win32 窗口，
// 这里经同一条通道把 `systemBallAction {id: screen_ocr, anchor}` 交给宿主（与原生
// 点按钮发的消息逐字节相同），其后全是真的：
//   1. 屏上先放一个写着「吾輩は猫である」的窗口（PowerShell WinForms，置顶）；
//   2. 宿主收起查词卡 → 原生藏球、截球所在显示器、盖冻结层 `FushiScreenOcrWindow`；
//   3. Windows.Media.Ocr 识别（本机要装日语识别器）→ 原生画行框；
//   4. **真鼠标**（SetCursorPos + mouse_event）点「猫」→ 冻结层报 tap → 宿主命中
//      测试 → 全局查词卡在冻结层之上弹出（Z 序在冻结层之上、isShowing）；
//   5. Esc 关冻结层 → 球恢复、卡收起。
// 每一步截一张真屏（PowerShell CopyFromScreen）留证。
//
// 跑法（PowerShell，在 fushi/ 下，显示器要亮着）：
//   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
//       integration_test/desktop_ball_screen_ocr_itest.dart

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/floating_ball/screen_ocr_picker.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final int Function(Pointer<Utf16>, Pointer<Utf16>) _findWindow = _user32
    .lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowW');
final int Function(int) _isWindowVisible = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsWindowVisible',
    );
final int Function(int, int) _setCursorPos = _user32
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'SetCursorPos',
    );
final void Function(int, int, int, int, int) _mouseEvent = _user32
    .lookupFunction<
      Void Function(Uint32, Uint32, Uint32, Uint32, IntPtr),
      void Function(int, int, int, int, int)
    >('mouse_event');
final int Function(int, int, int, int) _postMessage = _user32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)
    >('PostMessageW');
final int Function(int, int) _getWindow = _user32
    .lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>(
      'GetWindow',
    );

int _window(String className) {
  final Pointer<Utf16> name = className.toNativeUtf16();
  try {
    return _findWindow(name, nullptr);
  } finally {
    calloc.free(name);
  }
}

/// 整个虚拟屏截一张（证据）。PowerShell 不感知 DPI，200% 屏上是缩小图，够看。
Future<void> _screenshot(String path) async {
  await Process.run('powershell', <String>[
    '-NoProfile',
    '-Command',
    'Add-Type -AssemblyName System.Windows.Forms,System.Drawing;'
        r'$b=[System.Windows.Forms.SystemInformation]::VirtualScreen;'
        r'$bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height;'
        r'$g=[System.Drawing.Graphics]::FromImage($bmp);'
        r'$g.CopyFromScreen($b.X,$b.Y,0,0,$bmp.Size);'
        "\$bmp.Save('$path');",
  ]);
  debugPrint('[screen-ocr-itest] screenshot $path');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('点球截屏识字 → 点「猫」→ 查词卡压在冻结层上 → Esc 退出', (WidgetTester tester) async {
    expect(Platform.isWindows, isTrue);
    final String evidence =
        '${Directory.current.path}${Platform.pathSeparator}.codex-test'
        '${Platform.pathSeparator}screen-ocr-itest';
    Directory(evidence).createSync(recursive: true);

    // 1) 屏上放一段日文（置顶、居中、大字）。
    final Process text = await Process.start('powershell', <String>[
      '-NoProfile',
      '-Command',
      'Add-Type -AssemblyName System.Windows.Forms,System.Drawing;'
          r'$f=New-Object System.Windows.Forms.Form;'
          r'$f.Text="ocr-itest-text";$f.TopMost=$true;'
          r'$f.FormBorderStyle="None";$f.BackColor="White";'
          r'$f.StartPosition="CenterScreen";$f.Width=900;$f.Height=220;'
          r'$l=New-Object System.Windows.Forms.Label;$l.Dock="Fill";'
          r'$l.TextAlign="MiddleCenter";$l.ForeColor="Black";'
          r'$l.Font=New-Object System.Drawing.Font("Yu Gothic UI",48);'
          r'$l.Text="吾輩は猫である";$f.Controls.Add($l);'
          r'$f.ShowDialog()',
    ]);
    addTearDown(() => text.kill());

    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    expect(await seedDictionary(tester), isTrue);
    final AppModel appModel = await readyAppModel(tester);
    await GlobalLookupController.instance.start(appModel: appModel);
    expect(GlobalLookupController.instance.isAvailable, isTrue);
    for (int i = 0; i < 80; i++) {
      if (await GlobalLookupChannel.isWebViewReady()) break;
      await tester.pump(const Duration(milliseconds: 250));
    }

    // 原生系统球起来（截屏时要藏它、之后放回来）。
    await appModel.prefsRepo.setFloatingBallSystem(true);
    for (int i = 0; i < 40 && _window('FushiFloatingBallWindow') == 0; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final int ball = _window('FushiFloatingBallWindow');
    expect(ball, isNot(0), reason: '原生系统球没起来');
    await tester.pump(const Duration(seconds: 2));

    // 2) 点球上的「截屏识字」：与原生按钮发的消息相同（anchor = 主屏右缘的球）。
    final ByteData message = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('systemBallAction', <String, Object?>{
        'id': 'screen_ocr',
        'anchor': <double>[1800, 900, 1896, 996],
      }),
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      FloatingBallChannel.channel.name,
      message,
      (_) {},
    );

    ({Rect screen, List<SystemOcrTextLine> lines})? state;
    for (int i = 0; i < 80 && state == null; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      state = debugDesktopScreenOcrState;
    }
    final int overlay = _window('FushiScreenOcrWindow');
    debugPrint(
      '[screen-ocr-itest] overlay=$overlay ballVisible=${_isWindowVisible(ball)} '
      'screen=${state?.screen} lines=${state?.lines.length}',
    );
    for (final SystemOcrTextLine line
        in state?.lines ?? <SystemOcrTextLine>[]) {
      debugPrint('[screen-ocr-itest] line "${line.text}" ${line.rect}');
    }
    await _screenshot('$evidence${Platform.pathSeparator}01-frozen.png');
    expect(overlay, isNot(0), reason: '冻结层没出来');
    expect(_isWindowVisible(ball), 0, reason: '截屏期间球要藏起来');
    expect(state, isNotNull, reason: '识别结果没回来');

    // 3) 找到「猫」所在行，算出这个字在屏幕上的中心，真鼠标点下去。
    final SystemOcrTextLine line = state!.lines.firstWhere(
      (SystemOcrTextLine l) => l.text.contains('猫'),
      orElse: () => throw StateError('没识别出「猫」'),
    );
    final int index = line.text.indexOf('猫');
    final int count = line.text.length;
    final Rect r = line.rect;
    final double cx = r.left + r.width * (index + 0.5) / count;
    final double cy = r.center.dy;
    // 自检：Dart 的命中测试也落在「猫」上。
    final ScreenOcrHit? hit = screenOcrHitTest(
      lines: state.lines,
      point: Offset(cx, cy),
      scale: 1,
    );
    expect(hit?.charIndex, index);
    final int sx = (state.screen.left + cx).round();
    final int sy = (state.screen.top + cy).round();
    debugPrint('[screen-ocr-itest] click 猫 at screen ($sx, $sy)');
    _setCursorPos(sx, sy);
    _mouseEvent(0x0002, 0, 0, 0, 0); // LEFTDOWN
    _mouseEvent(0x0004, 0, 0, 0, 0); // LEFTUP

    bool showing = false;
    for (int i = 0; i < 80 && !showing; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      showing = await GlobalLookupChannel.isShowing();
    }
    await tester.pump(const Duration(seconds: 1));
    await _screenshot('$evidence${Platform.pathSeparator}02-card.png');
    expect(showing, isTrue, reason: '点字后查词卡没弹出');
    // 卡必须压在冻结层之上：从卡往下找，Z 序里应当能碰到冻结层。
    final int card = _window('FushiGlobalLookupWindow');
    bool cardAbove = false;
    for (
      int h = _getWindow(card, 2 /* GW_HWNDNEXT */);
      h != 0;
      h = _getWindow(h, 2)
    ) {
      if (h == overlay) {
        cardAbove = true;
        break;
      }
    }
    debugPrint('[screen-ocr-itest] card=$card cardAboveOverlay=$cardAbove');
    expect(cardAbove, isTrue, reason: '查词卡被冻结层盖住了');
    expect(_window('FushiScreenOcrWindow'), overlay, reason: '点字不该关掉冻结层');

    // 4) Esc 关冻结层：球回来、卡收起。
    _postMessage(overlay, 0x0100 /* WM_KEYDOWN */, 0x1B /* VK_ESCAPE */, 0);
    for (int i = 0; i < 40 && _window('FushiScreenOcrWindow') != 0; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pump(const Duration(seconds: 1));
    await _screenshot('$evidence${Platform.pathSeparator}03-closed.png');
    expect(_window('FushiScreenOcrWindow'), 0, reason: 'Esc 没关掉冻结层');
    expect(_isWindowVisible(ball), isNot(0), reason: '退出后球要放回来');
    expect(await GlobalLookupChannel.isShowing(), isFalse, reason: '卡要收起');
    expect(debugDesktopScreenOcrState, isNull);

    await appModel.prefsRepo.setFloatingBallSystem(false);
  });
}
