import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

void main() {
  test('resolveMouse maps default middle button to seek action', () {
    final reg = FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);
    expect(
      reg.resolveMouse(1, scope: ShortcutScope.audiobook),
      ShortcutAction.audiobookSeekToClickedSentence,
    );
  });

  test('resolveMouse returns null for unbound button', () {
    final reg = FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);
    expect(reg.resolveMouse(2, scope: ShortcutScope.audiobook), isNull);
  });

  test('resolveMouse respects scope', () {
    final reg = FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);
    expect(reg.resolveMouse(1, scope: ShortcutScope.reader), isNull);
  });

  // BUG-1995：用户报「关闭词典快捷键，小说鼠标侧键可以，视频不行」。根因不是绑定
  // 解析错了，而是 video scope 从未开放鼠标通道——设置页连「添加鼠标按键」入口都
  // 不给，运行时也没有 PointerDownEvent → MouseBinding → 派发的管线。
  test('BUG-1995: video scope 开放鼠标通道，侧键可绑到 videoDismissDict', () {
    final FushiShortcutRegistry reg = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);

    expect(
      ShortcutScope.video.channels.contains(ShortcutChannel.mouse),
      isTrue,
      reason: '通道关着的话设置页不给「添加鼠标按键」入口，用户根本绑不上',
    );

    // 侧键（DOM button 3 = kBackMouseButton）绑到「只关词典」。
    reg.updateBinding(
      ShortcutAction.videoDismissDict,
      const ShortcutBindingSet(mouseBindings: <MouseBinding>[MouseBinding(3)]),
    );

    expect(
      reg.resolveMouse(3, scope: ShortcutScope.video),
      ShortcutAction.videoDismissDict,
    );
    // 未绑的按钮仍然无归属——开通道不等于「什么都接」。
    expect(reg.resolveMouse(4, scope: ShortcutScope.video), isNull);
  });

  test('BUG-1995: videoDismissDict 默认无绑定（不抢用户已有的键）', () {
    final FushiShortcutRegistry reg = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    final ShortcutBindingSet set = reg.bindingsFor(
      ShortcutAction.videoDismissDict,
    );
    expect(set.mouseBindings, isEmpty);
    expect(set.keyboardBindings, isEmpty);
    expect(set.gamepadBindings, isEmpty);
  });

  // v10 → v11 **不得**清理老快照里 video scope 的鼠标绑定。
  //
  // 曾经加过这样一条迁移，理由是「通道关着的那段时间它们从来没生效过」。那是错的：
  // 弹窗输入桥 `dictionaryPopupInputSpecFor` 读的是 `bindingsFor(action)`，不看
  // `scope.channels`；视频页又把整份 video scope 转发给词典浮层。所以那些绑定
  // 今天就在生效（浮层上按侧键关浮层），清掉 = 静默删除用户正在用的配置。
  test('BUG-1995: v11 升级不得删除老快照里 video scope 的鼠标绑定', () {
    final FushiShortcutRegistry reg = FushiShortcutRegistry();
    reg.loadFromJsonString(
      '{"__schema_version__": 10,'
      ' "video_toggle_play_pause": {"mouse": ["MouseBack"], "keyboard": []},'
      ' "reader_dismiss_dict": {"mouse": ["MouseBack"], "keyboard": []}}',
      TargetPlatform.windows,
    );

    expect(
      reg.bindingsFor(ShortcutAction.videoTogglePlayPause).mouseBindings,
      const <MouseBinding>[MouseBinding(3)],
      reason: '这条绑定经词典浮层输入桥今天就在生效，升级不得静默删掉它',
    );
    expect(
      reg.bindingsFor(ShortcutAction.readerDismissDict).mouseBindings,
      const <MouseBinding>[MouseBinding(3)],
      reason: 'reader 的鼠标绑定同样不能被任何迁移误伤',
    );
    // 仍然可解析——这是「它是活的」最直接的证据。
    expect(
      reg.resolveMouse(3, scope: ShortcutScope.video),
      ShortcutAction.videoTogglePlayPause,
    );
  });

  // 同一件事的另一面：通道**关着**的 scope，其鼠标绑定照样解析得出来。
  // 这条钉住「channels 只是设置页的录入门，不是派发门」这个契约本身——只要有人再想
  // 拿「通道没开」推出「绑定是死的」，这里就会红。
  test('BUG-1995: channels 不含 mouse 的 scope，已有鼠标绑定仍可解析', () {
    // 取样从 home 换成 globalExternal：home 本轮接上了真实的鼠标派发入口、通道已开。
    // globalExternal 是**按构造**开不了的那一类（OS 级 RegisterHotKey 的 `HotKey.key`
    // 类型就是 `KeyboardKey`），所以它会长期留在关着的一侧，适合当这条契约的锚点。
    expect(
      ShortcutScope.globalExternal.channels.contains(ShortcutChannel.mouse),
      isFalse,
      reason: '前提：globalExternal 没有开鼠标通道（开了就换一个仍关着的 scope）',
    );

    final FushiShortcutRegistry reg = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    reg.updateBinding(
      ShortcutAction.globalExternalLookup,
      const ShortcutBindingSet(mouseBindings: <MouseBinding>[MouseBinding(4)]),
    );

    expect(
      reg.resolveMouse(4, scope: ShortcutScope.globalExternal),
      ShortcutAction.globalExternalLookup,
      reason: 'resolveMouse 不查 channels —— 通道开关管不着已存在的绑定能否派发',
    );
  });
}
