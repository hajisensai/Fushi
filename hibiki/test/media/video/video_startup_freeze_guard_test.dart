import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-772 源码守卫：快速进出视频 → Windows 启动冻死在 loading 的**减触发面**修复。
///
/// 根因是进程共享 D3D device/swapchain 被 libmpv/ANGLE/WGC churn 弄进 device-lost，
/// Flutter 引擎 raster/present 管线楔死（Dart isolate 其实活着）。引擎级根治在
/// Windows native，非 app Dart；本层做的是「减少制造 churn 的机会」+「退出干净收尾」。
///
/// 无法纯 widget 测（VideoFushiPage ~5800 行 + 需真 libmpv/GPU），故与既有
/// `video_lifecycle_static_test.dart` 一致，在源码层钉死结构不变式，防回归删除。
void main() {
  String read(String rel) => File(rel).readAsStringSync();

  group('BUG-772 首开在途 controller 主动取消 (Task 1)', () {
    final String src =
        read('lib/src/pages/implementations/video_fushi_page.dart');

    test('声明 _pendingController 字段', () {
      expect(src.contains('VideoPlayerController? _pendingController'), isTrue,
          reason: '需持有首开在途 controller 以便页面 dispose 时主动取消');
    });

    test('首开路径把在途 controller 存入 _pendingController（仅新建，换集不设）', () {
      expect(
        RegExp(r'if \(isInitialVideoOpen\)\s*_pendingController = controller;')
            .hasMatch(src),
        isTrue,
        reason: '只在 isInitialVideoOpen（新建）时登记；换集复用同一 controller 不设',
      );
    });

    test('dispose() 主动 dispose 在途 controller 且不与 _controller 二次 dispose', () {
      final RegExpMatch? body = RegExp(
        r'void dispose\(\) \{(.*?)\n  \}',
        dotAll: true,
      ).firstMatch(src);
      expect(body, isNotNull, reason: '找不到 State.dispose 方法体');
      final String b = body!.group(1)!;
      expect(b.contains('_pendingController'), isTrue,
          reason: 'dispose 必须处理在途 controller（否则 native churn 跑完污染 GPU）');
      expect(b.contains('!identical(_pendingController, _controller)'), isTrue,
          reason: '避免与已赋值的 _controller 二次 dispose 同一实例');
    });

    test('首开成功赋值后清空 _pendingController', () {
      expect(
        RegExp(r'_controller = controller;\s*_pendingController = null;')
            .hasMatch(src),
        isTrue,
        reason: '首开成功后必须清空在途标记，否则 dispose 会误 dispose 正在用的实例',
      );
    });
  });
}
