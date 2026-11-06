/// 截屏识字送给系统 OCR（Android ML Kit / Apple Vision / Windows.Media.Ocr）的
/// 语言：悬浮球截屏识字、桌面冻结层、拍照查词、浏览器「对图片 OCR」、AI 读屏
/// 全走这一个判据。
///
/// 跟随「默认内容语言」（`default_content_language`，与查词按中文处理同一个
/// 设置）：设成中文时截屏识字用中文识别器，学中文的用户不用另找开关。没设
/// （出厂为空）时回落日语，与此前写死 `ja` 的行为一致。三端原生都按 BCP-47
/// 主子标签匹配识别器，`zh` / `zh-Hans` / `zh-TW` 都能落到中文识别器。
library;

/// 「默认内容语言」没设时截屏识字用的语言（Fushi 出厂面向日语）。
const String kScreenOcrFallbackLanguage = 'ja';

/// [defaultContentLanguage] 为空（含只有空白）时回落 [kScreenOcrFallbackLanguage]，
/// 否则原样交给原生（去掉首尾空白）。
String resolveScreenOcrLanguage(String defaultContentLanguage) {
  final String tag = defaultContentLanguage.trim();
  return tag.isEmpty ? kScreenOcrFallbackLanguage : tag;
}
