/// 阅读器 WebView 侧「学习单位」计数判据的**唯一** JS 源。
///
/// Dart 侧的对应实现是 `package:fushi/src/stats/study_char_count.dart` 的
/// [countStudyChars]，两份必须同口径——JS 算出的 `charOffset` 会写进 DB 的
/// `char_offset` 列，并在 `absoluteCharOffsetOf`（`reader_fushi_page.dart`）与
/// `computeBookProgress`（`reader_fushi_source.dart`）里与 Dart 算出的每章
/// `characters` **直接相加**。对拍守卫见
/// `fushi/test/stats/study_char_count_parity_test.dart`（node 真跑本段 JS）。
///
/// ## 为什么是「单位结束」而不是「这个字符计不计」
///
/// 旧判据 `isMatchableChar(char)` 只看单个字符，逐字符累加即得字数。新口径里西文
/// 一整串字母才算**一个**单位，单看一个字符答不了「计不计」。但所有调用点都在按
/// 顺序走同一段文本、且手里有 `text` 与下标，所以把谓词换成
/// `isUnitEnd(text, index)`——「这个位置是不是一个学习单位的最后一个码点」——逐位置
/// 累加仍然得到正确单位数，而且每个调用点只需改一行，几何与结构一律不动。
///
/// 前缀语义：`isUnitEnd` 只在词串**结束**处计数，所以走到词中间的前缀比
/// [countStudyChars] 对同一前缀少算 1（那一个词还没写完）。整段文本走完两者一致，
/// 而 `buildNodeOffsets` / `charOffsetInRange` 用的是整节点总数，`scrollToCharOffset`
/// 用的是同一套逐位置累加的逆向查找——同口径闭合，不会互相错位。
///
/// ## 与匹配 / 归一化的分界
///
/// `isMatchableChar` / `normalizeText` / `readerRegexNegated` **不动**：那套白名单是
/// 有声书 cue 重定位（`foldNormalize`、`buildSentenceAudioNormIndex`）和纯图片章判定
/// 的坐标系，与 Dart 的 `AudioTextNormalizer` 逐值对齐，跟着改会打断有声书高亮。
/// 计数与匹配是两个问题，这次只统一计数那一个。
library;

/// 定义 `window.fushiStudyUnits`（幂等）。两个 shell 各自内嵌同一份，谁先跑谁定义，
/// 不引入注入顺序依赖。
const String kStudyUnitJs = r"""
if (!window.fushiStudyUnits) {
  window.fushiStudyUnits = (function() {
    // 与 Dart study_char_count.dart 逐条对应：透明 / 字母数字 / 无空格文字。
    var TRANSPARENT = /[\p{M}\u200C\u200D'\u2019\u02BC]/u;
    var LETTER_OR_NUMBER = /[\p{L}\p{N}]/u;
    var NO_SPACE_SCRIPT = /[\p{Script_Extensions=Han}\p{Script_Extensions=Hiragana}\p{Script_Extensions=Katakana}\p{Script_Extensions=Hangul}\p{Script_Extensions=Bopomofo}\p{Script_Extensions=Yi}\p{Script_Extensions=Thai}\p{Script_Extensions=Lao}\p{Script_Extensions=Khmer}\p{Script_Extensions=Myanmar}\p{Script_Extensions=Tibetan}]/u;

    // 0 = 透明（不计数、不断词）；1 = 无空格文字（每码点一个单位）；
    // 2 = 空格分词文字的字母数字（连续串算一个单位）；3 = 分隔符。
    function classify(ch) {
      if (TRANSPARENT.test(ch)) return 0;
      if (LETTER_OR_NUMBER.test(ch)) return NO_SPACE_SCRIPT.test(ch) ? 1 : 2;
      return 3;
    }

    function charAt(text, index) {
      var cp = text.codePointAt(index);
      return cp === undefined ? '' : String.fromCodePoint(cp);
    }

    // [index] 处的码点是否是一个学习单位的最后一个码点。
    // 无空格文字：每个码点自成一个单位 → 恒 true。
    // 空格分词文字：只有当后面第一个非透明码点不再是同类字母数字时才算结束。
    function isUnitEnd(text, index) {
      var s = String(text || '');
      if (index < 0 || index >= s.length) return false;
      var ch = charAt(s, index);
      if (!ch) return false;
      var kind = classify(ch);
      if (kind === 1) return true;
      if (kind !== 2) return false;
      var i = index + ch.length;
      while (i < s.length) {
        var next = charAt(s, i);
        if (!next) break;
        var nk = classify(next);
        if (nk === 0) { i += next.length; continue; } // 透明：继续往后看
        return nk !== 2;
      }
      return true; // 文本到头，词串在此结束
    }

    // 整段文本的学习单位数。与 Dart countStudyChars 同口径。
    function count(text) {
      var s = String(text || '');
      var total = 0;
      var inWord = false;
      for (var i = 0; i < s.length;) {
        var ch = charAt(s, i);
        if (!ch) break;
        i += ch.length;
        var kind = classify(ch);
        if (kind === 0) continue;
        if (kind === 1) {
          if (inWord) { total++; inWord = false; }
          total++;
        } else if (kind === 2) {
          inWord = true;
        } else if (inWord) {
          total++;
          inWord = false;
        }
      }
      return inWord ? total + 1 : total;
    }

    return { isUnitEnd: isUnitEnd, count: count };
  })();
}
""";
