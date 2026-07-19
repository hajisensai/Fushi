import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_player_shortcuts.dart';

import '../../pages/video_hibiki_page_source_corpus.dart';

/// BUG-853 回归守卫：日语输入法（Windows 微软 IME）激活时，视频页按空格无法暂停。
///
/// 根因：IME 激活时裸 Space 的 `logicalKey` 被引擎改写成 [LogicalKeyboardKey.process]，
/// 视频页两条空格「播放/暂停」路径（media_kit controls 的 `keyboardShortcuts` 与页级
/// `_withPageSpaceOverride`）都用 `SingleActivator(LogicalKeyboardKey.space)` 匹配
/// `logicalKey`，故 IME 下按空格既不被内层消费、也不被页级兜底消费 → 按了没反应。
/// 修复与阅读器 TODO-847（[resolveReaderSpaceOverride]）同范式：在最外层 Focus 的
/// onKeyEvent 里按**物理键**还原 Space 语义（[isVideoImeSpacePlayPause]）。
void main() {
  group('isVideoImeSpacePlayPause', () {
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
}
