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
    globalDefault
  ]) {
    final String trimmed = candidate?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}
