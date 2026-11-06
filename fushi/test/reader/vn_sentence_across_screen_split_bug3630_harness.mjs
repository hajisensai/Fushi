// BUG-3630: the visual-novel reader only clones one screen slice into the
// document. When a sentence does not fit one screen the viewport split cuts it
// in the middle (the user's card started at 「きと同じ…」 because the previous
// screen ended on the ruby 「書」). Lookup / mining must still take the complete
// sentence from the chapter source, exactly like paginated / continuous mode.
//
// Runs the complete generated VN factory plus the real selection script in
// Chrome (the same setup as vn_lookup_audio_coordinates_harness.mjs); only the
// Flutter bridge is replaced with a recorder.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

// Screen capacity of the deterministic ruler below, in code points of visible
// text (ruby annotations excluded). With 17 the dialogue splits as
// 「作中の探偵役が、素人のミステリ書 | きと同じ思考なのをひけらかされるの | だからな」,
// i.e. exactly the user's cut after the ruby 「書」, and the looked-up word
// 「ひけらか」 sits whole on the second slice.
const screenCapacity = 17;
const before = '前の文。';
const sentence = '「作中の探偵役が、素人のミステリ書きと同じ思考なのをひけらかされるのだからな」';
const html = '<p>' + before + '「作中の探偵役が、素人のミステリ<ruby>書<rt>か</rt></ruby>' +
  'きと同じ思考なのをひけらかされるのだからな」</p>';

function pageFor() {
  const config = {
    vnRevealSpeed: 0,
    vnScreenMode: 'sentence',
    vnSentencesPerScreen: 1,
    // Dialogue kept whole is the setting that makes one unit longer than a
    // screen; the viewport split then has to cut inside it.
    vnPreserveDialogue: true,
    vnMergeCrossScreenSentenceAudioCues: false,
    sentenceAudioCues: [],
    initialProgress: 0,
    initialFragment: null,
    initialCharOffset: -1,
    navigationGeneration: 1,
    dartPageWidth: 240,
    dartPageHeight: 64,
    chromeTopInset: 0,
    chromeBottomInset: 0,
    blurImages: false,
    revealedKeys: [],
  };
  return '<!doctype html><html><head><meta charset="utf-8">' +
    '<style>body{margin:0;font:20px/1.5 sans-serif}' +
    // Mirror the production VN layout box (reader_content_styles.dart): a
    // clipped screen and a content box bounded by it, so the measurement
    // really overflows and the split happens.
    '.fushi-vn-stage,.fushi-vn-screen{width:240px;height:64px;' +
    'box-sizing:border-box;overflow:hidden;display:flex}' +
    '.fushi-vn-content{max-width:100%;max-height:100%}' +
    'p{margin:0}rt{font-size:10px}</style>' +
    '<script>window.__fushiShells={};window.restoreCount=0;' +
    'window.flutter_inappwebview={callHandler:(name,payload)=>{' +
    'if(name==="onTextSelected")window.lastPayload=JSON.parse(payload);' +
    'if(name==="onRestoreComplete")window.restoreCount++;}};' +
    scripts.units + '</script>' + scripts.shell +
    '<script>' + scripts.selection +
    ';window.__fushiShells.vn(' + JSON.stringify(config) + ');' +
    // The production ruler (measureScreenFits -> real glyph rects) makes the
    // split point depend on the host's fonts: on CI's Linux headless Chrome the
    // whole dialogue fit the 240x64 box (different fallback glyph widths), so
    // no split happened and the precondition below failed. Like vn_split_kinsoku_behavior_test.js, swap
    // only the ruler for a font-independent stand-in ("fits" = visible code
    // points <= capacity); the production split loop, kinsoku boundary, ruby
    // atomic units, screen cloning and lookup paths all still run. The patch
    // lands before initialize(), which only runs on window 'load'.
    'if(typeof window.fushiReader.measureScreenFits!=="function")' +
    'throw Error("VN reader lost measureScreenFits");' +
    'window.fushiReader.measureScreenFits=function(screen,measurement){' +
    'if(!screen||!measurement||!measurement.content)return true;' +
    'measurement.content.replaceChildren(screen.render());' +
    'const probe=measurement.content.cloneNode(true);' +
    'probe.querySelectorAll("rt,rp").forEach((el)=>el.remove());' +
    'return Array.from(probe.textContent).length<=' + screenCapacity + ';};' +
    '</script>' +
    '</head><body>' + html + '</body></html>';
}

const driver = await launchChromeDriver();
try {
  const result = await driver.evalOnPage(pageFor(), `(() => {
    const before = ${JSON.stringify(before)};
    const sentence = ${JSON.stringify(sentence)};
    const reader = window.fushiReader;
    const selection = window.fushiSelection;
    function check(condition, label, details) {
      if (!condition) throw Error(label +
        (details === undefined ? '' : ' ' + JSON.stringify(details)));
    }
    check(window.restoreCount > 0 && reader.contentStream && reader.rangeMap,
      'the complete VN factory initializes and restores');
    check(!document.body.contains(reader.sourceRoot),
      'chapter source is detached; the document only holds one screen');

    // Precondition: the viewport split cut the sentence, so the screen that
    // shows the looked-up word does not start at the sentence head.
    let target = -1;
    for (let i = 0; i < reader.screens.length; i++) {
      reader.renderScreen(i, true);
      const text = reader.screen.textContent;
      if (text.indexOf('ひけらか') >= 0) { target = i; break; }
    }
    check(target >= 0, 'some screen shows the word', reader.screens.length);
    const screenText = reader.screen.textContent;
    check(screenText.indexOf('「作中') < 0,
      'precondition: the word sits on a screen cut mid-sentence', screenText);
    check(screenText.indexOf('きと同じ') === 0,
      'precondition: the cut reproduces the user report (after the ruby 書)', screenText);

    function wordHit() {
      const walker = reader.createWalker();
      let node;
      while ((node = walker.nextNode())) {
        const offset = node.textContent.indexOf('ひけらか');
        if (offset >= 0) return { node, offset };
      }
      throw Error('rendered screen has no word');
    }
    // Expected sentence audio interval, straight from the chapter source.
    const headRaw = Array.from(before).length;
    const sentenceStart = reader.contentStream.matchableOffsetForRawOffset(headRaw);
    const sentenceEnd = reader.contentStream.matchableOffsetForRawOffset(
      headRaw + Array.from(sentence).length);

    function verify(payload, label) {
      check(payload, label + ' produced a payload');
      check(payload.sentence === sentence,
        label + ' returns the complete sentence, not the screen slice', payload.sentence);
      // A native (drag) selection reports the merged span with offset 0 by
      // design (TODO-1104); only the tap path carries the word offset.
      if (label === 'tap lookup') {
        check(payload.sentence.substring(payload.sentenceOffset).indexOf('ひけらか') === 0,
          label + ' sentenceOffset points at the word inside the full sentence', payload);
      }
      check(payload.sentenceMatchableOffset === sentenceStart &&
        payload.sentenceMatchableLength === sentenceEnd - sentenceStart,
        label + ' sentence audio interval covers the whole sentence',
        { payload, sentenceStart, sentenceEnd });
      check(payload.sentenceNormalizedOffset !== null &&
        payload.sentenceNormalizedLength > 0,
        label + ' sentence study interval resolves for source nodes', payload);
      check(payload.sentenceNormalizedOffset <= payload.normalizedOffset,
        label + ' sentence starts before the word', payload);
    }

    const hit = wordHit();
    window.lastPayload = null;
    selection.selectFromPosition(hit.node, hit.offset, 4);
    verify(window.lastPayload, 'tap lookup');

    // Advanced mining: neighbouring sentences come from the source chapter too.
    const around = selection.getSurroundingSentences(1, 0);
    check(around.prev.length === 1 && around.prev[0].sentence === before,
      'the previous sentence is found across the screen boundary', around);

    const range = document.createRange();
    range.setStart(hit.node, hit.offset);
    range.setEnd(hit.node, hit.offset + 4);
    window.getSelection().removeAllRanges();
    window.getSelection().addRange(range);
    verify(selection.nativeSelectionSentenceRange(), 'native selection');
    window.getSelection().removeAllRanges();
    return reader.screens.length;
  })()`);
  assert.ok(result > 1);
  console.log('PASS VN sentence across screen split (' + result + ' screens)');
} finally {
  driver.close();
}
