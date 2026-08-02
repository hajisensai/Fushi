import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_player_shortcuts.dart';
import 'package:hibiki/src/platform/windows_ime_space_channel.dart';
import 'package:hibiki/src/platform/windows_ime_space_dispatch.dart';

import '../../pages/video_hibiki_page_source_corpus.dart';

/// ⚠️ 部分假绿（2026-08-02 定性）：group
/// `[假绿·前提已证伪] isVideoImeSpacePlayPause` 的**断言前提已被引擎源码证伪**。
///
/// 那 6 条用例手工构造 `LogicalKeyboardKey.process`（及「其它 IME 改写值」）+ 物理
/// Space 的合成事件，而引擎在本仓 5 个出包平台上**根本不产生这类事件**：
/// - `process` 是 **Flutter Web 专有**值，裸 keyId `0x0010000070f` 全 engine 树只出现
///   3 处——web 引擎 `lib/web_ui/lib/src/engine/key_map.g.dart:237`（唯一生产用）+
///   Android / embedder 两个 **test util**；原生端生产键表全无。
/// - Windows 上被 IME 消费的键由
///   `shell/platform/windows/keyboard_key_embedder_handler.cc:177-183` 在 `VK_PROCESSKEY`
///   时直接 `callback(true); return;`（注释原文 "not sent to Flutter"）⇒ Dart 侧连
///   事件都收不到，更没有可用的 `physicalKey`（下面 BUG-1239 段落记录的 physical/
///   logical 均为 0 正是同一事实的另一面）。
///
/// ⇒ 该组绿灯**不代表用户症状被修好**，也永远不会因真机失效而转红——BUG-853 当年
/// 就是单测全绿、用户真机复报（即 BUG-936）。**不要当成回归保护。**
/// 保留是因为它钉的是纯谓词的分支行为，将来真修复时可能还要复用。
///
/// ✅ 本文件其余用例（`BUG-1239 native IME Space channel …` / `BUG-1239 native
/// notification Dart ownership gate` / 两条源码守卫）走的是 runner 侧 Win32 拦截
/// 这套**另一条真实契约**，不在假绿之列。
/// 事实守卫见 `test/shortcuts/ime_process_key_reachability_guard_test.dart`（BUG-1432）；
/// 定性见 `docs/bugs/BUG-936-video-ime-space-playpause.md` 的「根因证伪」栏。
///
/// 以下为原始说明（存档）：
/// BUG-853 回归守卫：日语输入法（Windows 微软 IME）激活时，视频页按空格无法暂停。
///
/// 根因：IME 激活时裸 Space 的 `logicalKey` 被引擎改写成 [LogicalKeyboardKey.process]，
/// 视频页两条空格「播放/暂停」路径（media_kit controls 的 `keyboardShortcuts` 与页级
/// `_withPageSpaceOverride`）都用 `SingleActivator(LogicalKeyboardKey.space)` 匹配
/// `logicalKey`，故 IME 下按空格既不被内层消费、也不被页级兜底消费 → 按了没反应。
/// 修复与阅读器 TODO-847（[resolveReaderSpaceOverride]）同范式：在最外层 Focus 的
/// onKeyEvent 里按**物理键**还原 Space 语义（[isVideoImeSpacePlayPause]）。
///
/// BUG-936：BUG-853 只认 `logicalKey == process` 这一种 IME 改写值，真机仍失效——日文 IME
/// 在不同输入模式下把物理空格改写成的逻辑键未必是 `process`。改判据为「物理键是 Space +
/// 逻辑键非裸 space」，覆盖 `process` 及任意其它 IME 改写值。
///
/// BUG-1239：前两轮仍建立在错误前提上。Flutter Windows 引擎会把 `VK_PROCESSKEY`
/// 事件降成 physical/logical key 均为 0，Dart 层根本拿不到旧修复依赖的物理 Space。
/// runner 必须在交给 Flutter 前从 Win32 lParam 的 scan code 识别 Space，再经专用
/// MethodChannel 通知当前视频页。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('[假绿·前提已证伪] isVideoImeSpacePlayPause', () {
    test('IME 改写成 process 的物理空格（无修饰、无文本框）→ 命中', () {
      expect(
        isVideoImeSpacePlayPause(
          logicalKey: LogicalKeyboardKey.process,
          physicalKey: PhysicalKeyboardKey.space,
          hasModifier: false,
          hasEditableFocus: false,
        ),
        isTrue,
      );
    });

    test('BUG-936：IME 改写成非 process 的其它逻辑键但物理是空格 → 仍命中', () {
      // 日文 IME 在某些模式下把物理空格的逻辑键改写成非 process 值（这里以 nonConvert
      // 代表任意 IME 改写值）。旧的 `logicalKey == process` 判据会漏掉，导致真机仍失效。
      expect(
        isVideoImeSpacePlayPause(
          logicalKey: LogicalKeyboardKey.nonConvert,
          physicalKey: PhysicalKeyboardKey.space,
          hasModifier: false,
          hasEditableFocus: false,
        ),
        isTrue,
      );
    });

    test('带修饰键（Ctrl/Shift/Alt/Meta）→ 不命中，交回原义', () {
      expect(
        isVideoImeSpacePlayPause(
          logicalKey: LogicalKeyboardKey.process,
          physicalKey: PhysicalKeyboardKey.space,
          hasModifier: true,
          hasEditableFocus: false,
        ),
        isFalse,
      );
    });

    test('文本框正在 composing（hasEditableFocus）→ 不命中，避免变换候选词误触', () {
      expect(
        isVideoImeSpacePlayPause(
          logicalKey: LogicalKeyboardKey.process,
          physicalKey: PhysicalKeyboardKey.space,
          hasModifier: false,
          hasEditableFocus: true,
        ),
        isFalse,
      );
    });

    test('裸逻辑空格（非 process）→ 不命中：交回既有 SingleActivator 路径不变', () {
      expect(
        isVideoImeSpacePlayPause(
          logicalKey: LogicalKeyboardKey.space,
          physicalKey: PhysicalKeyboardKey.space,
          hasModifier: false,
          hasEditableFocus: false,
        ),
        isFalse,
      );
    });

    test('process 但物理键不是空格（IME 改写的其它键）→ 不命中', () {
      expect(
        isVideoImeSpacePlayPause(
          logicalKey: LogicalKeyboardKey.process,
          physicalKey: PhysicalKeyboardKey.keyA,
          hasModifier: false,
          hasEditableFocus: false,
        ),
        isFalse,
      );
    });
  });

  test('视频页最外层 Focus.onKeyEvent 接入 IME 空格回退（源码守卫）', () {
    final String src = readVideoHibikiSource();

    // 回退 helper 存在，且经沉浸锁门控触发与页级覆盖同语义的 playOrPause。
    final int start = src.indexOf('bool _handleVideoImeSpacePlayPause(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '_handleVideoImeSpacePlayPause 回退 helper 必须存在');
    final int end = src.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body, contains('isVideoImeSpacePlayPause'),
        reason: '必须复用可单测的纯谓词识别 IME 空格');
    expect(body, contains('focusedEditableText()'),
        reason: '必须在文本框 composing 时关闭回退');
    expect(body, contains('_runWhenImmersiveAllowsShortcuts'),
        reason: '必须经沉浸锁快捷键门控（与页级 _withPageSpaceOverride 同语义）');
    expect(body, contains('controller.playOrPause()'),
        reason: 'IME 空格应触发播放/暂停');

    // 真正接入最外层手柄 Focus 的 onKeyEvent（否则 helper 是死代码，IME 空格到不了它）。
    expect(src, contains('_handleVideoImeSpacePlayPause(event)'),
        reason: '_wrapVideoGamepadControls 的 Focus.onKeyEvent 必须先调 IME 空格回退');
  });

  test('BUG-1239 native IME Space channel 只派发约定方法并按 owner 清理', () async {
    final Object owner = Object();
    int calls = 0;
    WindowsImeSpaceChannel.setHandler(owner, () => calls++);

    await WindowsImeSpaceChannel.debugDispatch(
      const MethodCall('unknownMethod'),
    );
    expect(calls, 0);

    await WindowsImeSpaceChannel.debugDispatch(
      const MethodCall('onImeSpaceDown'),
    );
    expect(calls, 1);

    WindowsImeSpaceChannel.clearHandler(Object());
    await WindowsImeSpaceChannel.debugDispatch(
      const MethodCall('onImeSpaceDown'),
    );
    expect(calls, 2, reason: '旧 route 不得清掉新 owner 的 handler');

    WindowsImeSpaceChannel.clearHandler(owner);
    await WindowsImeSpaceChannel.debugDispatch(
      const MethodCall('onImeSpaceDown'),
    );
    expect(calls, 2);
  });

  group('BUG-1239 native notification Dart ownership gate', () {
    WindowsImeSpaceDispatchAction resolve({
      bool mounted = true,
      bool hasController = true,
      bool isCurrentRoute = true,
      bool hasEditableFocus = false,
      bool hasVisiblePopup = false,
      bool immersiveAllowsShortcuts = true,
    }) {
      return resolveWindowsImeSpaceDispatch(
        mounted: mounted,
        hasController: hasController,
        isCurrentRoute: isCurrentRoute,
        hasEditableFocus: hasEditableFocus,
        hasVisiblePopup: hasVisiblePopup,
        immersiveAllowsShortcuts: immersiveAllowsShortcuts,
      );
    }

    test('当前视频、无编辑焦点且允许快捷键 → 只触发播放暂停', () {
      expect(
        resolve(),
        WindowsImeSpaceDispatchAction.togglePlayPause,
      );
    });

    test('IME composing / 输入框 / 字幕搜索编辑焦点 → 放行', () {
      expect(
        resolve(hasEditableFocus: true),
        WindowsImeSpaceDispatchAction.ignore,
      );
    });

    test('非当前路由、已销毁、无 controller 或沉浸禁用 → 放行', () {
      expect(
        resolve(isCurrentRoute: false),
        WindowsImeSpaceDispatchAction.ignore,
      );
      expect(resolve(mounted: false), WindowsImeSpaceDispatchAction.ignore);
      expect(
        resolve(hasController: false),
        WindowsImeSpaceDispatchAction.ignore,
      );
      expect(
        resolve(immersiveAllowsShortcuts: false),
        WindowsImeSpaceDispatchAction.ignore,
      );
    });

    test('词典浮层优先只关闭一次，不穿透播放暂停', () {
      expect(
        resolve(hasVisiblePopup: true),
        WindowsImeSpaceDispatchAction.dismissPopup,
      );
    });
  });

  test('BUG-1239 视频页注册 native 通道并守住路由/文本框/浮层边界', () {
    final String src = readVideoHibikiSource();
    expect(
      src,
      contains(
        'WindowsImeSpaceChannel.setHandler(this, _handleWindowsImeSpaceDown)',
      ),
    );
    expect(
      src,
      contains('WindowsImeSpaceChannel.clearHandler(this)'),
    );

    final int start = src.indexOf('void _handleWindowsImeSpaceDown()');
    final int end = src.indexOf('\n  }', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body, contains('_videoFullscreenRoute'));
    expect(body, contains('owner == null || owner.isCurrent'));
    expect(body, contains('focusedEditableText()'));
    expect(body, contains('_hasVisiblePopup'));
    expect(body, contains('_dismissTopVisiblePopup()'));
    expect(body, contains('resolveWindowsImeSpaceDispatch'));
    expect(body, contains('controller.playOrPause()'));
  });
}
