// BUG-1096 源码守卫：画面捕获里的「两个鼠标指针」。
//
// 两条成因各锁一半，C++ 无法在 Dart 测试里执行，故在源码层锁死结构：
//   ① 捕获目标：Magpie 缩放窗必须按窗口属性 Magpie.SrcHWND 重定向到真实源窗口，
//      且枚举阶段与绑定阶段**两处都做**（Dart 侧可能拿的是缓存句柄）；
//   ② 盲区：put_IsCursorCaptureEnabled 的 HRESULT 与 IGraphicsCaptureSession2 的 QI
//      结果不得再被静默丢弃，必须写进可回传的 diagnostics；
//   ③ diagnostics 要真的经 channel 回到 Dart（否则等于没记）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String capture = File(
    'windows/runner/window_capture.cpp',
  ).readAsStringSync();
  final String header = File(
    'windows/runner/window_capture.h',
  ).readAsStringSync();
  final String flutterWindow = File(
    'windows/runner/flutter_window.cpp',
  ).readAsStringSync();
  final String dartChannel = File(
    'lib/src/mining/window_capture_channel.dart',
  ).readAsStringSync();
  final String attachedSurface = File(
    'windows/runner/attached_text_surface_window.cpp',
  ).readAsStringSync();
  final String attachedHeader = File(
    'windows/runner/attached_text_surface_window.h',
  ).readAsStringSync();

  test('① Magpie 缩放窗按 Magpie.SrcHWND 属性重定向到源窗口', () {
    expect(
      capture.contains('GetPropW(hwnd, L"Magpie.SrcHWND")'),
      isTrue,
      reason: '判定契约是窗口属性名（跨版本稳定），不是类名里的 GUID',
    );
    expect(
      header.contains('HWND ResolveScalingSourceWindow(HWND hwnd);'),
      isTrue,
      reason: '重定向必须是一个具名、可复用的入口，不得内联进某一条路径',
    );
    // 拿不到属性 / 句柄失效必须原样返回，不改变没装 Magpie 的用户路径。
    expect(
      capture.contains('if (source == hwnd || !IsWindow(source)) {'),
      isTrue,
      reason: '属性指向自身或已失效的句柄必须回落到原窗口，不得崩也不得抓错窗',
    );
  });

  test('① 枚举阶段与捕获绑定阶段都过一次重定向', () {
    final int enumUse = 'ResolveScalingSourceWindow('
        .allMatches(capture)
        .length;
    expect(
      enumUse,
      greaterThanOrEqualTo(3),
      reason: '至少三处：函数定义 + EnumProc（换 hwnd/title/pid）+ CaptureWindowPng（绑定前）',
    );
    expect(
      capture.contains('GetWindowThreadProcessId(target, &w.pid)'),
      isTrue,
      reason: 'PID 必须取重定向后的窗口——否则 voice hook 会注入 Magpie.exe 而不是游戏',
    );
  });

  test(
    '① Magpie presentation mapping reads the explicit source/output viewports',
    () {
      expect(
        header.contains('struct MagpiePresentationMapping'),
        isTrue,
        reason:
            'surface geometry must have a shared source/presentation mapping type',
      );
      expect(
        header.contains(
          'ReadMagpiePresentationMapping(HWND presentation_hwnd,',
        ),
        isTrue,
        reason: 'mapping must be reusable by capture and the attached surface',
      );
      for (final String property in <String>[
        'Magpie.SrcLeft',
        'Magpie.SrcTop',
        'Magpie.SrcRight',
        'Magpie.SrcBottom',
        'Magpie.DestLeft',
        'Magpie.DestTop',
        'Magpie.DestRight',
        'Magpie.DestBottom',
      ]) {
        expect(
          capture.contains('L"$property"'),
          isTrue,
          reason: '$property must be read from the presentation window',
        );
      }
      expect(
        capture.contains('EnumPropsExW'),
        isTrue,
        reason:
            'zero is a valid screen coordinate; property presence must not be inferred from GetProp null',
      );
      expect(
        capture.contains('expected_source_hwnd'),
        isTrue,
        reason:
            'a same-shaped arbitrary window must not be accepted as the presentation',
      );
      expect(
        capture.contains('expected_source_hwnd == nullptr'),
        isTrue,
        reason: 'the mapping API must require an explicit source identity',
      );
    },
  );

  test('② 光标抑制的 QI 与 HRESULT 不再被静默丢弃', () {
    expect(
      capture.contains('const HRESULT cursor_qi = session.As(&session2);'),
      isTrue,
      reason: 'IGraphicsCaptureSession2 的 QI 结果必须被接住（Win10 19041- 上会失败）',
    );
    expect(
      capture.contains(
        'const HRESULT cursor_hr = session2->put_IsCursorCaptureEnabled(false);',
      ),
      isTrue,
      reason: 'put_IsCursorCaptureEnabled 的 HRESULT 必须被接住，不得裸调丢弃',
    );
    expect(
      capture.contains('AppendDiagnostic(out, "put_IsCursorCaptureEnabled'),
      isTrue,
      reason: 'put_ 失败必须留痕，否则「用户机器上到底关掉没有」又变成盲区',
    );
    expect(
      capture.contains('IGraphicsCaptureSession2 unavailable'),
      isTrue,
      reason: '接口本身缺失（旧系统）同样要留痕，不能与「已关掉」混为一谈',
    );
  });

  test('③ diagnostics 经 channel 回到 Dart', () {
    expect(
      header.contains('std::string diagnostics;'),
      isTrue,
      reason: 'diagnostics 必须与 error 正交（成功路径也要能说话）',
    );
    expect(
      flutterWindow.contains('flutter::EncodableValue("diagnostics")'),
      isTrue,
      reason: 'native 记了但不回传等于没记',
    );
    expect(
      dartChannel.contains("diagnostics: m['diagnostics'] as String?"),
      isTrue,
      reason: 'Dart 侧必须解析该字段',
    );
  });

  test('④ 捕获失败 reason 与 frame metadata 经 Flutter reply 回到 Dart', () {
    expect(
      header.contains('std::string capture_reason;'),
      isTrue,
      reason: 'native 需要保留 bounded machine-readable capture reason',
    );
    expect(
      capture.contains('"no_frame"'),
      isTrue,
      reason: '无首帧不能只留下人类可读 error',
    );
    expect(
      flutterWindow.contains('flutter::EncodableValue("captureReason")'),
      isTrue,
      reason: 'native reason 必须进入 Dart channel reply',
    );
    for (final String key in <String>[
      'contentWidthPx',
      'contentHeightPx',
      'textureWidthPx',
      'textureHeightPx',
    ]) {
      expect(
        flutterWindow.contains('flutter::EncodableValue("$key")'),
        isTrue,
        reason: '$key 必须经 Flutter reply 发送',
      );
    }
    expect(
      dartChannel.contains(
        "captureReason: _readBoundedCaptureReason(m['captureReason'])",
      ),
      isTrue,
    );
    expect(dartChannel.contains("'contentWidthPx'"), isTrue);
  });

  test('⑤ WGC item 失败保留 HRESULT，且不盲目重试', () {
    expect(
      capture.contains('const HRESULT item_hr = interop->CreateForWindow('),
      isTrue,
      reason: 'CreateForWindow 的真实 HRESULT 必须先保存再处理失败',
    );
    expect(
      capture.contains('FAILED(item_hr) ? item_hr : E_POINTER'),
      isTrue,
      reason: 'item 为空时只能为无 HRESULT 的异常情况补 E_POINTER',
    );
    expect(
      capture.contains('AppendDiagnostic(out, item ? "CreateForWindow failed"'),
      isTrue,
      reason: 'WGC item 创建失败必须进入 bounded diagnostics',
    );
    expect(
      capture.contains('constexpr int kMaximumAttempts = 2;'),
      isFalse,
      reason: '永久拒绝不能再次调用 CreateForWindow 伪装成几何重试',
    );
    expect(
      capture.contains('Sleep(40);'),
      isFalse,
      reason: 'WGC item 失败路径不再等待后盲重试',
    );
    expect(
      capture.contains(
        'SetCaptureReason(&candidate, "wgc_item_no_verified_presentation")',
      ),
      isFalse,
      reason: '不能用泛化 reason 覆盖首个真实 WGC 失败',
    );
    expect(
      capture.contains('TryCapturePrintWindow(source_hwnd, &candidate)'),
      isTrue,
      reason: '源 WGC item 失败后必须经过受限兼容后端',
    );
  });

  test('⑥ PrintWindow fallback 具备保护门槛、超时和非空像素校验', () {
    for (final String token in <String>[
      'IsWindowVisible(hwnd)',
      'IsIconic(hwnd)',
      'DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED',
      'GetWindowDisplayAffinity(hwnd, &affinity)',
      'affinity != WDA_NONE',
      'PrintWindow(',
      'PW_CLIENTONLY | PW_RENDERFULLCONTENT',
      'PrintWindow timed out; helper process terminated',
      'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE',
      'PROC_THREAD_ATTRIBUTE_HANDLE_LIST',
      'TerminatePrintWindowHelper(job.get(), process.get())',
      'g_print_window_worker_busy',
      'PrintWindow produced no pixels',
      'PrintWindow produced partial client pixels',
      'PrintWindow produced a black client frame',
      'PrintWindow produced a transparent client frame',
      'ReleaseGdiOnOwnerThread',
      'bytes[i + 3] = 0xFF',
      'SameCaptureClient(initial_client, final_client)',
    ]) {
      expect(capture.contains(token), isTrue, reason: 'missing $token');
    }
    expect(
      capture.contains('constexpr UINT kPrintWindowTimeoutMs = 750;'),
      isTrue,
      reason: 'PrintWindow helper 必须有固定等待上限，同时最多一个',
    );
    expect(
      capture.contains('WS_EX_NOREDIRECTIONBITMAP'),
      isFalse,
      reason: 'fallback 不能因未知 ex-style 把原始 WGC 失败直接挡掉',
    );
    expect(
      capture.contains('CreateForMonitor'),
      isFalse,
      reason: '不能回退到无法证明属于目标窗口的显示器图像',
    );
    expect(
      capture.contains('BitBlt'),
      isFalse,
      reason: '不能用屏幕 BitBlt 捕获遮挡桌面或错误窗口',
    );
  });

  test('⑦ Magpie 源 viewport 允许子区域并保留源客户区身份', () {
    for (final String token in <String>[
      'source_client_left_px',
      'source_client_top_px',
      'source_client_width_px',
      'source_client_height_px',
      'source_client_dpi',
      'RectWithin(presentation_mapping->source_rect_screen, source_client)',
      'SameCaptureClient(initial_source_client, final_source_client)',
    ]) {
      expect(capture.contains(token), isTrue, reason: 'missing $token');
    }
    expect(
      header.contains('int source_client_width_px = 0;'),
      isTrue,
      reason: 'Dart mapping 需要 native 返回真实源客户区尺寸',
    );
  });

  test('⑧ Magpie 生命周期立即触发贴附层重新解析 presentation HWND', () {
    expect(
      attachedHeader.contains('OnExternalWindowLifecycle(HWND output_window'),
      isTrue,
    );
    expect(
      attachedSurface.contains(
        'PostMessageW(hwnd_, kSyncTargetMessage, 0, 0);',
      ),
      isTrue,
      reason: '超分窗口重建/销毁后不能只等下一次 500ms 健康 tick',
    );
    expect(
      flutterWindow.contains(
        'attached_text_surface_window_->OnExternalWindowLifecycle(',
      ),
      isTrue,
      reason: 'Magpie 广播要同时通知 Dart 与 attached calibration surface',
    );
  });
}
