// BUG-1887 源码守卫：Windows 上 Fushi 不得在启动时占用系统定位能力。
//
// 症状：Windows「设置 → 隐私和安全性 → 定位」把 fushi.exe 列成「正在使用定位」，
// 从 app 启动那一秒起、退出才停。用户看到的就是「这个 app 在读我的位置」。
//
// 根因**不是** WebView2（一开始的直觉方向），也**不是**有功能在读位置：
// `permission_handler_windows` 0.1.2 的插件**构造函数**无条件订阅
// `Geolocator::PositionChanged`（回调体是空的）。订阅 = 让 Windows 开一个持续的
// 定位会话，而插件对象在 `RegisterPlugins()` 期间构造 —— 于是启动 0.7s 内
// CapabilityAccessManager 就记下 LastUsedTimeStart、Stop=0，直到进程退出。
//
// 实测判别（见 docs/bugs/BUG-1887-...md）：把所有 WebView2 环境创建全部弄失败、
// 零个 msedgewebview2.exe 子进程，账本照样写 —— 与 WebView2 无关。
//
// 修复分两件**不同**的事，缺一不可，所以这里分两组断言：
//   ① vendored permission_handler_windows：Geolocator + 订阅推迟到唯一读它的地方
//      （checkServiceStatus(LOCATION*)）。Fushi 的 Windows 端从不问，于是永远不开
//      定位会话。这是消掉系统显示的那一层。
//   ② runner 自有的两个裸 WebView2（app 外查词浮窗 + 剪贴板面板）装权限拒绝门，
//      拦**页面运行期**发起的定位/麦克风/摄像头请求。in-app 的 fork 早有这道门，
//      这两个窗一直没有。它修不掉 ① 的显示，但没有它，将来任意 HTML 内容都能
//      弹系统权限提示条。
//
// C++ 与 pubspec 在 Dart 测试里跑不了，所以在源码层锁定。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// vendored 的 permission_handler_windows 插件源码（相对 `fushi/` 的测试 cwd）。
const String _vendoredPluginPath =
    '../third_party/permission_handler_windows/windows/'
    'permission_handler_windows_plugin.cpp';

/// workspace 根 pubspec —— pub workspace 只认根 pubspec 的 dependency_overrides。
const String _rootPubspecPath = '../pubspec.yaml';

/// runner 自有的原生覆盖窗（app 外查词浮窗 + 剪贴板面板共用这份实现）。
const String _runnerOverlayPath = 'windows/runner/global_lookup_window.cpp';

/// 取出顶层函数 [signature] 的函数体源码（到下一个顶层 `}` 为止）。
/// 在 main() 顶层调用，故不能用 expect（那是 OutsideTestException），直接抛。
String _topLevelBody(String src, String signature, String path) {
  final int start = src.indexOf(signature);
  if (start < 0) {
    throw StateError('$path 里必须有 `$signature`（守卫依赖它作为锚点）');
  }
  final int end = src.indexOf('\n}', start + signature.length);
  return src.substring(start, end == -1 ? src.length : end);
}

void main() {
  late String plugin;
  late String rootPubspec;
  late String overlay;

  setUpAll(() {
    plugin = File(_vendoredPluginPath).readAsStringSync();
    rootPubspec = File(_rootPubspecPath).readAsStringSync();
    overlay = File(_runnerOverlayPath).readAsStringSync();
  });

  group('① vendored permission_handler_windows 不在启动时开定位会话', () {
    test('插件构造函数里没有 PositionChanged 订阅', () {
      expect(
        plugin.contains(
          'PermissionHandlerWindowsPlugin::PermissionHandlerWindowsPlugin() '
          '= default;',
        ),
        isTrue,
        reason: '构造函数在 RegisterPlugins 期间跑；在这里做任何 Geolocator '
            '订阅就是让 Windows 从启动到退出一直记「正在使用定位」——'
            '这正是 BUG-1887 的根因。构造函数必须是空的',
      );
      // 全文件只允许有一处订阅，且必须在 EnsureGeolocator 里（懒创建的落点）。
      final int subscribeAt = plugin.indexOf('PositionChanged(winrt::auto_revoke');
      final int lazyAt =
          plugin.indexOf('void PermissionHandlerWindowsPlugin::EnsureGeolocator()');
      expect(
        'PositionChanged(winrt::auto_revoke'.allMatches(plugin).length,
        1,
        reason: '订阅点必须唯一，多一处就意味着又有人在别的时机开定位会话',
      );
      expect(
        subscribeAt > lazyAt && lazyAt >= 0,
        isTrue,
        reason: '唯一那处订阅必须落在 EnsureGeolocator 函数体里（懒创建），'
            '不能回到构造函数或任何启动期路径',
      );
    });

    test('订阅推迟到 EnsureGeolocator，且 Geolocator 是懒句柄', () {
      expect(
        plugin.contains('void PermissionHandlerWindowsPlugin::EnsureGeolocator()'),
        isTrue,
        reason: '订阅本身不是无用代码（LocationStatus 只有存在会话时才报真实状态），'
            '所以是「推迟」不是「删掉」；推迟的落点就是这个函数',
      );
      expect(
        plugin.contains('Geolocator geolocator{nullptr}'),
        isTrue,
        reason: '成员必须是空句柄才谈得上懒创建；写成值类型成员就又变成'
            '「插件一构造就构造 Geolocator」',
      );
    });

    test('唯一读 LocationStatus 的地方按需创建', () {
      final String reader = _topLevelBody(
        plugin,
        'void PermissionHandlerWindowsPlugin::IsLocationServiceEnabled(',
        _vendoredPluginPath,
      );
      expect(
        reader.contains('EnsureGeolocator()'),
        isTrue,
        reason: '这是唯一读 geolocator 的地方；不在这里创建，'
            '真有人问「定位服务开没开」时会对空句柄取值',
      );
      expect(
        reader.contains('geolocator.LocationStatus()'),
        isTrue,
        reason: '按需创建之后语义要与上游一致，判据仍是 LocationStatus',
      );
    });

    test('根 pubspec 用 path override 顶掉 pub.dev 版本', () {
      expect(
        rootPubspec.contains('path: third_party/permission_handler_windows'),
        isTrue,
        reason: 'vendored 源码改了但没接上 override = 构建用的还是上游那份，'
            '定位显示照旧。pub workspace 只认根 pubspec 的 dependency_overrides',
      );
    });
  });

  group('② 原生浮窗拒绝网页发起的权限请求', () {
    test('ConfigureWebView 装了 PermissionRequested 门并 DENY', () {
      final String configure = _topLevelBody(
        overlay,
        'void GlobalLookupWindow::ConfigureWebView()',
        _runnerOverlayPath,
      );
      expect(
        configure.contains('add_PermissionRequested'),
        isTrue,
        reason: 'ConfigureWebView 是两条创建路径（composition / windowed）+ '
            'BUG-693 自愈重建的唯一漏斗；不在这里装门，WebView2 的默认行为是'
            '弹系统权限提示条，而这个窗是无边框置顶浮窗还开了防截屏',
      );
      expect(
        configure.contains('COREWEBVIEW2_PERMISSION_STATE_DENY'),
        isTrue,
        reason: '装了 handler 却不 put_State(DENY) 等于什么都没做',
      );
    });

    test('in-app fork 侧的既有兜底没被删', () {
      final String fork = File(
        '../packages/flutter_inappwebview_windows/windows/in_app_webview/'
        'in_app_webview.cpp',
      ).readAsStringSync();
      expect(
        fork.contains('add_PermissionRequested'),
        isTrue,
        reason: 'fork 这道门比 BUG-1887 早就存在（Dart 不接管时 put_State(DENY)），'
            '是 app 内阅读器/词典 WebView 的兜底',
      );
    });
  });
}
