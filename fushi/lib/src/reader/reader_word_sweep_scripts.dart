import 'dart:convert';

/// 阅读器「整句扫词」的 WebView 侧（拍板台 5H922XeDHM，照视频页
/// `video_fushi/word_sweep.part.dart` 的契约）。
///
/// 职责只有两件，且都只读 DOM、不碰字级光标（`window.fushiCaret` /
/// `window.fushiLyricsCaret`）的任何状态——扫词的全部价值就是「不进模态」：
///
/// 1. [sentenceInvocation]：定出**当前句**，把它按文档序摊平成一串字符
///    （每个 UTF-16 码元对应一个 `(文本节点, 偏移)`），连同「此刻屏上可见、能当查词
///    起点」的码元下标一起回传。分词放在 Dart（与视频页同一个
///    `buildSubtitleSweepTokens`，即词典引擎最长匹配），因为 `isScanBoundary` /
///    `isTokenStartBoundary` 只认空白 / 标点 / 文种切换，日文整段无空格，靠它们切出来
///    的是一整个分句而不是词。
/// 2. [lookupInvocation]：把 Dart 选定的码元下标映射回 `(节点, 偏移)`，走与字级光标
///    查词**逐字相同**的 `clearSelection()` + `selectFromPosition(node, offset, 400)`
///    （→ `onTextSelected` → 阅读器 `_handleTextSelected`），弹 / 换同一张弹窗。
///
/// 当前句怎么定（正文文档，分页 / 连续 / VN 共用）：
/// * 弹窗开着时以本次查词的选区起点为锚（用户点了别处的词就从那个词接着扫）；
/// * 否则以有声书正在播放的句（`.fushi-sentence-audio-active`）里第一个可见字为锚；
/// * 否则沿用上一次的句子（仍在 DOM 里且还有可见字时）；
/// * 都没有就取屏上第一个可见字（与进光标同一个判据 `fushiCaret._firstVisibleStop`）。
/// 锚定后按 `fushiSelection.sentenceDelimiters` 向两侧找句界，规则与
/// `getSentenceContext` 相同（段落容器内、无标点 cue 边界即句界、句末收尾括号归前句、
/// 被跳过的空白缝还原成一个空格），但**不走** VN 的 `sourceTextPosition` 换源：扫词
/// 要的是屏上真实存在的节点（换到源章节的节点不在文档里、查不了词）。
///
/// 歌词文档（有声书歌词视图）：一行 `.cue` 即一句——锚为选区所在行，否则为正在播放的行。
///
/// 可见判据与点击命中同源（`charRangeVisible` + `visibleContentBox`），句子跨页时只有
/// 本页那半句能停；`isScanBoundary`（空白 / 标点 / 「只扫日文」门控）的字不能当起点。
class ReaderWordSweepScripts {
  ReaderWordSweepScripts._();

  /// 定出当前句并回传 `{id, text, stops, at}`（JSON 字符串）；无可扫文本时回 null。
  static String sentenceInvocation() =>
      '(window.fushiWordSweep ? window.fushiWordSweep.sentence() : null)';

  /// 在会话 [id] 的第 [unit] 个码元处查词；会话已被替换时 JS 侧拒绝（返回 false）。
  static String lookupInvocation(int id, int unit) =>
      '(window.fushiWordSweep ? window.fushiWordSweep.lookupAt($id, $unit) : false)';

  /// 注入正文 / 歌词文档的 JS（依赖同文档里的 `window.fushiSelection`）。
  static String source() => r"""
window.fushiWordSweep = {
  _seq: 0,
  _session: null,
  // 句首最多回溯的码元数 / 一句最多摊平的码元数：无标点的超长段落（听写稿、诗）不至于
  // 每按一次就把整段几千字逐字量一遍几何。
  _BACK: 400,
  _MAX: 1200,
  _sel: function() {
    var s = window.fushiSelection;
    if (!s || typeof s.createWalker !== 'function' ||
        typeof s.selectFromPosition !== 'function') return null;
    return s;
  },
  _isLyrics: function() {
    return typeof window.__lyricsGetCurrentIndex === 'function';
  },
  _alive: function(sess) {
    var first = null, last = null;
    for (var i = 0; i < sess.chars.length; i++) {
      if (sess.chars[i]) { if (!first) first = sess.chars[i]; last = sess.chars[i]; }
    }
    return !!first && document.contains(first.node) && document.contains(last.node);
  },
  _indexOf: function(sess, node, offset) {
    for (var i = 0; i < sess.chars.length; i++) {
      var c = sess.chars[i];
      if (c && c.node === node && c.offset === offset) return i;
    }
    return -1;
  },
  _visibleChar: function(s, node, offset, box) {
    var r = s.charRangeAt(node, offset);
    return !!r && s.charRangeVisible(r, box);
  },
  // 能当查词起点的字：码点起始（不是代理对后半）且不是扫描边界（空白 / 标点 /
  // 「只扫日文」时的非日文字）——与点击查词「点空格 / 标点不查」同一判据。
  _isWordChar: function(s, text, offset) {
    var code = text.charCodeAt(offset);
    if (code >= 0xDC00 && code <= 0xDFFF) return false;
    var cp = text.codePointAt(offset);
    if (cp === undefined) return false;
    return !s.isScanBoundary(String.fromCodePoint(cp));
  },
  _stops: function(s, sess, box) {
    var out = [];
    for (var i = 0; i < sess.chars.length; i++) {
      var c = sess.chars[i];
      if (!c || !document.contains(c.node)) continue;
      if (!this._isWordChar(s, c.node.textContent, c.offset)) continue;
      if (!this._visibleChar(s, c.node, c.offset, box)) continue;
      out.push(i);
    }
    return out;
  },
  _pushChar: function(col, node, offset) {
    col.text += node.textContent[offset];
    col.chars.push({ node: node, offset: offset });
  },
  // BUG-3453 同款：walker 跳过的纯空白节点在排版上是真实的词间空格，还原成一个空格
  // （不对应任何节点，永远不是停靠点），否则英文两个词会被粘成一个。
  _gap: function(s, col, earlier, later) {
    if (s.hasSkippedWhitespaceBetween(earlier, later) &&
        s.isWordGapBetweenChars(earlier.textContent, later.textContent)) {
      col.text += ' ';
      col.chars.push(null);
    }
  },
  _collectSentence: function(s, node, offset) {
    var delims = s.sentenceDelimiters, trailing = s.trailingSentenceChars;
    var container = s.findParagraph(node) || document.body;
    var walker = s.createWalker(container);
    walker.currentNode = node;
    // ① 回溯到句首。
    var startNode = node, startOffset = 0, budget = this._BACK, found = false;
    var cur = node, limit = offset;
    while (cur) {
      var t = cur.textContent;
      for (var i = limit - 1; i >= 0; i--) {
        var isDelim = delims.indexOf(t[i]) >= 0;
        if (isDelim || budget <= 0) {
          var st = i + 1;
          // 句末收尾括号（。」）归前一句，新句从括号之后起。
          if (isDelim) while (st < t.length && trailing.indexOf(t[st]) >= 0) st++;
          if (cur === node && st > offset) st = offset;
          startNode = cur; startOffset = st; found = true;
          break;
        }
        budget--;
      }
      if (found) break;
      startNode = cur; startOffset = 0;
      var later = cur;
      cur = walker.previousNode();
      if (cur && s.isUnpunctuatedCueBoundary(cur, later)) break;
      if (cur) limit = cur.textContent.length;
    }
    // ② 从句首向后摊平到句末（含句末收尾括号）。
    var col = { text: '', chars: [] };
    walker.currentNode = startNode;
    cur = startNode;
    var j = startOffset, prev = null;
    while (cur && col.chars.length < this._MAX) {
      if (prev) {
        if (s.isUnpunctuatedCueBoundary(prev, cur)) break;
        this._gap(s, col, prev, cur);
      }
      var tx = cur.textContent, done = false;
      for (; j < tx.length && col.chars.length < this._MAX; j++) {
        this._pushChar(col, cur, j);
        if (delims.indexOf(tx[j]) >= 0) {
          var e = j + 1;
          while (e < tx.length && trailing.indexOf(tx[e]) >= 0) { this._pushChar(col, cur, e); e++; }
          done = true;
          break;
        }
      }
      if (done) break;
      prev = cur;
      cur = walker.nextNode();
      j = 0;
    }
    return col;
  },
  _collectRoot: function(s, root) {
    var col = { text: '', chars: [] };
    var walker = s.createWalker(root);
    var n, prev = null;
    while ((n = walker.nextNode()) && col.chars.length < this._MAX) {
      if (prev) this._gap(s, col, prev, n);
      var t = n.textContent;
      for (var k = 0; k < t.length && col.chars.length < this._MAX; k++) this._pushChar(col, n, k);
      prev = n;
    }
    return col;
  },
  _build: function(col, root) {
    this._seq += 1;
    return { id: this._seq, chars: col.chars, text: col.text, root: root };
  },
  _audioAnchor: function(s, box) {
    var els = document.querySelectorAll('.fushi-sentence-audio-active');
    for (var e = 0; e < els.length; e++) {
      var walker = s.createWalker(els[e]);
      var n;
      while ((n = walker.nextNode())) {
        var t = n.textContent;
        for (var i = 0; i < t.length; i++) {
          if (!this._isWordChar(s, t, i)) continue;
          if (this._visibleChar(s, n, i, box)) return { node: n, offset: i };
        }
      }
    }
    return null;
  },
  _firstVisible: function(s, box) {
    var caret = window.fushiCaret;
    if (caret && typeof caret._firstVisibleStop === 'function') {
      var p = caret._firstVisibleStop();
      if (p && p.node && p.node.nodeType === Node.TEXT_NODE) return { node: p.node, offset: p.offset };
      return null;
    }
    var walker = s.createWalker(document.body);
    var n;
    while ((n = walker.nextNode())) {
      var t = n.textContent;
      for (var i = 0; i < t.length; i++) {
        if (!this._isWordChar(s, t, i)) continue;
        if (this._visibleChar(s, n, i, box)) return { node: n, offset: i };
      }
    }
    return null;
  },
  sentence: function() {
    var s = this._sel();
    if (!s) return null;
    var box = s.visibleContentBox();
    var sess = this._session;
    if (sess && !this._alive(sess)) sess = null;
    var sel = null;
    var cur = s.selection;
    if (cur && cur.startNode && document.contains(cur.startNode) &&
        this._visibleChar(s, cur.startNode, cur.startOffset, box)) {
      sel = { node: cur.startNode, offset: cur.startOffset };
    }
    if (this._isLyrics()) {
      var cueEl = null;
      if (sel) {
        var pe = sel.node.parentElement;
        cueEl = pe && pe.closest ? pe.closest('.cue') : null;
      }
      if (!cueEl) {
        var cues = document.querySelectorAll('.cue');
        var idx = window.__lyricsGetCurrentIndex();
        if (idx >= 0 && idx < cues.length) cueEl = cues[idx];
      }
      if (!cueEl) { this._session = null; return null; }
      if (!sess || sess.root !== cueEl) sess = this._build(this._collectRoot(s, cueEl), cueEl);
    } else {
      var anchor = sel || this._audioAnchor(s, box);
      if (anchor) {
        if (!sess || this._indexOf(sess, anchor.node, anchor.offset) < 0) {
          sess = this._build(this._collectSentence(s, anchor.node, anchor.offset), null);
        }
      } else if (!sess || this._stops(s, sess, box).length === 0) {
        var first = this._firstVisible(s, box);
        if (!first) { this._session = null; return null; }
        sess = this._build(this._collectSentence(s, first.node, first.offset), null);
      }
    }
    this._session = sess;
    if (!sess.text) return null;
    return JSON.stringify({
      id: sess.id,
      // 换行等长换成空格（与 getSentenceContext 同口径），下标不变。
      text: sess.text.replace(/[\n\r]/g, ' '),
      stops: this._stops(s, sess, box),
      at: sel ? this._indexOf(sess, sel.node, sel.offset) : -1
    });
  },
  lookupAt: function(id, unit) {
    var s = this._sel();
    var sess = this._session;
    if (!s || !sess || sess.id !== id) return false;
    var c = sess.chars[unit];
    if (!c || !document.contains(c.node)) return false;
    // 歌词行：与 fushiLyricsCaret._setCueContext 同一份元数据，收藏 / 句子归属与点击一致。
    if (sess.root) {
      window.__lyricsCueContext = {
        textFragmentId: sess.root.getAttribute('data-text-fragment-id'),
        cueIndex: parseInt(sess.root.getAttribute('data-cue-index'), 10)
      };
    }
    if (typeof s.clearSelection === 'function') s.clearSelection();
    return !!s.selectFromPosition(c.node, c.offset, 400);
  }
};
""";

  /// 解析 [sentenceInvocation] 的回传；缺字段 / 非法时返回 null。
  static ReaderWordSweepSentence? parseSentence(Object? raw) {
    Object? decoded = raw;
    if (raw is String) {
      final String trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed == 'null') return null;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) return null;
    final Object? id = decoded['id'];
    final Object? text = decoded['text'];
    final Object? stops = decoded['stops'];
    final Object? at = decoded['at'];
    if (id is! num || text is! String || stops is! List) return null;
    return ReaderWordSweepSentence(
      id: id.toInt(),
      text: text,
      stops: <int>[
        for (final Object? s in stops)
          if (s is num) s.toInt(),
      ],
      at: at is num ? at.toInt() : -1,
    );
  }
}

/// [ReaderWordSweepScripts.sentenceInvocation] 回传的当前句快照。
class ReaderWordSweepSentence {
  const ReaderWordSweepSentence({
    required this.id,
    required this.text,
    required this.stops,
    required this.at,
  });

  /// JS 会话号：句子重建（换句 / 翻页 / 换屏 / 切歌词行）即换号。
  final int id;

  /// 摊平后的句子（UTF-16 下标与 JS 侧字符表一一对应）。
  final String text;

  /// 此刻可见、能当查词起点的码元下标（升序）。
  final List<int> stops;

  /// 弹窗开着时本次查词选区起点在 [text] 里的码元下标；-1 = 无。
  final int at;
}
