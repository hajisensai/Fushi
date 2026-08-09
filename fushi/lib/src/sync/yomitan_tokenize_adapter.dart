/// 分词函数类型：文本 -> 词片段列表（对接 JapaneseLanguage.textToWords）。
typedef Tokenizer = List<String> Function(String text);

/// 读音解析函数类型：词 -> 读音（命中返回假名，未命中返回空串）。
typedef ReadingResolver = String Function(String word);

/// 把分词结果包装成 yomitan-api `tokenize` 单条响应形状。
/// 形状：`{ id:"scan", source:<parser>, dictionary:null, index,
/// content: [[{text, reading}], ...] }`（content 二维：每段一个数组）。
/// headwords（首段精简词条）按文档可省略，本版省略（宽松取舍）。
Map<String, dynamic> buildYomitanTokenizeResponse({
  required String text,
  required int index,
  required Tokenizer tokenize,
  required ReadingResolver readingOf,
  String parser = 'scanning-parser',
}) {
  final List<List<Map<String, dynamic>>> content =
      <List<Map<String, dynamic>>>[];
  if (text.isNotEmpty) {
    for (final String seg in tokenize(text)) {
      content.add(<Map<String, dynamic>>[
        <String, dynamic>{'text': seg, 'reading': readingOf(seg)},
      ]);
    }
  }
  return <String, dynamic>{
    'id': 'scan',
    'source': parser,
    'dictionary': null,
    'index': index,
    'content': content,
  };
}
