/// 内容语言三档解析（纯函数）。
///
/// 从 app 的 `content_font_chain.dart` 拆出：字体链选择是 UI 关心的事，但
/// 「这本书 / 这个视频的内容语言是什么」是全仓唯一入口，引擎里的字幕语言偏好
/// 与 EPUB 导入都要用。app 的 `content_font_chain.dart` re-export 本函数，调用方
/// 不动。
library;

/// 内容语言解析。三档优先级：
/// 1. [explicit] 该媒体显式设置的内容语言；
/// 2. [metadata] 媒体自带元数据声明的语言（EPUB `dc:language` / 视频刮削）；
/// 3. [globalDefault] 全局设置里的默认内容语言。
///
/// 三档全空返回 null = 语言未知，由调用方决定是保持原样还是用硬编码兜底链。
/// 空串与纯空白一律视为「没设」——偏好默认值是空串，DB 列可能存进空串。
String? resolveContentLanguage({
  String? explicit,
  String? metadata,
  String? globalDefault,
}) {
  for (final String? candidate in <String?>[
    explicit,
    metadata,
    globalDefault,
  ]) {
    final String trimmed = candidate?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// 内容语言归一成主语言子标签小写（`zh-Hant-TW` / `zh_TW` / `ZH` → `zh`，`ja-JP` →
/// `ja`）：同一种语言写法不同不分家。空、`und`、不像语言标签的值（数字、单字母、
/// 超过 8 位）归为空串 = 未知。
///
/// 「同名不同语言的版本」一律按它分：书籍系列归组按语言拆组、刮封面按版本语言挑卷图、
/// 朗读声音按「系列 + 语言」记，判据只有这一份。
String contentLanguageKey(String? raw) {
  final String trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  final String primary = trimmed
      .replaceAll('_', '-')
      .split('-')
      .first
      .toLowerCase();
  if (primary.length < 2 || primary.length > 8 || primary == 'und') return '';
  for (final int unit in primary.codeUnits) {
    if (unit < 0x61 || unit > 0x7a) return '';
  }
  return primary;
}
