import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

/// 有声书激活时，无修饰 Space 改作播放/暂停（媒体播放器惯例）。
///
/// 设计：阅读器键盘解析里 reader scope 先于 audiobook scope，默认绑定中
/// Space=翻页、Ctrl+Space=播放/暂停，导致有声书场景按 Space 永远翻页。
/// 本函数仅在「有声书已激活 + 无任何修饰键 + 是 Space」时返回
/// [ShortcutAction.audiobookPlayPause] 覆写翻页；其余一律返回 null 表示
/// 不覆写，交回默认解析（翻页仍可用方向键/PageDown；Shift+Space 仍后退翻页；
/// Ctrl+Space 保留原义）。
ShortcutAction? resolveReaderSpaceOverride({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool hasActiveAudiobook,
}) {
  if (key != LogicalKeyboardKey.space) return null;
  if (modifiers.isNotEmpty) return null;
  if (!hasActiveAudiobook) return null;
  return ShortcutAction.audiobookPlayPause;
}
