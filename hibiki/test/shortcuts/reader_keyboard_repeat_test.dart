import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/reader_space_override.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-1370 / BUG-687：长按左右键连续切句 / 连续翻页。
///
/// 根因：阅读器 `_handleKeyEvent` 在解析快捷键前有 `event is! KeyDownEvent` 闸门，
/// 把长按产生的 OS 自动重复 [KeyRepeatEvent] 全部丢弃（字符光标除外），所以按住
/// Ctrl+←/→（有声书上一句/下一句）或用户改绑成裸 ←/→ 的句子导航只触发一次，无法
/// 连续。修复：在闸门之前新增 KeyRepeat 分支，仅对「可重复」动作（翻页 + 有声书上/
/// 下一句）连发，与视频播放器 `SingleActivator(includeRepeats: true)` 及手柄 D-pad
/// 自动重复对齐；离散动作仍一次一按。
///
/// 这里两层守卫：
///   ① [isRepeatableReaderKeyboardShortcut] 纯函数白名单正确性；
///   ② 源码守卫：`_handleKeyEvent` 确有 KeyRepeat 分支，落在 KeyDown-only 闸门之前，
///      经共享解析器 + 白名单谓词执行，且排除原生手柄键与字符光标激活态。
void main() {
  group('isRepeatableReaderKeyboardShortcut 白名单', () {
    test('翻页与有声书上/下一句可随长按连发', () {
      const List<ShortcutAction> repeatable = <ShortcutAction>[
        ShortcutAction.readerPageForward,
        ShortcutAction.readerPageBackward,
        ShortcutAction.audiobookNextSentence,
        ShortcutAction.audiobookPrevSentence,
      ];
      for (final ShortcutAction action in repeatable) {
        expect(isRepeatableReaderKeyboardShortcut(action), isTrue,
            reason: '$action 应可随长按连续触发');
      }
    });

    test('离散动作绝不随长按连发（一次一按）', () {
      const List<ShortcutAction> discrete = <ShortcutAction>[
        ShortcutAction.readerLookupAtCursor,
        ShortcutAction.readerShiftLookup,
        ShortcutAction.readerCreateCardFromPopup,
        ShortcutAction.readerToggleBookmark,
        ShortcutAction.readerToggleChrome,
        ShortcutAction.readerOpenMenu,
        ShortcutAction.readerDismissDict,
        ShortcutAction.audiobookPlayPause,
      ];
      for (final ShortcutAction action in discrete) {
        expect(isRepeatableReaderKeyboardShortcut(action), isFalse,
            reason: '$action 是离散动作，长按不得连发');
      }
    });

    test('未显式列入白名单的 action 默认不可重复', () {
      // 抽样几个非阅读器/离散 action，确保 default 分支返回 false（新增 action 天然
      // 不连发，避免误连发）。
      const List<ShortcutAction> others = <ShortcutAction>[
        ShortcutAction.globalBack,
        ShortcutAction.videoNextSubtitle,
        ShortcutAction.homeTabNext,
      ];
      for (final ShortcutAction action in others) {
        expect(isRepeatableReaderKeyboardShortcut(action), isFalse);
      }
    });
  });

  group('_handleKeyEvent KeyRepeat 分支源码守卫', () {
    late final String reader = readReaderPageSource();

    test('存在 KeyRepeat 分支并落在 KeyDown-only 闸门之前', () {
      final int repeatIdx = reader.indexOf('if (event is KeyRepeatEvent) {');
      expect(repeatIdx, isNonNegative,
          reason: '_handleKeyEvent 必须显式处理 KeyRepeatEvent 才能长按连发');
      final int gateIdx = reader.indexOf(
        'if (event is! KeyDownEvent) return KeyEventResult.ignored;',
        repeatIdx,
      );
      expect(gateIdx, isNonNegative);
      expect(repeatIdx, lessThan(gateIdx),
          reason: 'KeyRepeat 分支必须在 KeyDown-only 闸门之前，否则闸门先拦掉重复事件');
    });

    test('长按分支经共享解析器 + 白名单谓词执行，且排除手柄键与光标激活态', () {
      final int repeatIdx = reader.indexOf('if (event is KeyRepeatEvent) {');
      final int nextGate = reader.indexOf(
        'if (event is! KeyDownEvent) return KeyEventResult.ignored;',
        repeatIdx,
      );
      final String branch = reader.substring(repeatIdx, nextGate);
      // 白名单谓词把关，只连发可重复动作。
      expect(branch, contains('isRepeatableReaderKeyboardShortcut('),
          reason: '长按分支必须用白名单谓词过滤，离散动作不得连发');
      // 共享解析器：KeyDown 与 KeyRepeat 两路解析一致。
      expect(branch, contains('_resolveReaderKeyboardShortcut('));
      // 字符光标激活时它自己的重复分支在上面处理，长按分支让位。
      expect(branch, contains('_focusNavEnabled && _caretActive'));
      // 原生手柄键（含 Android D-pad 的 KeyRepeat）保持按下沿路由，不进键盘长按分支。
      expect(branch, contains('GamepadButton.fromKeyEvent(event) != null'));
    });

    test('KeyDown 与 KeyRepeat 复用同一解析器 _resolveReaderKeyboardShortcut', () {
      // 解析器被定义一次、且两条路径都调用它（至少两处调用点）。
      expect(
          reader, contains('ShortcutAction? _resolveReaderKeyboardShortcut('));
      final int calls =
          '_resolveReaderKeyboardShortcut('.allMatches(reader).length;
      // 1 处定义 + 2 处调用（KeyDown 路径 + KeyRepeat 路径）。
      expect(calls, greaterThanOrEqualTo(3),
          reason: 'KeyDown 与 KeyRepeat 必须共用同一解析器，避免两路解析漂移');
    });
  });
}
