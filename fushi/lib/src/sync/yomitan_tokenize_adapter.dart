/// 分词结果的一段：原文片段 + 读音（未命中为空串）。
typedef TokenizedSegment = ({String text, String reading});

/// 分词函数类型：一批文本 -> 每条文本的带读音词片段列表（与 [texts] 等长、按序对应）。
///
/// 对接 `JapaneseLanguage.textsToWordsWithReadingsInBackground`：整批在一个后台 isolate
/// 里切完（扩展整页分词约 177 ms，HBK-AUDIT-009），HTTP 处理器所在的 UI isolate 只等结果。
typedef Tokenizer =
    Future<List<List<TokenizedSegment>>> Function(List<String> texts);

/// 把分词结果包装成 yomitan-api `tokenize` 单条响应形状。
/// 形状：`{ id:"scan", source:<parser>, dictionary:null, index,
/// content: [[{text, reading}], ...] }`（content 二维：每段一个数组）。
/// headwords（首段精简词条）按文档可省略，本版省略（宽松取舍）。
///
/// [segments] 是 [text] 的分词结果；[text] 为空时一律给空 content（不看 [segments]）。
Map<String, dynamic> buildYomitanTokenizeResponse({
  required String text,
  required int index,
  required List<TokenizedSegment> segments,
  String parser = 'scanning-parser',
}) {
  final List<List<Map<String, dynamic>>> content =
      <List<Map<String, dynamic>>>[];
  if (text.isNotEmpty) {
    for (final TokenizedSegment seg in segments) {
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
