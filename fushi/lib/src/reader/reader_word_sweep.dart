import 'package:fushi/src/media/shared/controller_lookup_steps.dart';
import 'package:fushi/src/media/video/subtitle_word_sweep.dart';
import 'package:fushi/src/reader/reader_word_sweep_scripts.dart';

/// 阅读器「整句扫词」的纯逻辑层（拍板台 5H922XeDHM；无 Flutter / 无页面状态）。
///
/// 与视频页共用同一套词序列与游标规则（[buildSubtitleSweepTokens] /
/// [resolveSubtitleSweepStop]：引擎最长匹配分词、句尾循环、跳过整词不可查的词），
/// 区别只在坐标：JS 侧回传的停靠点是句子里的 **UTF-16 码元**下标，这里折算成
/// grapheme 再交给共用函数，落点再折回码元交给 JS 查词。页面侧接线在
/// `reader_fushi/word_sweep.part.dart`，WebView 侧在 [ReaderWordSweepScripts]。

/// 扫词一步的落点：第几个词（[tokenIndex]）、在句子里哪个码元起查（[unit]）。
typedef ReaderWordSweepStop = ({int tokenIndex, int unit});

/// [text] 里每个 UTF-16 码元所属的 grapheme 下标。
List<int> _unitGraphemes(String text) {
  final List<int> starts = controllerLookupGraphemeStarts(text);
  final List<int> out = List<int>.filled(text.length, 0);
  for (int g = 0; g < starts.length; g++) {
    final int end = g + 1 < starts.length ? starts[g + 1] : text.length;
    for (int u = starts[g]; u < end; u++) {
      out[u] = g;
    }
  }
  return out;
}

/// 码元 [unit] 所在的词在 [tokens] 里的下标；不在任何词里（越界）时返回 -1。
int readerWordSweepTokenAt(
  List<SubtitleSweepToken> tokens,
  String text,
  int unit,
) {
  if (unit < 0 || unit >= text.length) return -1;
  final int g = _unitGraphemes(text)[unit];
  for (int i = 0; i < tokens.length; i++) {
    if (g >= tokens[i].graphemeStart && g < tokens[i].graphemeEnd) return i;
  }
  return -1;
}

/// 从游标 [index] 朝 [forward] 走一步的落点。[stops] 是此刻可见、能当查词起点的码元。
///
/// 同一个 grapheme 里有多个停靠码元（基字 + 组合符）时取第一个；整句无停靠点返回 null。
ReaderWordSweepStop? resolveReaderWordSweepStop({
  required String text,
  required List<SubtitleSweepToken> tokens,
  required int index,
  required bool forward,
  required Iterable<int> stops,
}) {
  final List<int> unitGrapheme = _unitGraphemes(text);
  final Map<int, int> firstStopOfGrapheme = <int, int>{};
  for (final int unit in stops) {
    if (unit < 0 || unit >= text.length) continue;
    final int g = unitGrapheme[unit];
    final int? known = firstStopOfGrapheme[g];
    if (known == null || unit < known) firstStopOfGrapheme[g] = unit;
  }
  final SubtitleSweepStop? stop = resolveSubtitleSweepStop(
    tokens: tokens,
    index: index,
    forward: forward,
    selectableGraphemes: firstStopOfGrapheme.keys.toSet(),
  );
  if (stop == null) return null;
  return (
    tokenIndex: stop.tokenIndex,
    unit: firstStopOfGrapheme[stop.graphemeIndex]!,
  );
}

/// 扫词会话（仅内存）：当前句的词序列与词游标。
///
/// 句变即重建（JS 会话号或句子文本变了）；同句重按从上次位置继续。弹窗开着时 JS 回传
/// 本次查词的选区起点（[ReaderWordSweepSentence.at]），游标先对齐到它所在的词——用户
/// 点了句中别的词，下一按就从那个词往后扫，而不是接着上一次扫到的位置。
class ReaderWordSweepSession {
  ReaderWordSweepSession({this.tokenize});

  /// 仅单测注入；生产走 [buildSubtitleSweepTokens] 的默认引擎分词。
  final SubtitleSweepTokenizer? tokenize;

  int _id = -1;
  String _text = '';
  List<SubtitleSweepToken> _tokens = const <SubtitleSweepToken>[];
  int _index = -1;

  /// 当前词下标（-1 = 尚未开始）。
  int get index => _index;

  /// 当前句的词序列。
  List<SubtitleSweepToken> get tokens => _tokens;

  /// 用 [sentence] 推进一步，返回这一步要查的落点；无处可停时返回 null（游标不动）。
  ReaderWordSweepStop? advance(
    ReaderWordSweepSentence sentence, {
    required bool forward,
  }) {
    if (sentence.id != _id || sentence.text != _text) {
      _id = sentence.id;
      _text = sentence.text;
      _tokens = buildSubtitleSweepTokens(sentence.text, tokenize: tokenize);
      _index = -1;
    }
    if (sentence.at >= 0) {
      final int at = readerWordSweepTokenAt(_tokens, _text, sentence.at);
      if (at >= 0) _index = at;
    }
    final ReaderWordSweepStop? stop = resolveReaderWordSweepStop(
      text: _text,
      tokens: _tokens,
      index: _index,
      forward: forward,
      stops: sentence.stops,
    );
    if (stop == null) return null;
    _index = stop.tokenIndex;
    return stop;
  }
}
