import 'dart:convert';

import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// 单一真相：哪个 DOM 鼠标按钮触发「seek 到点击句」由快捷键注册表决定（默认中键）。
/// 鼠标键是位置型动作，不进位置无关的 `_executeShortcutAction`，故单列此判定供
/// 阅读器与歌词两处复用、并可纯测。
bool isSeekToClickedSentenceButton(
  HibikiShortcutRegistry registry,
  int button,
) {
  if (button < 0) return false;
  return registry.resolveMouse(button, scope: ShortcutScope.audiobook) ==
      ShortcutAction.audiobookSeekToClickedSentence;
}

/// 歌词模式中键决策：按钮命中绑定且 [idx] 在 [lyricsCues] 范围内时返回目标 cue，
/// 否则返回 null（不播）。把按钮闸门 + 越界检查抽成纯函数以便真测行为。
AudioCue? cueForLyricsPointer(
  HibikiShortcutRegistry registry,
  int button,
  int idx,
  List<AudioCue> lyricsCues,
) {
  if (!isSeekToClickedSentenceButton(registry, button)) return null;
  if (idx < 0 || idx >= lyricsCues.length) return null;
  return lyricsCues[idx];
}

/// 把 `hoshiReader.cueIdAtPoint` 回传的 JSON（`{type,id}`）解析到 [allCues]
/// 里的目标 cue。`type=='sid'` 按 sentenceIndex（字符串 id，合成书 [data-cue-id]），
/// `type=='frag'` 按 textFragmentId（Sasayaki 原生 EPUB）。无法解析或无命中返回
/// null。纯函数，便于单测 payload→cue 反查而无需真实 WebView。
AudioCue? cueForPointerPayload(String json, List<AudioCue> allCues) {
  if (json.isEmpty || json == 'null') return null;
  try {
    final Object? decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    final String? type = decoded['type'] as String?;
    if (type == 'sid') {
      final int sid = int.tryParse('${decoded['id']}') ?? -1;
      final int i = allCues.indexWhere((c) => c.sentenceIndex == sid);
      return i >= 0 ? allCues[i] : null;
    }
    if (type == 'frag') {
      final String fragId = '${decoded['id']}';
      final int i = allCues.indexWhere((c) => c.textFragmentId == fragId);
      return i >= 0 ? allCues[i] : null;
    }
  } catch (_) {
    // Malformed payload — treat as "no cue".
  }
  return null;
}
