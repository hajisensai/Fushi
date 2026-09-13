/// manga-ocr 的字符级 BERT tokenizer（仅解码方向）。
///
/// 词表来自模型仓库的 `vocab.txt`（每行一个 token，行号即 id），特殊符号
/// 沿用 BERT 惯例：[PAD] / [UNK] / [CLS] / [SEP] / [MASK]。解码时跳过特殊
/// 符号、剥掉 wordpiece 的 "##" 连写前缀，并做 manga-ocr 同款后处理
/// （去空白 + 省略号/连点归一）。
library;

/// 字符级 tokenizer（解码用）。
class MangaOcrTokenizer {
  MangaOcrTokenizer._(this._idToToken, this._specialIds, this.clsId, this.sepId,
      this.padId, this.unkId);

  /// 从 `vocab.txt` 文本构建（每行一个 token）。
  factory MangaOcrTokenizer.fromVocabText(String vocabText) {
    final List<String> tokens = vocabText
        .split('\n')
        .map((String line) => line.replaceAll('\r', ''))
        .toList();
    // vocab.txt 末尾可能有一个空行；中间不应有空 token。
    while (tokens.isNotEmpty && tokens.last.isEmpty) {
      tokens.removeLast();
    }
    int require(String token) {
      final int id = tokens.indexOf(token);
      if (id < 0) {
        throw FormatException('vocab.txt missing special token $token');
      }
      return id;
    }

    final int cls = require('[CLS]');
    final int sep = require('[SEP]');
    final int pad = require('[PAD]');
    final int unk = require('[UNK]');
    final Set<int> special = <int>{cls, sep, pad, unk};
    final int mask = tokens.indexOf('[MASK]');
    if (mask >= 0) {
      special.add(mask);
    }
    return MangaOcrTokenizer._(tokens, special, cls, sep, pad, unk);
  }

  final List<String> _idToToken;
  final Set<int> _specialIds;

  final int clsId;
  final int sepId;
  final int padId;
  final int unkId;

  int get vocabSize => _idToToken.length;

  /// id 序列 -> 文本。跳过特殊符号，"##x" 还原为 "x"。
  String decode(Iterable<int> ids) {
    final StringBuffer buffer = StringBuffer();
    for (final int id in ids) {
      if (id < 0 || id >= _idToToken.length || _specialIds.contains(id)) {
        continue;
      }
      final String token = _idToToken[id];
      buffer.write(token.startsWith('##') ? token.substring(2) : token);
    }
    return postProcess(buffer.toString());
  }

  /// manga-ocr `post_process`：去所有空白；"…" -> "..."；
  /// 连续 2 个以上的 [・.] 归一为等长的 "."。
  static String postProcess(String text) {
    String result = text.replaceAll(RegExp(r'\s+'), '');
    result = result.replaceAll('…', '...');
    result = result.replaceAllMapped(
      RegExp(r'[・.]{2,}'),
      (Match m) => '.' * (m.end - m.start),
    );
    return result;
  }
}
