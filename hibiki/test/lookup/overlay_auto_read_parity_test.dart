import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1210 守卫：app 外两个 WebView2 表面（瞬态查词覆盖窗 / 常驻剪贴板面板）
/// 必须**都**接自动朗读，且走**同一份**实现。
///
/// 根因：自动朗读此前只在 `global_lookup_controller` 里接了线，
/// `clipboard_panel_controller` 整条路径没有任何朗读调用——同一个全局开关
/// `autoReadOnLookup` 在一个表面生效、在另一个完全无效，用户表现为「面板查词
/// 不读，必须手动点 ♪」。而剪贴板面板正是 galgame / 复制文本流的主力表面。
///
/// 这条链路的运行时依赖是真实 WebView2 + native channel，widget 测试跑不起来，
/// 故守在源码层（与 `overlay_bridge_handlers` 的「绝不复制」红线同一层保护）。
///
/// flutter test 的 cwd 是 hibiki 包根。
void main() {
  final String panel =
      File('lib/src/lookup/clipboard_panel_controller.dart').readAsStringSync();
  final String overlay =
      File('lib/src/lookup/global_lookup_controller.dart').readAsStringSync();
  final String shared =
      File('lib/src/lookup/overlay_auto_read.dart').readAsStringSync();

  test('剪贴板面板查到词后触发自动朗读（BUG-1210 的核心缺失）', () {
    expect(panel.contains('autoReadFirstEntry('), true,
        reason: '面板查词成功路径必须调用 autoReadFirstEntry，'
            '否则 autoReadOnLookup 开关对面板完全无效（BUG-1210）');
  });

  test('面板接住播放回报，否则每次自动发音都空耗满 5s 超时', () {
    expect(panel.contains('maybeHandleWordAudioPlayed('), true,
        reason: '面板的 _onJsMessage 必须处理 wordAudioPlayed，'
            '否则 Completer 永远等不到回报、每次都要等满超时才回落 Dart 播放器');
  });

  test('两个表面共用同一份实现，不得各写一份', () {
    for (final ({String name, String src}) surface
        in <({String name, String src})>[
      (name: '剪贴板面板', src: panel),
      (name: '瞬态覆盖窗', src: overlay),
    ]) {
      expect(surface.src.contains('OverlayAutoRead('), true,
          reason: '${surface.name}必须使用共享的 OverlayAutoRead');
      // 私有副本的标志物：自己维护 token / pending 表 / 播放脚本，
      // 正是 BUG-1210 之前两个表面漂开的形态。
      expect(surface.src.contains('_pendingWordAudioPlays'), false,
          reason: '${surface.name}不得自己维护 pending 表——收口到共享实现');
      expect(surface.src.contains('buildPlayWordAudioScript('), false,
          reason: '${surface.name}不得自己拼播放脚本——收口到共享实现');
    }
  });

  test('共享实现保留既有播放契约（WebView 快路径 + 就绪门控 + 超时回落）', () {
    expect(shared.contains('autoReadWordUnified('), true,
        reason: '播放必须走 autoReadWordUnified 单一真相（WebView 快路径 + Dart 兜底）');
    expect(shared.contains('LookupAutoReadCoordinator.instance.runAutomatic('),
        true,
        reason: '必须复用同一去重协调器，避免被动剪贴板流重复同词连读');
    expect(shared.contains('_isWebViewReady()'), true,
        reason: '发播放脚本前必须过就绪门控，否则会顶掉挂起中的整栈渲染脚本');
    expect(shared.contains('autoReadOnLookup'), true, reason: '必须尊重用户的自动朗读开关');
  });
}
