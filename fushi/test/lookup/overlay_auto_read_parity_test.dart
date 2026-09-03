import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1210 守卫：app 外查词覆盖窗必须接自动朗读，且走共享实现
/// （`overlay_auto_read.dart`），不得自己维护一份播放/回报逻辑。
///
/// 这条链路的运行时依赖是真实 WebView2 + native channel，widget 测试跑不起来，
/// 故守在源码层（与 `overlay_bridge_handlers` 的「绝不复制」红线同一层保护）。
///
/// flutter test 的 cwd 是 hibiki 包根。
void main() {
  /// 剥掉注释后再扫：讲「为什么」的注释里必然写着下面要断言的每一个符号名，
  /// 连注释一起扫等于让文档给自己背书。统一走共享 helper maskComments。
  final String overlay = maskComments(
    File('lib/src/lookup/global_lookup_controller.dart').readAsStringSync(),
  );
  final String shared = maskComments(
    File('lib/src/lookup/overlay_auto_read.dart').readAsStringSync(),
  );

  test('覆盖窗查到词后触发自动朗读', () {
    expect(
      overlay.contains('autoReadFirstEntry('),
      true,
      reason: '覆盖窗查词成功路径必须调用 autoReadFirstEntry，'
          '否则 autoReadOnLookup 开关对覆盖窗完全无效',
    );
  });

  test('覆盖窗接住播放回报，否则每次自动发音都空耗满 5s 超时', () {
    expect(
      overlay.contains('maybeHandleWordAudioPlayed('),
      true,
      reason: '覆盖窗的 _onJsMessage 必须处理 wordAudioPlayed，'
          '否则 Completer 永远等不到回报、每次都要等满超时才回落 Dart 播放器',
    );
  });

  test('覆盖窗使用共享实现，不得自己写一份', () {
    expect(
      overlay.contains('OverlayAutoRead('),
      true,
      reason: '覆盖窗必须使用共享的 OverlayAutoRead',
    );
    // 私有副本的标志物：自己维护 token / pending 表 / 播放脚本。
    expect(
      overlay.contains('_pendingWordAudioPlays'),
      false,
      reason: '覆盖窗不得自己维护 pending 表——收口到共享实现',
    );
    expect(
      overlay.contains('buildPlayWordAudioScript('),
      false,
      reason: '覆盖窗不得自己拼播放脚本——收口到共享实现',
    );
  });

  test('共享实现保留既有播放契约（WebView 快路径 + 就绪门控 + 超时回落）', () {
    expect(
      shared.contains('autoReadWordUnified('),
      true,
      reason: '播放必须走 autoReadWordUnified 单一真相（WebView 快路径 + Dart 兜底）',
    );
    expect(
      shared.contains('LookupAutoReadCoordinator.instance.runAutomatic('),
      true,
      reason: '必须复用同一去重协调器，避免同词重复连读',
    );
    expect(
      shared.contains('_isWebViewReady()'),
      true,
      reason: '发播放脚本前必须过就绪门控，否则会顶掉挂起中的整栈渲染脚本',
    );
    expect(shared.contains('autoReadOnLookup'), true, reason: '必须尊重用户的自动朗读开关');
  });

  test('覆盖窗注入自己的 native 通道', () {
    expect(
      overlay.contains("label: 'overlay'"),
      true,
      reason: '覆盖窗必须用自己的 label，日志才分得清来源',
    );
    expect(
      overlay.contains('GlobalLookupChannel.render'),
      true,
      reason: '覆盖窗必须注入自己的渲染通道',
    );
  });

  test('覆盖窗 root 查词按调用方传入的朗读资格决定是否朗读', () {
    expect(
      overlay.contains('if (autoRead)'),
      true,
      reason: '瞬态覆盖窗 root 查词必须执行调用方传入的朗读资格',
    );
  });
}
