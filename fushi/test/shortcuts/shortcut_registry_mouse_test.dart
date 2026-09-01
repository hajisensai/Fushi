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
    final ShortcutBindingSet set =
        reg.bindingsFor(ShortcutAction.videoDismissDict);
    expect(set.mouseBindings, isEmpty);
    expect(set.keyboardBindings, isEmpty);
    expect(set.gamepadBindings, isEmpty);
  });

  // v11 迁移：video scope 的鼠标通道**历史上开过**，那期间绑上去的键从来没有生效过
  // （没有派发管线）。现在管线建好了，若不清理，那些被遗忘的绑定会突然开始真的执行
  // ——「下一句」「切换全屏」在用户眼里就是升级后侧键行为凭空变了。
  test('BUG-1995: v11 迁移清掉老快照里 video scope 的死鼠标绑定', () {
    final FushiShortcutRegistry reg = FushiShortcutRegistry();
    reg.loadFromJsonString(
      '{"__schema_version__": 10,'
      ' "video_toggle_play_pause": {"mouse": ["MouseBack"], "keyboard": []},'
      ' "reader_dismiss_dict": {"mouse": ["MouseBack"], "keyboard": []}}',
      TargetPlatform.windows,
    );

    expect(
      reg.bindingsFor(ShortcutAction.videoTogglePlayPause).mouseBindings,
      isEmpty,
      reason: '从未生效过的 video 鼠标绑定必须清掉，否则升级后突然开始触发',
    );
    expect(
      reg.bindingsFor(ShortcutAction.readerDismissDict).mouseBindings,
      const <MouseBinding>[MouseBinding(3)],
      reason: 'reader 的鼠标绑定一直是真实生效的，绝不能被这条迁移误伤',
    );
  });
}
