/// 学习语言代码的**唯一真相源**（零 Flutter）：全 app 目前只有日语一种学习语言。
///
/// [JapaneseLanguage] 的 `languageCode` 取自这里；不能 import material 的纯 Dart 宿主
/// （`packages/fushi_engine`、无头服务端 `packages/fushi_server`）经
/// `fushi_dictionary_core.dart` 拿同一个值，不各写一份 `'ja'`、也不靠可选参数的空
/// 默认值静默退化成「没有语言偏好」。
library;

/// 日语的 ISO 639-1 代码。
const String kJapaneseLanguageCode = 'ja';

/// 当前学习语言（字幕挑选等「优先学习语言」的规则用它）。
const String kLearningLanguageCode = kJapaneseLanguageCode;
