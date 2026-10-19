/// 分词结果的一段：原文片段 + 读音（未命中为空串）。
typedef TokenizedSegment = ({String text, String reading});

/// 分词函数类型：文本 -> 带读音的词片段列表（对接
/// `JapaneseLanguage.textToWordsWithReadings`：一次原生调用切完整段并带出每段读音）。
typedef Tokenizer = List<TokenizedSegment> Function(String text);

/// 把分词结果包装成 yomitan-api `tokenize` 单条响应形状。
/// 形状：`{ id:"scan", source:<parser>, dictionary:null, index,
/// content: [[{text, reading}], ...] }`（content 二维：每段一个数组）。
/// headwords（首段精简词条）按文档可省略，本版省略（宽松取舍）。
Map<String, dynamic> buildYomitanTokenizeResponse({
  required String text,
  required int index,
  required Tokenizer tokenize,
  String parser = 'scanning-parser',
}) {
  final List<List<Map<String, dynamic>>> content =
      <List<Map<String, dynamic>>>[];
  if (text.isNotEmpty) {
    for (final TokenizedSegment seg in tokenize(text)) {
      content.add(<Map<String, dynamic>>[
        <String, dynamic>{'text': seg.text, 'reading': seg.reading},
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
