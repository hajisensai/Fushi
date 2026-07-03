import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-1110 / BUG-535）：Android 视频「无画面」纹理握手诊断不变量。
///
/// 背景：某台 Android 11 设备（RMX3085）上视频解码链完全正常（首帧解出、videoParams
/// 就绪），但 media_kit_video 2.0.1 的 Android 纹理握手从未完成 —— `vo=null` /
/// `current-vo=` 空 / `gpu-api` 空 / texture id 停在 not-created，黑屏无画面。根因在
/// `SurfaceProducer`（1.3.0 迁移）native 实现内部（`onSurfaceAvailable` 从未产出有效
/// surface → `wid=0` → widListener 永远设 `vo=null`），Dart 层无法根治。
///
/// **诊断盲区**：旧诊断只在 `open()` 后**一次性**回读 `vo`，那一刻 `vo=null` 是
/// media_kit 有意的初始态（`wid` 未到），无法区分「vo=null 瞬态（正常）」与「vo=null
/// 永久（真无画面）」。本次加了两个能一步定位的诊断钩子：
///   1. 监听 `VideoController.id`（纹理握手唯一 Dart 侧可观测输出）的每次变化；
///   2. 首帧渲染 / 6s 超时后**再回读一次** texture id + 渲染属性，并显式记出被
///      media_kit 吞掉的 `VideoController.create` 异常。
///
/// 真正的 native surface 失败只能真机 + logcat 复现；此守卫锁住这些诊断钩子的静态
/// 存在，防有人重构时误删、让下次真机日志又回到「vo=null 无法判真伪」的盲区。
void main() {
  String read(String relPath) {
    for (final String prefix in <String>['', '../']) {
      final File f = File('$prefix$relPath');
      if (f.existsSync()) return f.readAsStringSync();
    }
    throw StateError('找不到文件：$relPath');
  }

  group('Android 视频无画面诊断钩子 (TODO-1110 / BUG-535)', () {
    final String src = read('lib/src/media/video/video_player_controller.dart');

    test('挂 VideoController.id 监听记录纹理握手状态变化', () {
      // texture id 是纹理握手成功与否的唯一 Dart 侧信号；必须挂监听记它的变化。
      expect(src.contains('_attachTextureIdDiag'), isTrue,
          reason: '缺纹理 id 诊断监听：无画面时无法判断握手是否完成');
      expect(src.contains('.id.addListener'), isTrue,
          reason: '未真正监听 VideoController.id ValueNotifier');
      // 监听必须在 dispose / 换集时清理（防向已释放 controller 回调）。
      expect(src.contains('_detachTextureIdDiag'), isTrue,
          reason: '纹理 id 监听未清理');
      expect(src.contains('.id.removeListener'), isTrue,
          reason: '未移除 VideoController.id 监听');
    });

    test('首帧/超时后再回读一次渲染状态区分 vo=null 瞬态 vs 永久', () {
      expect(src.contains('_logRenderStateAfterFirstFrame'), isTrue,
          reason: '缺首帧后的二次回读：无法区分 vo=null 瞬态与永久');
      // 必须等首帧渲染 Future（握手成功才 complete）而非固定 sleep。
      expect(src.contains('waitUntilFirstFrameRendered'), isTrue,
          reason: '二次回读未等 waitUntilFirstFrameRendered');
      // 超时后仍回读（无画面时首帧永不来，靠超时兜底出快照）。
      expect(src.contains('6s-timeout') || src.contains('seconds: 6'), isTrue,
          reason: '二次回读缺超时兜底');
    });

    test('显式记出被 media_kit 吞掉的 VideoController.create 异常', () {
      // media_kit 的 VideoController.create 失败只 debugPrint 吞掉；诊断须显式记出。
      expect(src.contains('create-error'), isTrue,
          reason: '未把 create 失败异常记进诊断日志');
    });

    test('二次回读走 _isCurrentLoad 双判据防原生 UAF', () {
      // 后台 await 期间可能换片/销毁；回读前必须重校验，防向已释放 NativePlayer 读属性。
      final int idx = src.indexOf('_logRenderStateAfterFirstFrame(');
      expect(idx, greaterThan(0));
      final String body = src.substring(idx, idx + 2000);
      expect(body.contains('_isCurrentLoad'), isTrue,
          reason: '首帧后二次回读缺 loadToken 双判据，存在原生 UAF 风险');
    });
  });
}
