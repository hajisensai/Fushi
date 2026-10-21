// 查词卡顿（P0-1 / P2）一致性：在真 Chrome DOM 上，把生产的 fushiReader / fushiSelection
// 对象跑起来，逐节点、逐偏移比对「缓存 / 索引的新实现」与「原样保留的旧实现」。
//   - getMatchableOffset（节点前缀表 + MutationObserver 失效） vs getMatchableOffsetByWalk
//   - cueIdAtDomPoint（祖先链查表 + Range 二分） vs cueIdAtDomPointLinear
//   - getCaretRange 逐字兜底（行盒剪枝 caretScanCandidates） vs 不剪枝的全量扫描
//   - fireTextSelected 的悬停回执 / 歌词 cue 上下文
// 只替换了 Flutter 桥（callHandler 记录器）。
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const driver = await launchChromeDriver();
let count = 0;
try {
  for (const shell of scripts.shells) {
    const start = shell.indexOf('window.fushiReader = {');
    const end = shell.indexOf('\n};', start);
    assert.ok(start >= 0 && end > start, 'production reader object exists');
    const source = 'const C = {};\n' + scripts.units + '\n' +
      shell.slice(start, end + 3) + '\n' + scripts.selection;
    const html = '<!doctype html><meta charset="utf-8">' +
      '<style>html,body{margin:0}body{padding:30px;font:20px/1.6 serif;width:520px}</style><body>';
    const result = await driver.evalOnPage(html, `(async () => {
      (0, eval)(${JSON.stringify(source)});
      window.lastEvents = [];
      window.flutter_inappwebview = {callHandler: (name, payload) => {
        window.lastEvents.push(name);
        if (typeof payload === 'string') window.lastPayload = JSON.parse(payload);
        return Promise.resolve(null);
      }};
      window.__fushiCssHighlightsSupported = true;
      const reader = window.fushiReader;
      const selection = window.fushiSelection;
      const results = [];
      function check(condition, label) {
        if (!condition) throw Error(label);
        results.push(label);
      }
      function textNodesOf(root) {
        const out = [];
        const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let n;
        while ((n = w.nextNode())) out.push(n);
        return out;
      }

      // ---------- P0-1: getMatchableOffset ----------
      let builds = 0;
      const realBuild = selection.buildMatchableIndex;
      selection.buildMatchableIndex = function() { builds++; return realBuild.apply(this, arguments); };
      function sweepMatchable(label, extraNodes) {
        const nodes = textNodesOf(document.body).concat(extraNodes || []);
        let compared = 0, nonNull = 0;
        for (const n of nodes) {
          const len = (n.textContent || '').length;
          for (let o = 0; o <= len; o++) {
            const fast = selection.getMatchableOffset(n, o);
            const slow = selection.getMatchableOffsetByWalk(n, o);
            if (fast !== slow) {
              throw Error(label + ': node ' + JSON.stringify(n.textContent) + ' offset ' + o +
                ' fast=' + fast + ' slow=' + slow);
            }
            compared++;
            if (fast !== null) nonNull++;
          }
        }
        check(compared > 20 && nonNull > 10, label + ' (' + compared + ' points)');
      }
      document.body.innerHTML =
        '<p>漢字<ruby>振<rt>ふ</rt></ruby>仮名、😀絵文字！abc DEF ０１２ ｱｲｳ</p>\\n  ' +
        '<p>  </p><p>二段目。<span>「入れ子」</span>テスト🀄️𠮷野家 — ‘quote’ … 1,234.5</p>' +
        '<p><ruby>漢<rp>(</rp><rt>かん</rt><rp>)</rp></ruby>字<ruby><rb>東</rb><rt>とう</rt></ruby>京👨‍👩‍👧‍👦終</p>';
      sweepMatchable('ruby / rp / emoji surrogate / mixed punctuation');
      check(builds === 1, 'prefix table built once for the whole sweep (builds=' + builds + ')');
      // DOM surgery with NO explicit invalidation call: the observer must catch it.
      const p0 = document.querySelector('p').firstChild;
      p0.splitText(1);
      sweepMatchable('after splitText');
      const second = document.querySelectorAll('p')[2];
      const wrapR = document.createRange();
      wrapR.setStart(second.firstChild, 1); wrapR.setEnd(second.firstChild, 3);
      wrapR.surroundContents(document.createElement('b'));
      sweepMatchable('after wrapping a span');
      document.body.normalize();
      sweepMatchable('after normalize');
      document.querySelector('span').firstChild.data = '差し替えた文字列😀';
      sweepMatchable('after characterData edit');
      const inserted = document.createElement('p');
      inserted.textContent = '先頭に挿入、abc';
      document.body.insertBefore(inserted, document.body.firstChild);
      sweepMatchable('after inserting text before every node');
      // Same-task mutation then query (observer callback has not run yet).
      const before = selection.getMatchableOffset(document.querySelectorAll('p')[3].firstChild, 1);
      document.body.insertBefore(document.createTextNode('同期'), document.body.firstChild);
      const after = selection.getMatchableOffset(document.querySelectorAll('p')[3].firstChild, 1);
      check(after === before + 2 &&
        after === selection.getMatchableOffsetByWalk(document.querySelectorAll('p')[3].firstChild, 1),
        'same-task mutation is seen through takeRecords');
      const detached = document.createTextNode('游離テキスト');
      sweepMatchable('detached node stays null', [detached]);
      check(selection.getMatchableOffset(detached, 2) === null, 'detached node returns null');
      document.body.lastChild.remove();
      sweepMatchable('after removing a node');
      selection.buildMatchableIndex = realBuild;

      // ---------- P2: cueIdAtDomPoint ----------
      function sweepCue(label, expectHits) {
        const nodes = textNodesOf(document.body);
        let compared = 0, hits = 0;
        for (const n of nodes) {
          const len = (n.textContent || '').length;
          for (let o = 0; o <= len; o++) {
            const fast = reader.cueIdAtDomPoint(n, o);
            const slow = reader.cueIdAtDomPointLinear(n, o);
            if (fast !== slow) {
              throw Error(label + ': node ' + JSON.stringify(n.textContent) + ' offset ' + o +
                ' fast=' + fast + ' slow=' + slow);
            }
            compared++;
            if (fast) hits++;
          }
        }
        check(compared >= 5 && hits >= expectHits, label + ' (' + compared + ' points, ' + hits + ' hits)');
      }
      const cueText = '<p>西暦2148年。Eighty Six部隊。次の文。</p>' +
        '<p><ruby>次<rt>つぎ</rt></ruby>の文。<ruby>会<rt>かい</rt></ruby>釈をする。</p>';
      const cues = [
        {id:'a', text:'西暦2148年。', start:0, length:7},
        {id:'b', text:'Eighty Six部隊。', start:7, length:11},
        {id:'c', text:'次の文。', start:18, length:3},
        {id:'d', text:'次の文。', start:21, length:3},
        {id:'e', text:'会釈をする。', start:24, length:5}
      ];
      window.__fushiSentenceAudioRangeMode = false;
      reader.resetSentenceAudioCues();
      document.body.innerHTML = cueText;
      reader.applySentenceAudioCues(cues);
      check(reader.cueWrappers.size > 0, 'wrapper mode built wrappers');
      sweepCue('wrapper mode (incl. ruby annotations)', 10);
      window.__fushiSentenceAudioRangeMode = true;
      reader.resetSentenceAudioCues();
      document.body.innerHTML = cueText;
      reader.applySentenceAudioCues(cues);
      check(reader.cueRangesMap.size > 0 && reader.cueLookupIndex().ranges !== null,
        'range mode built disjoint sorted ranges (binary search active)');
      sweepCue('range mode', 10);
      // Live-range drift after DOM surgery keeps order: split a text node mid-cue.
      textNodesOf(document.body)[0].splitText(3);
      sweepCue('range mode after splitText', 10);
      window.__fushiSentenceAudioRangeMode = undefined;
      // Hand-built maps (as older callers / tests do): touching, overlapping, nested.
      reader.resetSentenceAudioCues();
      document.body.innerHTML = '<p>前文次文後文</p>';
      const t = document.querySelector('p').firstChild;
      const mk = (s, e) => { const r = document.createRange(); r.setStart(t, s); r.setEnd(t, e); return r; };
      reader.cueRangesMap.set('prev', [mk(0, 2)]);
      reader.cueRangesMap.set('cur', [mk(2, 4)]);
      reader.cueRangesMap.set('empty', [mk(4, 4)]);
      sweepCue('touching boundaries + collapsed range', 4);
      reader.cueRangesMap.set('overlap', [mk(1, 5)]);
      check(reader.cueLookupIndex().ranges === null, 'overlapping ranges disable the binary search');
      sweepCue('overlapping ranges fall back to the linear order', 5);
      reader.resetSentenceAudioCues();
      document.body.innerHTML = '<p>外<span id="o">側<span id="i">内側</span>続</span><ruby>漢<rt>かん</rt></ruby></p>';
      const outer = document.getElementById('o'), inner = document.getElementById('i');
      const ruby = document.querySelector('ruby');
      reader.cueWrappers.set('second-inner', [inner]);
      reader.cueWrappers.set('first-outer', [outer]);
      reader.cueRubyElements.set('ruby-owner', [ruby]);
      sweepCue('nested wrappers resolve to Map insertion order', 3);
      reader.resetSentenceAudioCues();
      document.body.innerHTML = '<p><ruby><span class="w">漢</span><rt>かん</rt></ruby>字</p>';
      reader.cueWrappers.set('x', [document.querySelector('p').lastChild.parentNode.querySelector('.w')]);
      sweepCue('annotation resolves to the wrapper of the same ruby', 2);
      reader.resetSentenceAudioCues();

      // ---------- P2: getCaretRange nearest-glyph fallback ----------
      let long = '';
      for (let i = 0; i < 14; i++) long += 'これは長い本文の第' + i + '行です。Latin words, too! ';
      document.body.innerHTML =
        '<div id="c" style="columns:2;column-gap:24px;height:360px">' + long +
        '<b>太字の' + long.slice(0, 40) + '</b>' + long + '</div>';
      Object.defineProperty(document, 'caretPositionFromPoint', { value: undefined, configurable: true });
      const realCandidates = selection.caretScanCandidates;
      function fullScan(container) {
        const w = selection.createWalker(container);
        const out = [];
        let n;
        while ((n = w.nextNode())) out.push(n);
        return out;
      }
      function caretKey(r) {
        if (!r) return 'null';
        const nodes = textNodesOf(document.body);
        return nodes.indexOf(r.startContainer) + ':' + r.startOffset;
      }
      const points = [];
      for (let x = -4; x <= 640; x += 29) for (let y = -4; y <= 440; y += 27) points.push([x, y]);
      // Glyph edges: just inside / just outside the corners of a sample of characters.
      const sampleNodes = textNodesOf(document.body);
      for (const n of sampleNodes) {
        for (let o = 0; o < n.textContent.length; o += 23) {
          const r = document.createRange(); r.setStart(n, o); r.setEnd(n, o + 1);
          const q = r.getClientRects()[0];
          if (!q) continue;
          for (const dx of [-7, -2, 1, q.width + 2, q.width + 7]) {
            for (const dy of [-7, 1, q.height + 2, q.height + 7]) points.push([q.left + dx, q.top + dy]);
          }
        }
      }
      let caretHits = 0, pruned = 0;
      for (const [x, y] of points) {
        selection.caretScanCandidates = realCandidates;
        const fast = caretKey(selection.getCaretRange(x, y));
        const element = document.elementFromPoint(x, y);
        if (element) {
          const container = element.closest('p, div, span, ruby, a') || document.body;
          if (realCandidates.call(selection, container, x, y, selection.visibleContentBox()).length <
              fullScan(container).length) pruned++;
        }
        selection.caretScanCandidates = function(container) { return fullScan(container); };
        const slow = caretKey(selection.getCaretRange(x, y));
        if (fast !== slow) throw Error('getCaretRange mismatch at ' + x + ',' + y + ' fast=' + fast + ' slow=' + slow);
        if (fast !== 'null') caretHits++;
      }
      selection.caretScanCandidates = realCandidates;
      check(caretHits > 50 && pruned > 50,
        'getCaretRange fallback identical with pruning (' + points.length + ' points, ' +
        caretHits + ' hits, ' + pruned + ' pruned scans)');

      // ---------- P0-2 / P1: fireTextSelected contract ----------
      document.body.innerHTML = '<p>悬停查词テスト</p>';
      const tn = document.querySelector('p').firstChild;
      delete window.__lyricsCueContext;
      const seq0 = selection.textSelectedSeq || 0;
      selection.selectFromPosition(tn, 0, 4, 10, 10, true);
      check((selection.textSelectedSeq || 0) === seq0 + 1 &&
        selection.lastTextSelectedAck && typeof selection.lastTextSelectedAck.then === 'function',
        'fireTextSelected exposes a sequence number and the host ack promise');
      check(!('lyricsCueContext' in window.lastPayload) && window.lastPayload.fromHover === true,
        'documents without __lyricsCueContext do not send the key');
      window.__lyricsCueContext = {textFragmentId: 'frag-1', cueIndex: 3};
      selection.clearSelection();
      selection.selectFromPosition(tn, 1, 4, 10, 10, false);
      check(window.lastPayload.lyricsCueContext &&
        window.lastPayload.lyricsCueContext.textFragmentId === 'frag-1' &&
        window.lastPayload.lyricsCueContext.cueIndex === 3,
        'lyrics cue context rides along with the payload');
      window.__lyricsCueContext = null;
      selection.clearSelection();
      selection.selectFromPosition(tn, 2, 4, 10, 10, false);
      check('lyricsCueContext' in window.lastPayload && window.lastPayload.lyricsCueContext === null,
        'a null lyrics context is sent as an explicit null');
      return results;
    })()`);
    count += result.length;
  }
  console.log('PASS ' + count + ' browser cases');
} finally {
  driver.close();
}
