// 官网（fushi.moe）预览录屏的录制件：找到本测试自己的 Flutter 主窗口客户区（物理像素）、
// 用 ffmpeg 的 ddagrab（桌面复制）录那块区域、在 app 根 Overlay 上画一枚假指针。
//
// 为什么录桌面而不是 captureFlutterFrame：查词弹窗是 WebView2 纹理，
// OffsetLayer.toImage 抓不到（见 helpers/observe_capture.dart）。桌面复制拿的是
// DWM 合成后的真像素，弹窗 / 对话框 / 视频纹理都在里面。前提是窗口在屏上且不被
// 遮挡——由 runner 的 FUSHI_TEST_TOPMOST="x,y,w,h" 置顶停靠保证（不抢焦点）。
//
// 为什么指针是画出来的：用户拍板录制时不动真鼠标（2026-10-27），ddagrab 用
// draw_mouse=0 录，指针由 [SitePreviewCursor] 画在 app 自己的根 Overlay 最上层，
// 与画面天然同步，不用后期对时间轴。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// 屏幕上的一块物理像素矩形（桌面坐标，主显示器左上为原点）。
@immutable
class PhysicalRect {
  const PhysicalRect(this.x, this.y, this.width, this.height);

  final int x;
  final int y;
  final int width;
  final int height;

  /// 偶数化：libx264 + yuv420p 要求宽高为偶数。
  PhysicalRect even() => PhysicalRect(x, y, width & ~1, height & ~1);

  @override
  String toString() => '$x,$y ${width}x$height';
}

typedef _FindWindowExNative =
    IntPtr Function(
      IntPtr parent,
      IntPtr after,
      Pointer<Utf16> cls,
      Pointer<Utf16> title,
    );
typedef _FindWindowExDart =
    int Function(
      int parent,
      int after,
      Pointer<Utf16> cls,
      Pointer<Utf16> title,
    );
typedef _GetPidNative = Uint32 Function(IntPtr hwnd, Pointer<Uint32> pid);
typedef _GetPidDart = int Function(int hwnd, Pointer<Uint32> pid);
typedef _RectNative = Int32 Function(IntPtr hwnd, Pointer<Int32> rect);
typedef _RectDart = int Function(int hwnd, Pointer<Int32> rect);
typedef _IsVisibleNative = Int32 Function(IntPtr hwnd);
typedef _IsVisibleDart = int Function(int hwnd);

/// 本进程可见的 `FLUTTER_RUNNER_WIN32_WINDOW` 主窗口的客户区（物理像素）。
///
/// 只认类名为 FLUTTER_RUNNER_WIN32_WINDOW 且属于本进程的可见窗口——同类名的还有
/// 用户自己开着的安装版 / 热重载实例，按进程号筛掉。找不到返回 null。
PhysicalRect? findOwnMainWindowClientRect() {
  if (!Platform.isWindows) return null;
  final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
  final _FindWindowExDart findWindowEx = user32
      .lookupFunction<_FindWindowExNative, _FindWindowExDart>('FindWindowExW');
  final _GetPidDart getPid = user32.lookupFunction<_GetPidNative, _GetPidDart>(
    'GetWindowThreadProcessId',
  );
  final _RectDart getClientRect = user32.lookupFunction<_RectNative, _RectDart>(
    'GetClientRect',
  );
  final _RectDart clientToScreen = user32
      .lookupFunction<_RectNative, _RectDart>('ClientToScreen');
  final _IsVisibleDart isVisible = user32
      .lookupFunction<_IsVisibleNative, _IsVisibleDart>('IsWindowVisible');

  final Pointer<Utf16> cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final Pointer<Uint32> pidOut = calloc<Uint32>();
  final Pointer<Int32> rect = calloc<Int32>(4);
  final Pointer<Int32> origin = calloc<Int32>(2);
  try {
    int hwnd = 0;
    while (true) {
      hwnd = findWindowEx(0, hwnd, cls, nullptr);
      if (hwnd == 0) return null;
      getPid(hwnd, pidOut);
      if (pidOut.value != pid || isVisible(hwnd) == 0) continue;
      if (getClientRect(hwnd, rect) == 0) continue;
      origin[0] = 0;
      origin[1] = 0;
      if (clientToScreen(hwnd, origin) == 0) continue;
      return PhysicalRect(
        origin[0],
        origin[1],
        rect[2] - rect[0],
        rect[3] - rect[1],
      );
    }
  } finally {
    calloc.free(cls);
    calloc.free(pidOut);
    calloc.free(rect);
    calloc.free(origin);
  }
}

/// 一段 ffmpeg ddagrab 录屏。[stop] 经 stdin 发 `q` 让 ffmpeg 正常收尾（写完 moov）。
class SitePreviewRecording {
  SitePreviewRecording._(this._process, this.output, this._log, this.startedAt);

  final Process _process;
  final File output;
  final StringBuffer _log;

  /// 发出 ffmpeg 命令的时刻；场景时间线（音轨对齐）以它为零点。
  final DateTime startedAt;

  /// 在 [rect] 上开录，[fps] 帧率，输出无损级 H.264（后期再缩放 / 压缩）。
  static Future<SitePreviewRecording> start({
    required PhysicalRect rect,
    required File output,
    int fps = 30,
  }) async {
    final PhysicalRect r = rect.even();
    await output.parent.create(recursive: true);
    final StringBuffer log = StringBuffer();
    final Process process = await Process.start('ffmpeg', <String>[
      '-hide_banner',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'ddagrab=output_idx=0:framerate=$fps:draw_mouse=0'
          ':offset_x=${r.x}:offset_y=${r.y}:video_size=${r.width}x${r.height}'
          ',hwdownload,format=bgra',
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '12',
      '-pix_fmt',
      'yuv420p',
      output.path,
    ]);
    process.stderr
        .transform(utf8.decoder)
        .listen((String s) => log.write(s), onError: (_) {});
    process.stdout.drain<void>().ignore();
    final SitePreviewRecording rec = SitePreviewRecording._(
      process,
      output,
      log,
      DateTime.now(),
    );
    // ddagrab 起来要几百毫秒；等它真开始出帧（stderr 打出 frame= 进度）再返回，
    // 免得场景前几步没录进去。
    final Stopwatch sw = Stopwatch()..start();
    while (!log.toString().contains('frame=') && sw.elapsed.inSeconds < 10) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    debugPrint(
      '[site-preview] recording ${output.path} rect=$r '
      'ready=${log.toString().contains('frame=')}',
    );
    return rec;
  }

  /// 停录并等 ffmpeg 退出；返回退出码（0 = 文件完整）。
  Future<int> stop() async {
    _process.stdin.write('q');
    await _process.stdin.flush();
    await _process.stdin.close();
    final int code = await _process.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
    if (code != 0) {
      debugPrint('[site-preview] ffmpeg exit=$code\n$_log');
    }
    return code;
  }
}

/// 画在根 Overlay 最上层的假指针。弹窗 / 对话框也是后插入的 Overlay 条目，
/// 每次动作前 [raise] 一次，指针始终压在它们上面。
class SitePreviewCursor {
  SitePreviewCursor._(this._overlay);

  final OverlayState _overlay;
  bool _inserted = false;
  final ValueNotifier<Offset> _position = ValueNotifier<Offset>(Offset.zero);
  final ValueNotifier<double> _press = ValueNotifier<double>(0);
  final ValueNotifier<bool> _visible = ValueNotifier<bool>(false);
  late final OverlayEntry _entry = OverlayEntry(
    builder: (BuildContext context) => IgnorePointer(
      child: ValueListenableBuilder<bool>(
        valueListenable: _visible,
        builder: (BuildContext context, bool visible, Widget? child) =>
            visible ? child! : const SizedBox.shrink(),
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[_position, _press]),
          builder: (BuildContext context, Widget? child) => CustomPaint(
            size: Size.infinite,
            painter: _CursorPainter(_position.value, _press.value),
          ),
        ),
      ),
    ),
  );

  static SitePreviewCursor attach(WidgetTester tester) {
    final OverlayState overlay = tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .overlay!;
    final SitePreviewCursor cursor = SitePreviewCursor._(overlay);
    overlay.insert(cursor._entry);
    cursor._inserted = true;
    return cursor;
  }

  Offset get position => _position.value;

  /// 把指针条目挪回最上层（新弹出的弹窗 / 路由会压住它）。
  void raise() {
    // entry.mounted 要到下一帧才变真，刚插入就再挪会撞「已在 Overlay 里」，按自己的账判断。
    if (_inserted) _entry.remove();
    _overlay.insert(_entry);
    _inserted = true;
  }

  void show(Offset at) {
    _position.value = at;
    _visible.value = true;
    raise();
  }

  void hide() => _visible.value = false;

  /// 以缓动曲线把指针在 [duration] 内移到 [target]（真实时间，逐帧 pump）。
  Future<void> moveTo(
    WidgetTester tester,
    Offset target, {
    Duration duration = const Duration(milliseconds: 650),
  }) async {
    raise();
    final Offset from = _position.value;
    final Stopwatch sw = Stopwatch()..start();
    while (sw.elapsed < duration) {
      final double t = Curves.easeInOutCubic.transform(
        sw.elapsedMicroseconds / duration.inMicroseconds,
      );
      _position.value = Offset.lerp(from, target, t)!;
      await tester.pump(const Duration(milliseconds: 16));
    }
    _position.value = target;
    await tester.pump(const Duration(milliseconds: 16));
  }

  /// 按下-抬起的视觉反馈（指针缩一下 + 一圈涟漪）。[onDown] 在按下那一刻执行真动作。
  Future<void> click(
    WidgetTester tester, {
    Future<void> Function()? onDown,
  }) async {
    raise();
    final Stopwatch sw = Stopwatch()..start();
    bool fired = false;
    const Duration total = Duration(milliseconds: 420);
    while (sw.elapsed < total) {
      final double t = sw.elapsedMicroseconds / total.inMicroseconds;
      _press.value = t;
      if (!fired && t >= 0.25) {
        fired = true;
        if (onDown != null) await onDown();
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    if (!fired && onDown != null) await onDown();
    _press.value = 0;
    await tester.pump(const Duration(milliseconds: 16));
  }

  void dispose() {
    if (_inserted) _entry.remove();
    _inserted = false;
  }
}

class _CursorPainter extends CustomPainter {
  _CursorPainter(this.at, this.press);

  final Offset at;

  /// 0 = 未按；(0,1) = 一次点击的进度。
  final double press;

  @override
  void paint(Canvas canvas, Size size) {
    if (press > 0) {
      final double r = 6 + 22 * press;
      canvas.drawCircle(
        at,
        r,
        Paint()
          ..color = const Color(
            0xFF3B82F6,
          ).withValues(alpha: 0.45 * (1 - press))
          ..style = PaintingStyle.fill,
      );
    }
    // 标准箭头指针（Windows 外形），按下时略缩。
    final double s = press > 0 && press < 0.5 ? 0.88 : 1.0;
    final Path arrow = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 17)
      ..lineTo(4.2, 13.2)
      ..lineTo(7.2, 20)
      ..lineTo(10, 18.8)
      ..lineTo(7.1, 12.2)
      ..lineTo(12.6, 12.2)
      ..close();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(s * 1.15);
    canvas.drawPath(
      arrow.shift(const Offset(0.6, 1.2)),
      Paint()
        ..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6),
    );
    canvas.drawPath(arrow, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawPath(
      arrow,
      Paint()
        ..color = const Color(0xFF111111)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CursorPainter old) => old.at != at || old.press != press;
}

/// 场景时间线：记下每条需要后期混进成片的音频（录屏本身无声），
/// 写成 JSON 给 tool/site_previews/postprocess 读。
class SitePreviewTimeline {
  SitePreviewTimeline(this.recording);

  final SitePreviewRecording recording;
  final List<Map<String, Object>> audio = <Map<String, Object>>[];

  /// 后期参数（posterMs / trimStartMs / trimEndMs），原样写进 JSON。
  final Map<String, Object> extra = <String, Object>{};

  /// 从现在起，成片里播放 [file] 的 [fromMs] 起 [durationMs] 长的一段。
  void playAudio(String file, {int fromMs = 0, int? durationMs}) {
    audio.add(<String, Object>{
      'atMs': DateTime.now().difference(recording.startedAt).inMilliseconds,
      'file': file,
      'fromMs': fromMs,
      if (durationMs != null) 'durationMs': durationMs,
    });
  }

  /// 截断最后一条仍在播放的音频到此刻（例如查词时视频暂停）。
  void stopAudio() {
    if (audio.isEmpty) return;
    final Map<String, Object> last = audio.last;
    final int now = DateTime.now()
        .difference(recording.startedAt)
        .inMilliseconds;
    final int at = last['atMs']! as int;
    final int? dur = last['durationMs'] as int?;
    if (dur == null || at + dur > now) last['durationMs'] = now - at;
  }

  Future<void> write(File file) => file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(<String, Object>{
      'video': recording.output.path,
      'audio': audio,
      ...extra,
    }),
  );
}
