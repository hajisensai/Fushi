// Executes generated production reader/selection objects against Chrome Range,
// Selection and wrapper DOM; only the Flutter bridge is replaced by a recorder.
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
    const result = await driver.evalOnPage('<!doctype html><meta charset="utf-8"><body>', `(async () => {
      (0, eval)(${JSON.stringify(source)});
      window.flutter_inappwebview = {callHandler: (name, payload) => {
        if (typeof payload === 'string') window.lastPayload = JSON.parse(payload);
        window.lastEvent = name;
      }};
      window.__fushiCssHighlightsSupported = true;
      const reader = window.fushiReader;
      const selection = window.fushiSelection;
      const results = [];
      function check(condition, label) {
        if (!condition) throw Error(label);
        results.push(label);
      }
      function native(node, start, end) {
        const range = document.createRange();
        range.setStart(node, start); range.setEnd(node, end);
        window.getSelection().removeAllRanges();
        window.getSelection().addRange(range);
        return selection.nativeSelectionSentenceRange();
      }
      function cue(payload) { return payload.audioCuePayload ? JSON.parse(payload.audioCuePayload) : {}; }
      document.body.innerHTML = '<p>西暦2148年。Eighty Six部隊。次の文。</p>';
      reader.applySentenceAudioCues([
        {id:'previous', text:'西暦2148年。', start:0, length:7},
        {id:'current', text:'Eighty Six部隊。', start:7, length:11},
        {id:'next', text:'次の文。', start:18, length:3}
      ]);
      const current = reader.cueWrappers.get('current')[0].firstChild;
      selection.selectFromPosition(current, 0, 1);
      check(cue(window.lastPayload).id === 'current', 'tap targets rendered English cue');
      check(window.lastPayload.normalizedOffset === 4 &&
        reader.buildSentenceAudioNormIndex().full.indexOf('eighty') === 7,
        'digit run makes study offset 4 differ from subtitle offset 7');
      check(cue(native(current, 0, 1)).id === 'current', 'native selection targets same cue');
      const hitRange = document.createRange(); hitRange.setStart(current, 0); hitRange.setEnd(current, 1);
      const rect = hitRange.getBoundingClientRect();
      check(JSON.parse(reader.cueIdAtPoint(rect.left + rect.width / 3, rect.top + rect.height / 2)).id === 'current',
        'real glyph pointer seek agrees with lookup payload');
      const next = reader.cueWrappers.get('next')[0].firstChild;
      selection.selectFromPosition(next, 0, 1);
      check(cue(window.lastPayload).id === 'next' && window.lastPayload.normalizedOffset === 8,
        'English words compress study offsets without moving next sentence seek');
      reader.resetSentenceAudioCues();
      document.body.innerHTML = '<p>前文次文</p>';
      const node = document.querySelector('p').firstChild;
      const previous = document.createRange(); previous.setStart(node, 0); previous.setEnd(node, 2);
      const following = document.createRange(); following.setStart(node, 2); following.setEnd(node, 4);
      reader.cueRangesMap.set('previous', [previous]);
      reader.cueRangesMap.set('current', [following]);
      reader.buildNodeOffsets();
      selection.selectFromPosition(node, 2, 1);
      check(cue(window.lastPayload).id === 'current', 'tap at shared Range boundary excludes previous cue');
      check(cue(native(node, 2, 3)).id === 'current', 'native Range boundary excludes previous cue');
      reader.resetSentenceAudioCues();
      document.body.innerHTML = '<p><ruby>次<rt>つぎ</rt></ruby>の文。</p>';
      reader.applySentenceAudioCues([{id:'ruby', text:'次の文。', start:0, length:3}]);
      const ruby = document.querySelector('ruby');
      // BUG-2806: the base text is wrapped in place inside the ruby (the ruby never moves).
      const rubyWrapper = ruby.querySelector('.fushi-sentence-audio-cue');
      if (ruby.parentNode !== document.querySelector('p') || !rubyWrapper) throw Error('ruby stays in place, base wrapped inside');
      const rubyBase = rubyWrapper.firstChild;
      selection.selectFromPosition(rubyBase, 0, 1);
      check(cue(window.lastPayload).id === 'ruby' &&
        JSON.parse(reader.cueIdAtDomPoint(ruby.querySelector('rt').firstChild, 0)).id === 'ruby',
        'ruby base lookup and annotation pointer keep cue identity');
      check(cue(native(rubyBase, 0, 1)).id === 'ruby', 'ruby native selection preserves cue');
      reader.resetSentenceAudioCues();
      document.body.innerHTML = '<p data-cue-id="12">合成文。</p><p id="missing">字幕なし。</p>';
      reader.buildNodeOffsets();
      const synthetic = document.querySelector('p').firstChild;
      selection.selectFromPosition(synthetic, 0, 1);
      check(cue(window.lastPayload).type === 'sid' && cue(window.lastPayload).id === '12',
        'synthetic tap preserves sid identity');
      check(cue(native(synthetic, 0, 1)).type === 'sid', 'synthetic native selection preserves sid');
      const missing = document.querySelector('#missing').firstChild;
      selection.selectFromPosition(missing, 0, 1);
      check(window.lastPayload.audioCuePayload === null && native(missing, 0, 1).audioCuePayload === null,
        'unmapped text has no previous-cue fallback');
      // BUG-2806 review: the gap-fill shadow is a measured pixel value, so a relayout
      // while the cue stays active (paused) must re-measure it. Real layout, real
      // observers: swap the reader stylesheet the way _applyStylesLive does.
      reader.resetSentenceAudioCues();
      const style = document.createElement('style');
      style.id = 'fushi-reader-style';
      // Chrome stretches the in-ruby wrapper across the annotation, so the gap is
      // made with em-based ruby padding: it scales with the font size, like the
      // WebKit annotation overhang it stands in for.
      const rubyGap = 'ruby { padding-inline: 0.5em; }';
      style.textContent = 'body { font-size: 20px; } ' + rubyGap;
      document.head.appendChild(style);
      document.body.innerHTML = '<p>ほら<ruby>漢</ruby>字だ</p>';
      reader.applySentenceAudioCues([{id:'gap', text:'ほら漢字だ', start:0, length:5}]);
      reader.highlightSentenceAudioCue('gap', false);
      const baseWrapper = document.querySelector('ruby .fushi-sentence-audio-cue');
      const small = baseWrapper.style.boxShadow;
      if (!small) throw Error('ruby padding leaves a gap to fill at 20px');
      const settle = () => new Promise((r) => setTimeout(r, 0));
      style.textContent = 'body { font-size: 40px; } ' + rubyGap;
      await settle();
      const relaid = baseWrapper.style.boxShadow;
      reader.paintSentenceAudioRubyGaps();
      check(relaid !== small && relaid === baseWrapper.style.boxShadow,
        'stylesheet swap re-measures the gap fill');
      style.textContent = 'body { font-size: 40px; }';
      await settle();
      check(baseWrapper.style.boxShadow === '', 'a swap that closes the gap removes the fill');
      return results;
    })()`);
    count += result.length;
  }
  console.log('PASS ' + count + ' browser cases');
} finally {
  driver.close();
}
