import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// flutter_inappwebview_windows fork native 源码合并守卫
/// （inappwebview-windows-native），合并自：
///   - process_exit_gate_guard_test.dart（TODO-618 fix3）
///   - webview2_disable_external_drop_guard_test.dart（TODO-648 / BUG-361）
///   - wgc_capture_lifecycle_log_guard_test.dart（TODO-506）
/// 各守卫保持独立 test() 块（保失败隔离），断言逐字搬运。放在 hibiki/test/ 下
/// 是因为 _read 的双候选相对路径（'packages/...' 与 '../packages/...'）依赖从
/// 仓库根或 hibiki/ 运行。本机无 MSVC 不能编译该 native fork，由 CI 编译验证；
/// 源码扫描守卫保证逻辑不回退。
String _read(List<String> candidates, String name) {
  final File? file = candidates.map(File.new).cast<File?>().firstWhere(
        (File? f) => f != null && f.existsSync(),
        orElse: () => null,
      );
  expect(file, isNotNull, reason: '$name not found');
  return file!.readAsStringSync();
}

String _body(String src, String signature, String nextMarker) {
  final int start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '$signature not found');
  final int end = src.indexOf(nextMarker, start + signature.length);
  expect(end, greaterThan(start),
      reason: '$signature must be bounded by $nextMarker');
  return src.substring(start, end);
}

String _readTextureBridgeSource() {
  final File? file = <String>[
    'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
    '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
  ].map(File.new).cast<File?>().firstWhere(
        (File? f) => f != null && f.existsSync(),
        orElse: () => null,
      );
  expect(file, isNotNull, reason: 'texture_bridge.cc not found');
  return file!.readAsStringSync();
}

String _methodBody(String src, String signature, String nextMarker) {
  final int start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '$signature not found');
  final int end = src.indexOf(nextMarker, start + signature.length);
  expect(end, greaterThan(start),
      reason: '$signature must be bounded by $nextMarker');
  return src.substring(start, end);
}

final RegExp _eventPattern = RegExp(r'\bevt=([^\s]+)');
final RegExp _poolPattern = RegExp(r'\bpool=([^\s]+)');
final RegExp _generationPattern = RegExp(r'\bgeneration=(\d+)');

const Set<String> _bannedLifecycleEvents = <String>{
  'retire-defer-fail',
  'remove-before-close-fail',
  'remove-before-close-closed-unexpected',
  'retire-remove-closed',
  'remove-before-close-start',
  'remove-before-close-done',
  'handler-release-done',
};

const List<String> _requiredClosureEvents = <String>[
  'pump-stop-start',
  'pump-remove-tick-done',
  'pump-stop-done',
  'session-close-done',
  'pool-close-done',
  'retire-register-done',
];

class _PoolClosure {
  _PoolClosure(this.pool, this.generation);

  final String pool;
  final String generation;
  final Map<String, int> eventIndexes = <String, int>{};
}

bool _isValidWgcLifecycleLog(String log) {
  final Map<String, _PoolClosure> closures = <String, _PoolClosure>{};
  final List<String> lines = log
      .split(RegExp(r'\r?\n'))
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .toList();

  for (int i = 0; i < lines.length; i += 1) {
    final String line = lines[i];
    final String? event = _eventPattern.firstMatch(line)?.group(1);
    if (event == null) {
      continue;
    }
    if (_bannedLifecycleEvents.contains(event) ||
        line.contains('defer_enqueue=0')) {
      return false;
    }

    if (!_requiredClosureEvents.contains(event)) {
      continue;
    }
    final String? pool = _poolPattern.firstMatch(line)?.group(1);
    final String? generation = _generationPattern.firstMatch(line)?.group(1);
    if (pool == null || generation == null) {
      return false;
    }
    final String key = '$pool#$generation';
    closures
        .putIfAbsent(key, () => _PoolClosure(pool, generation))
        .eventIndexes[event] = i;
  }

  if (closures.isEmpty) {
    return false;
  }
  for (final _PoolClosure closure in closures.values) {
    int previous = -1;
    for (final String event in _requiredClosureEvents) {
      final int? index = closure.eventIndexes[event];
      if (index == null || index <= previous) {
        return false;
      }
      previous = index;
    }
  }
  return true;
}

void main() {
  /// TODO-618 fix3 守卫：native 退出态总闸（g_process_exiting）。
  ///
  /// 断言：
  ///   1. texture_bridge.h 声明跨 TU 的 SetProcessExiting/IsProcessExiting。
  ///   2. texture_bridge.cc 定义 std::atomic<bool> g_process_exiting，且
  ///      PumpFrameLocked 的帧上报回调 frame_available_() 之前存在退出态短路
  ///      早返回。
  ///   3. in_app_webview_manager.cpp 的 prepareForProcessExit 入口在
  ///      webViews.clear() 之前调 SetProcessExiting()（早返回闸门必须在任何
  ///      teardown 之前置位）。
  group('process exit gate (TODO-618 fix3)', () {
    test(
        'TODO-618 fix3: native process-exit master gate short-circuits frame reports',
        () {
      final String header = _read(<String>[
        'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
        '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
      ], 'texture_bridge.h');
      final String bridge = _read(<String>[
        'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
        '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      ], 'texture_bridge.cc');
      final String manager = _read(<String>[
        'packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp',
        '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp',
      ], 'in_app_webview_manager.cpp');

      // 1) 头文件跨 TU 声明（external linkage）。
      expect(header.contains('void SetProcessExiting() noexcept'), isTrue,
          reason: 'process-exit master gate setter must be declared in header');
      expect(header.contains('bool IsProcessExiting() noexcept'), isTrue,
          reason: 'process-exit master gate getter must be declared in header');

      // 2) cc 定义进程级 atomic 总闸。
      expect(bridge.contains('std::atomic<bool> g_process_exiting'), isTrue,
          reason: 'process-exit master gate must be a std::atomic<bool>');
      expect(bridge.contains('void SetProcessExiting() noexcept'), isTrue,
          reason: 'SetProcessExiting must be defined in texture_bridge.cc');
      expect(bridge.contains('bool IsProcessExiting() noexcept'), isTrue,
          reason: 'IsProcessExiting must be defined in texture_bridge.cc');

      // 3) 帧上报短路：PumpFrameLocked 内 IsProcessExiting() 早返回必须在
      //    frame_available_() 之前（退出态一律不再向引擎推帧），且既有
      //    frame_available_() 调用未被删除（不回退）。
      final String pumpBody = _body(
        bridge,
        'void TextureBridge::PumpFrameLocked(',
        'bool TextureBridge::ShouldDropFrame()',
      );
      final int exitGate = pumpBody.indexOf('if (IsProcessExiting())');
      final int frameReport = pumpBody.indexOf('frame_available_()');
      expect(exitGate, greaterThanOrEqualTo(0),
          reason: 'PumpFrameLocked must short-circuit when process is exiting');
      expect(frameReport, greaterThan(exitGate),
          reason:
              'IsProcessExiting() early-return must guard the frame_available_() call');
      // 短路使用早返回，不得退化成只记日志后继续推帧。
      final String afterGate = pumpBody.substring(exitGate, frameReport);
      expect(afterGate.contains('return;'), isTrue,
          reason:
              'exit gate must return early, not fall through to frame report');

      // 4) prepareForProcessExit 入口在 webViews.clear() 之前置位总闸。
      final String prepareBody = _body(
        manager,
        'void InAppWebViewManager::prepareForProcessExit()',
        'bool InAppWebViewManager::isGraphicsCaptureSessionSupported()',
      );
      final int setExit = prepareBody.indexOf('SetProcessExiting()');
      final int clearWebViews = prepareBody.indexOf('webViews.clear()');
      expect(setExit, greaterThanOrEqualTo(0),
          reason: 'prepareForProcessExit must arm the master gate');
      expect(clearWebViews, greaterThan(setExit),
          reason:
              'SetProcessExiting() must run before webViews.clear() / any teardown');

      // manager.cpp 必须 include texture_bridge.h 才能看到 SetProcessExiting 声明。
      expect(
          manager
              .contains('#include "../custom_platform_view/texture_bridge.h"'),
          isTrue,
          reason:
              'manager must include texture_bridge.h for SetProcessExiting');
    });
  });

  /// TODO-648 / BUG-361 源码守卫：vendored fork `flutter_inappwebview_windows`
  /// 的 WebView2 控制器初始化路径必须显式 `put_AllowExternalDrop(FALSE)`。
  ///
  /// 根因（已验真）：WebView2 运行时默认 `AllowExternalDrop=TRUE`，会在**宿主主窗口**
  /// HWND 上注册自己的 `IDropTarget`（让 OS 文件能拖进网页），抢占 desktop_drop 的整窗
  /// 单点 `RegisterDragDrop`。WebView2 关闭时（`~InAppWebView` -> `Close()`）`RevokeDragDrop`
  /// 自己的 target 但**不恢复** desktop_drop 的 → 主 HWND 无有效 `IDropTarget` → 拖 .epub
  /// 进书架显示「禁止」光标（瞬态：开过 reader/查词 WebView 才触发，重启恢复）。
  ///
  /// 修复不变量：在 fork 的 WebView2 控制器初始化路径（`InAppWebView::prepare`）QI 拿
  /// `ICoreWebView2Controller4` 后显式 `put_AllowExternalDrop(FALSE)`，使 WebView2 不在宿主
  /// 窗口注册 drop target，desktop_drop 主 HWND 注册全程不被抢占。本守卫扫源码钉死这条，
  /// 防回归把它退回 WebView2 的默认 TRUE。
  group('WebView2 AllowExternalDrop (TODO-648 / BUG-361)', () {
    test(
        'TODO-648/BUG-361: fork WebView2 controller init disables AllowExternalDrop '
        'so desktop_drop keeps the host HWND drop registration', () {
      final List<String> sourceCandidates = <String>[
        'packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
        '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
      ];
      final File? sourceFile = sourceCandidates
          .map(File.new)
          .cast<File?>()
          .firstWhere((File? f) => f != null && f.existsSync(),
              orElse: () => null);
      expect(sourceFile, isNotNull, reason: 'in_app_webview.cpp 未找到');

      final String src = sourceFile!.readAsStringSync();

      // 修复说明注释必须保留 BUG-361 / TODO-648 标识，钉住根因与修复契约。
      expect(src.contains('BUG-361'), isTrue,
          reason: '修复说明注释应保留 BUG-361，标识 WebView2 抢占主窗口 drop 注册根因');

      // 必须显式关闭 AllowExternalDrop（默认 TRUE 是根因，不关就回归）。
      expect(src.contains('put_AllowExternalDrop(FALSE)'), isTrue,
          reason: 'WebView2 控制器初始化必须显式 put_AllowExternalDrop(FALSE)，否则默认 TRUE '
              '会在宿主主窗口注册 IDropTarget，关闭后留主 HWND 无有效 drop target -> 禁止光标');

      // AllowExternalDrop 在 ICoreWebView2Controller4，必须经 QueryInterface 拿到再调，
      // 老 Runtime 无该接口时 QI 失败应静默跳过（不崩）。
      expect(src.contains('ICoreWebView2Controller4'), isTrue,
          reason:
              'put_AllowExternalDrop 在 ICoreWebView2Controller4，必须 QI 拿到该接口');

      // 守卫调用位置：必须落在控制器初始化路径（prepare），且 QI 成功才调（容错）。
      final int prepareIdx = src.indexOf('void InAppWebView::prepare(');
      expect(prepareIdx, greaterThanOrEqualTo(0),
          reason: 'AllowExternalDrop 必须在 InAppWebView::prepare 控制器初始化路径设置');
      final int qiIdx =
          src.indexOf('IID_PPV_ARGS(&webViewController4)', prepareIdx);
      expect(qiIdx, greaterThan(prepareIdx),
          reason: 'prepare 内必须 QueryInterface 拿 ICoreWebView2Controller4');
      final int dropIdx = src.indexOf('put_AllowExternalDrop(FALSE)', qiIdx);
      expect(dropIdx, greaterThan(qiIdx),
          reason: 'put_AllowExternalDrop(FALSE) 必须在 QueryInterface 成功之后调用');
    });
  });

  /// TODO-506 WGC capture lifecycle log 守卫：attribution 事件可见性 +
  /// timer-pump retire 排序（StopPumpLocked 先于 finalize、无 FrameArrived
  /// handler-stack 路径残留）+ 行为型日志校验器夹具（拒绝旧事件驱动负样本、
  /// 接受 per-pool 成功闭包序列）。
  group('WGC capture lifecycle log (TODO-506)', () {
    test(
        'TODO-506 active WGC pool logs carry enough attribution to explain skips',
        () {
      final String src = _readTextureBridgeSource();

      for (final String event in <String>[
        'start-skip-running',
        'surface-size-changed',
        'frame-first-success',
        'frame-needs-update',
        'frame-noop',
        'pump-start',
        'pump-stop-start',
        'pump-remove-tick-done',
        'pump-stop-done',
        'recreate-skip-samesize',
      ]) {
        expect(src.contains('WgcLog::Write("$event"'), isTrue,
            reason: 'TODO-506 must make $event visible in WGC.captureLog');
      }

      final String startBody = _methodBody(
        src,
        'bool TextureBridge::Start()',
        'bool TextureBridge::CreateAndStartFramePoolLocked()',
      );
      expect(startBody.contains('BridgeStateDetail'), isTrue,
          reason:
              'start/start-skip-running must use the shared attribution detail builder');
      for (final String field in <String>[
        'GenerationDetail',
        'pool_size',
        'capture_item_size',
        'needs_update',
        'bridge',
      ]) {
        expect(src.contains(field), isTrue,
            reason: 'start/start-skip-running log must include $field');
      }

      final String recreateBody = _methodBody(
        src,
        'void TextureBridge::RecreateFramePoolLocked()',
        'void TextureBridge::Stop()',
      );
      expect(recreateBody.contains('current_size'), isTrue,
          reason: 'recreate-skip-samesize must log current capture item size');
      expect(recreateBody.contains('lifetime_size'), isTrue,
          reason:
              'recreate-skip-samesize must log existing frame-pool lifetime size');

      final String frameBody = src.substring(
        src.indexOf('void TextureBridge::PumpFrameLocked('),
        src.indexOf('bool TextureBridge::ShouldDropFrame()'),
      );
      expect(frameBody.contains('FrameHandlerDetail'), isTrue,
          reason:
              'PumpFrameLocked must use the shared frame attribution detail builder');
      for (final String field in <String>[
        'GenerationDetail',
        'in_handler',
        'retiring',
        'has_frame',
        'needs_update',
      ]) {
        expect(src.contains(field), isTrue,
            reason: 'PumpFrameLocked low-frequency logs must include $field');
      }
    });

    test('timer-pump WGC retire removes Tick before closing capture resources',
        () {
      final String src = _readTextureBridgeSource();
      final String retireBody = _methodBody(
        src,
        'void TextureBridge::RetireFramePoolLocked(',
        'void FinalizeFramePoolLifetime(',
      );

      expect(retireBody.contains('StopPumpLocked(lifetime, reason)'), isTrue,
          reason: 'retire must stop/remove the timer pump before finalizing');
      expect(retireBody.contains('TryEnqueue'), isFalse,
          reason:
              'FrameArrived handler-stack defer is not part of the default timer pump path');
      expect(src.contains('add_FrameArrived'), isFalse,
          reason: 'default WGC path must not subscribe to FrameArrived');
      expect(src.contains('WgcLog::Write("retire-defer-fail"'), isFalse,
          reason:
              'retire-defer-fail belongs to the removed handler-stack path');
      expect(src.contains('defer_enqueue=0'), isFalse,
          reason:
              'timer pump path must not use handler-stack enqueue fallback');
    });

    test('WGC lifecycle log fixture rejects old event-driven negative events',
        () {
      const String userFailureLog = '''
2026-06-17T11:00:00.000Z tid=42 evt=create-pool pool=0xABC generation=9
2026-06-17T11:00:00.100Z tid=42 evt=retire pool=0xABC reason=recreate
2026-06-17T11:00:00.101Z tid=42 evt=remove-before-close-start pool=0xABC generation=9
2026-06-17T11:00:00.102Z tid=42 evt=handler-release-done pool=0xABC generation=9
2026-06-17T11:00:00.104Z tid=42 evt=session-close-done pool=0xABC generation=9
2026-06-17T11:00:00.105Z tid=42 evt=pool-close-done pool=0xABC generation=9
2026-06-17T11:00:00.106Z tid=42 evt=retire-register-done pool=0xABC generation=9
''';

      expect(_isValidWgcLifecycleLog(userFailureLog), isFalse);
    });

    test('WGC lifecycle log fixture accepts per-pool successful closure', () {
      const String successLog = '''
2026-06-17T11:00:00.000Z tid=42 evt=create-pool pool=0xABC generation=9
2026-06-17T11:00:00.100Z tid=42 evt=retire pool=0xABC reason=recreate
2026-06-17T11:00:00.101Z tid=42 evt=pump-stop-start pool=0xABC generation=9
2026-06-17T11:00:00.102Z tid=42 evt=pump-remove-tick-done pool=0xABC generation=9 hr=0x00000000
2026-06-17T11:00:00.103Z tid=42 evt=pump-stop-done pool=0xABC generation=9
2026-06-17T11:00:00.104Z tid=42 evt=session-close-done pool=0xABC generation=9 hr=0x00000000
2026-06-17T11:00:00.105Z tid=42 evt=pool-close-done pool=0xABC generation=9 hr=0x00000000
2026-06-17T11:00:00.106Z tid=42 evt=retire-register-done pool=0xABC generation=9
''';

      expect(_isValidWgcLifecycleLog(successLog), isTrue);
    });
  });
}
