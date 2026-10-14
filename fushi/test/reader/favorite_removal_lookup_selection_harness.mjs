// BUG-3328: deleting a favourite highlight must not lose the live lookup
// selection. Runs the generated production reader objects (paginated /
// continuous) and the complete VN factory, the selection script and the
// favourite highlight bridge against Chrome's real DOM, Range and
// Node.normalize(); only the Flutter bridge is replaced by a recorder.
//
// Both highlight engines are covered: CSS Custom Highlights (Blink, WebKit
// 17.2+) and the span-wrapping fallback (iOS / macOS Safari before 17.2), which
// is the one that unwrapped the favourite spans and merged text nodes under the
// lookup selection's "text node + offset" points.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
// The only argument is the temp payload file the Dart test just wrote (production
// scripts serialized from the repo); there is no user- or model-supplied path here.
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));  // NOSONAR: S8707 false positive, path comes from the Dart test harness

const PARAGRAPH = '<p>前の文。猫がいる。後の文です。</p>';

function readerObject(shell) {
  const start = shell.indexOf('window.fushiReader = {');
  const end = shell.indexOf('\n};', start);
  assert.ok(start >= 0 && end > start, 'production reader object exists');
  return shell.slice(start, end + 3);
}

function flatPage(shell) {
  const source = 'const C = {};\n' + scripts.units + '\n' + readerObject(shell) +
    '\n' + scripts.selection + '\n' + scripts.bridge;
  return {
    html: '<!doctype html><meta charset="utf-8"><body>',
    setup: `(0, eval)(${JSON.stringify(source)});
      document.body.innerHTML = ${JSON.stringify(PARAGRAPH)};
      window.fushiReader.buildNodeOffsets();`,
  };
}

function vnPage() {
  const config = {
    vnRevealSpeed: 0, vnScreenMode: 'block', vnSentencesPerScreen: 1,
    vnPreserveDialogue: false, vnMergeCrossScreenSentenceAudioCues: false,
    sentenceAudioCues: [], initialProgress: 0, initialFragment: null,
    initialCharOffset: -1, navigationGeneration: 1, dartPageWidth: 800,
    dartPageHeight: 600, chromeTopInset: 0, chromeBottomInset: 0,
    blurImages: false, revealedKeys: [],
  };
  return {
    html: '<!doctype html><html><head><meta charset="utf-8">' +
      '<style>body{margin:0;font:20px/1.5 sans-serif}' +
      '.fushi-vn-stage,.fushi-vn-screen{width:800px;height:600px}p{margin:0}</style>' +
      '<script>window.__fushiShells={};' +
      'window.flutter_inappwebview={callHandler:()=>{}};' + scripts.units + '</script>' +
      scripts.vn + '<script>' + scripts.selection +
      ';window.__fushiShells.vn(' + JSON.stringify(config) + ');</script>' +
      '</head><body>' + PARAGRAPH + '</body></html>',
    setup: `(0, eval)(${JSON.stringify(scripts.bridge)});`,
  };
}

// The scenario, run once per engine. `label` is prefixed to every failure.
const scenario = (label, css) => `
  window.flutter_inappwebview = {callHandler: () => {}};
  window.__fushiCssHighlightsSupported = ${css};
  const reader = window.fushiReader;
  const selection = window.fushiSelection;
  const host = reader.screen || document.body;
  const results = [];
  function check(condition, what, details) {
    if (!condition) {
      throw Error(${JSON.stringify(label)} + ': ' + what +
        (details === undefined ? '' : ' ' + JSON.stringify(details)));
    }
    results.push(what);
  }
  function catNode() {
    const walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      const at = node.data.indexOf('猫');
      if (at >= 0) return { node, at };
    }
    throw Error('rendered text has no cat');
  }
  // What the lookup selection resolves to through its own "node + offset"
  // state (what drag grips, re-highlighting and the mining sentence read),
  // and what is painted for it.
  function lookupState() {
    const st = selection.selection;
    if (!st) return { live: false };
    const segments = st.matchedRanges || [];
    const painted = ${css}
      ? Array.from(CSS.highlights.get('fushi-selection') || []).map(r => r.toString()).join('')
      : selection.highlightWrappers.filter(w => w.isConnected).map(w => w.textContent).join('');
    return {
      live: true,
      connected: st.startNode.isConnected &&
        segments.concat(st.ranges).every(s => s.node.isConnected),
      start: st.startNode.data.slice(st.startOffset, st.startOffset + 1),
      matched: segments.map(s => s.node.data.slice(s.start, s.end)).join(''),
      selected: st.ranges.map(s => s.node.data.slice(s.start, s.end)).join(''),
      painted,
    };
  }
  function expectLookup(matched, phase) {
    const state = lookupState();
    check(state.live && state.connected, phase + ': lookup selection still references the document', state);
    check(state.start === '猫', phase + ': selection start still points at the looked-up character', state);
    check(state.matched === matched, phase + ': matched ranges still cover the looked-up text', state);
    check(state.selected === '猫がいる', phase + ': the whole selected span still reads the same', state);
    check(state.painted === matched, phase + ': lookup highlight is still painted', state);
  }
  // Whether the favourite is painted at all, so a deletion that never touched
  // the DOM cannot pass for one that kept the lookup.
  function favoritePainted(id, color) {
    return ${css}
      ? !!(CSS.highlights.get('fushi-hl-' + color) && CSS.highlights.get('fushi-hl-' + color).size)
      : document.querySelectorAll('[data-highlight-id="' + id + '"]').length > 0;
  }
  // The lookup selects 4 characters (猫がいる) and the popup highlights the
  // matched 2 (猫が). The favourite starts inside the selected span, so the
  // selection's last segment lies in the favourite's first text node: unwrapping
  // the favourite puts that node right after the unmatched 「い」 and normalize()
  // merges it away -- the case a bare normalize() lost.
  const favorite = { id: 'fav', text: 'る。後の文', color: 'yellow' };
  const other = { id: 'other', text: '前の文。', color: 'blue' };

  window.__fushiApplyHighlights([favorite, other]);
  const hit = catNode();
  selection.selectFromPosition(hit.node, hit.at, 4);
  selection.highlightSelection(2);
  expectLookup('猫が', 'lookup reaching into a favourite');
  check(favoritePainted('fav', 'yellow') && favoritePainted('other', 'blue'), 'both favourites are painted');

  // Toggling the favourite off from the lookup popup re-applies the remaining
  // favourites of the section (_refreshSectionHighlights).
  window.__fushiApplyHighlights([other]);
  expectLookup('猫が', 'favourite deleted, another one remains');
  check(!favoritePainted('fav', 'yellow') && favoritePainted('other', 'blue'), 'only the deleted favourite is gone');
  window.__fushiApplyHighlights([]);
  expectLookup('猫が', 'last favourite deleted');

  window.__fushiApplyHighlights([favorite]);
  expectLookup('猫が', 'favourite added back under the lookup');
  check(favoritePainted('fav', 'yellow'), 'favourite painted again');
  window.__fushiRemoveHighlight('fav');
  expectLookup('猫が', 'single favourite removed by id');

  // The popup keeps narrowing / widening the lookup on the same selection.
  selection.highlightSelection(3);
  expectLookup('猫がい', 'lookup re-highlighted after the deletion');

  // VN wraps the playing sentence lazily and unwraps it (same merge) when the
  // cue data is re-applied, without clearing the lookup. The paginated /
  // continuous shells clear the lookup before unwrapping (resetSentenceAudioCues),
  // so there is no live selection to keep there.
  if (reader.screen) {
    const cue = { id: 'cue', text: '猫がいる', start: 4, length: 4 };
    reader.applySentenceAudioCues([cue]);
    reader.highlightSentenceAudioCue('cue', false);
    const wrapper = host.querySelector('.fushi-sentence-audio-cue');
    check(wrapper !== null, 'VN wrapped the playing sentence');
    const inCue = catNode();
    selection.selectFromPosition(inCue.node, inCue.at, 4);
    selection.highlightSelection(3);
    expectLookup('猫がい', 'lookup inside a VN sentence audio wrapper');
    reader.applySentenceAudioCues([cue]);
    // The cue stays active, so VN unwraps the old wrapper and wraps it again.
    check(!wrapper.isConnected, 'VN unwrapped the old sentence wrapper');
    expectLookup('猫がい', 'VN sentence audio re-wrapped');
  }
  selection.clearSelection();
  check(selection.selection === null && document.querySelectorAll('.fushi-dict-highlight').length === 0,
    'clearing the lookup still removes it');
  check(host.textContent.indexOf('前の文。猫がいる。後の文です。') >= 0,
    'text is unchanged after all the DOM surgery', host.textContent);
  return results.length;
`;

const pages = [
  ['paginated', flatPage(scripts.paginated)],
  ['continuous', flatPage(scripts.continuous)],
  ['vn', vnPage()],
];

const driver = await launchChromeDriver();
let cases = 0;
try {
  for (const [mode, page] of pages) {
    for (const css of [false, true]) {
      const label = mode + (css ? ' / CSS highlights' : ' / span fallback');
      const count = await driver.evalOnPage(page.html, `(() => {
        ${page.setup}
        ${scenario(label, css)}
      })()`);
      assert.ok(count > 0, label + ' ran');
      console.log('PASS ' + label + ' (' + count + ' checks)');
      cases++;
    }
  }
  console.log('PASS ' + cases + ' favourite removal scenarios');
} finally {
  driver.close();
}
