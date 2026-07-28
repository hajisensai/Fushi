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
  /// 剥掉整行 `//` 注释后再扫。讲「BUG-1210 之前长什么样」「这一步为什么不能省」的
  /// 注释里必然写着下面要断言的每一个符号名，连注释一起扫等于让文档给自己背书：
  /// 把真实实现删光、只留注释也照样绿。**变异实测证实过**——删掉共享实现里
  /// `if (!ReaderHibikiSource.instance.autoReadOnLookup) return;`（即用户明确关掉
  /// 自动朗读也照读不误）后，本测试原版仍然全绿。
  String stripComments(String src) => src
      .split('\n')
      .where((String l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  final String panel = stripComments(
      File('lib/src/lookup/clipboard_panel_controller.dart')
          .readAsStringSync());
  final String overlay = stripComments(
      File('lib/src/lookup/global_lookup_controller.dart').readAsStringSync());
  final String shared = stripComments(
      File('lib/src/lookup/overlay_auto_read.dart').readAsStringSync());

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

  test('两个表面各自注入自己的 native 通道（不得共用一个）', () {
    // 共享的是**逻辑**，不是通道：覆盖窗走 GlobalLookupChannel、面板走
    // OverlayWindowChannel(_channel)。注错通道 = 播放脚本发进另一个窗口，
    // 表现为「面板查词，声音从看不见的覆盖窗出」或干脆不响。
    expect(overlay.contains("label: 'overlay'"), true,
        reason: '覆盖窗必须用自己的 label，日志才分得清来源');
    expect(overlay.contains('GlobalLookupChannel.render'), true,
        reason: '覆盖窗必须注入自己的渲染通道');
    expect(panel.contains("label: 'panel'"), true, reason: '面板必须用自己的 label');
    expect(panel.contains('_channel.render'), true,
        reason: '面板必须注入自己的渲染通道（OverlayWindowChannel），不得借用覆盖窗的');
  });

  test('面板朗读前必须核对 latest-wins 序号（不能读出已被顶掉的旧词）', () {
    // 面板 update() 的契约是「每个 await 后核对 seq，过期即弃」（VN 流乱序守卫），
    // 而朗读调用排在 _renderPanel 这个 await 之后。少这一句核对，被后一句顶掉的
    // 旧查词仍会把**旧词**读出来——屏幕上是新句、耳朵里是上一句。面板正是被动
    // 剪贴板流（galgame 台词 / texthooker）的主力表面，快速连续更新是它的常态。
    // 覆盖窗没有 latest-wins 机制，故这是面板独有的契约，收口共享实现时最容易被
    // 一起抹掉——本 PR 初版就漏了这一步。
    final int callIdx = panel.indexOf('_autoRead.autoReadFirstEntry(');
    expect(callIdx, greaterThanOrEqualTo(0),
        reason: '面板必须调用 autoReadFirstEntry；守卫锚点失效请同步更新本测试');
    // 判据必须是「**最后一个 await 之后**有核对」，不能是「往前 N 字符内有核对」——
    // update() 里本来就有好几处 seq 核对（_showPanel / raise 分支各一处），固定窗口
    // 会够到那些，删掉朗读前这一句照样绿（变异实测漏过一次）。
    final String before = panel.substring(0, callIdx);
    final int lastAwait = before.lastIndexOf('await ');
    expect(lastAwait, greaterThanOrEqualTo(0),
        reason: '朗读调用前应有 await（渲染）；守卫锚点失效请同步更新本测试');
    expect(before.substring(lastAwait).contains('seq != _updateSeq'), true,
        reason: '朗读调用与它前面最后一个 await 之间必须核对 latest-wins 序号，'
            '否则被顶掉的旧查词会读出与屏幕不符的旧词（BUG-1210）');
  });
}
