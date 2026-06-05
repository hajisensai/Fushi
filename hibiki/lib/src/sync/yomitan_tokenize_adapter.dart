/// 分词函数类型：文本 -> 词片段列表（对接 JapaneseLanguage.textToWords）。
typedef Tokenizer = List<String> Function(String text);

/// 读音解析函数类型：词 -> 读音（命中返回假名，未命中返回空串）。
typedef ReadingResolver = String Function(String word);

/// 把分词结果包装成 yomitan-api `tokenize` 单条响应形状。
/// 形状：`{ id, source, dictionary, index, content: [{text, reading}] }`。
Map<String, dynamic> buildYomitanTokenizeResponse({
  required String text,
  required int index,
  required Tokenizer tokenize,
  required ReadingResolver readingOf,
}) {
  final List<Map<String, dynamic>> content = <Map<String, dynamic>>[];
  if (text.isNotEmpty) {
    for (final String seg in tokenize(text)) {
      content.add(<String, dynamic>{
        'text': seg,
        'reading': readingOf(seg),
      });
    }
  }
  return <String, dynamic>{
    'id': index,
    'source': text,
    'dictionary': 'Hibiki',
    'index': index,
    'content': content,
  };
}
