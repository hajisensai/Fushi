// TODO-688 behavior test: the popup must RENDER the IPA `transcriptions` that
// TODO-687 block3 wired into the popup JSON. Each pitch GROUP carries a
// `transcriptions` string array (e.g. ['neꜜko']) — empty for plain pitch-accent
// dicts, populated for Yomitan `ipa`-mode dicts. popup.js renders them inside the
// pitch group as `[ipa]` tags.
//
// This EXECUTES the real popup.js against a minimal fake DOM and drives the real
// `createPitchSection` builder, then walks the produced element tree for the
// transcription text. Reverting the render (dropping the createTranscriptionsHtml
// call, or the empty-pitchPositions guard in createPitchSection) turns this red.
//
// Cases covered:
//   1. plain pitch dict (transcriptions: []) renders NO transcription text.
//   2. dict with both pitch positions AND transcriptions renders both.
//   3. IPA-only dict (pitchPositions: [], transcriptions: [...]) — the group is
//      kept under deduplicatePitchAccents and the transcriptions still render.
//
// Run: node fushi/test/pages/popup_pitch_transcriptions_test.js
// (also driven from popup_pitch_transcriptions_test.dart so it executes inside
//  `flutter test`).

const assert = require('assert');
const {
  loadPopup,
  collectByClass,
  collectText,
} = require('./_popup_dom_host.js');


// Collect the className of every element node in the tree.
function collectClasses(node, acc) {
  acc = acc || [];
  if (!node) return acc;
  if (node.nodeType !== 3 && node.className) acc.push(node.className);
  const kids = node.children || node.childNodes || [];
  for (const k of kids) collectClasses(k, acc);
  return acc;
}

(function run() {
  // Case 1: plain pitch dict — transcriptions empty → no transcription markup.
  {
    const sb = loadPopup();
    const section = sb.window.__test.createPitchSection(
      [{ dictionary: 'NHK', pitchPositions: [2], transcriptions: [] }], 'ねこ');
    assert.ok(section, 'plain pitch dict must still render a pitch section');
    const classes = collectClasses(section);
    assert.ok(!classes.includes('pitch-transcriptions'),
      'a plain pitch dict (empty transcriptions) must NOT render a transcriptions list; got '
        + JSON.stringify(classes));
  }

  // Case 2: pitch positions AND transcriptions both present → both render.
  {
    const sb = loadPopup();
    const section = sb.window.__test.createPitchSection(
      [{ dictionary: 'IPA', pitchPositions: [1], transcriptions: ['neꜜko', 'neko'] }], 'ねこ');
    assert.ok(section, 'mixed dict must render a pitch section');
    const text = collectText(section);
    assert.ok(text.includes('[neꜜko]'),
      'transcription [neꜜko] must be rendered; got ' + JSON.stringify(text));
    assert.ok(text.includes('[neko]'),
      'all transcriptions must be rendered; got ' + JSON.stringify(text));
    assert.ok(text.includes('[1]'),
      'the pitch position must still render alongside transcriptions; got ' + JSON.stringify(text));
    const classes = collectClasses(section);
    assert.ok(classes.includes('pitch-transcriptions'),
      'a transcriptions list element must exist; got ' + JSON.stringify(classes));
  }

  // Case 3: IPA-only dict (no pitch positions) under deduplicatePitchAccents.
  // The group has no unique pitch positions, so the dedup branch would drop it
  // unless transcriptions keep it alive.
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = true;
    const section = sb.window.__test.createPitchSection(
      [{ dictionary: 'IPA-only', pitchPositions: [], transcriptions: ['tabeꜜɾɯ'] }], 'たべる');
    assert.ok(section, 'IPA-only dict must render a pitch section');
    const text = collectText(section);
    assert.ok(text.includes('[tabeꜜɾɯ]'),
      'IPA-only transcription must NOT be dropped by the dedup empty-position guard; got '
        + JSON.stringify(text));
  }

  console.log('popup_pitch_transcriptions_test.js: all assertions passed');
})();
