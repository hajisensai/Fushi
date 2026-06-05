import 'dart:convert';

import 'package:hibiki_audio/hibiki_audio.dart';

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
