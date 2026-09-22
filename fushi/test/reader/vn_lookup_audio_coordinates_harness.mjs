// Run the complete generated VN factory, including content-stream/range-map
// dependencies and host shims, against Chrome's actual cloned DOM and Ranges.
// Only the Flutter bridge is replaced with a recorder.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const fixtures = [
  {
    name: 'blocks with ruby and repeated sentences',
    mode: 'block',
    html: '<p>西暦2148年。Eighty Six部隊。𠀀<ruby>猫<rt>ねこ</rt></ruby>がいる。</p>' +
      '<p>ABCDEF1234567890。猫がいる。</p><p>猫がいる。</p>',
    screenCount: 3,
    targets: [
      // Audio positions count normalized UTF-16 code units, so 𠀀 counts two;
      // study positions compress the digit run and the two English words.
      { screen: 0, offset: 20, sentenceStart: 18, sentenceLength: 6,
        cueText: '𠀀猫がいる', id: 'first' },
      { screen: 1, offset: 40, sentenceStart: 40, sentenceLength: 4,
        cueText: '猫がいる', id: 'middle' },
      { screen: 2, offset: 44, sentenceStart: 44, sentenceLength: 4,
        cueText: '猫がいる', id: 'last' },
    ],
  },
  {
    name: 'sentence screens cut from the same source text node',
    mode: 'sentence',
    html: '<p>Alpha 2148𠀀前文。猫がいる。Beta 123456𠀀中段。猫がいる。</p>',
    screenCount: 4,
    targets: [
      { screen: 1, offset: 13, sentenceStart: 13, sentenceLength: 4,
        cueText: '猫がいる', id: 'cut-first' },
      { screen: 3, offset: 31, sentenceStart: 31, sentenceLength: 4,
        cueText: '猫がいる', id: 'cut-last' },
    ],
  },
];

function pageFor(fixture) {
  const config = {
    vnRevealSpeed: 0,
    vnScreenMode: fixture.mode,
    vnSentencesPerScreen: 1,
    vnPreserveDialogue: false,
    vnMergeCrossScreenSentenceAudioCues: !!fixture.merge,
    sentenceAudioCues: [],
    initialProgress: 0,
    initialFragment: null,
    initialCharOffset: -1,
    navigationGeneration: 1,
    dartPageWidth: 800,
    dartPageHeight: 600,
    chromeTopInset: 0,
    chromeBottomInset: 0,
    blurImages: false,
    revealedKeys: [],
  };
  return '<!doctype html><html><head><meta charset="utf-8">' +
    '<style>body{margin:0;font:20px/1.5 sans-serif}' +
    '.fushi-vn-stage,.fushi-vn-screen{width:800px;height:600px}' +
    'p{margin:0}rt{font-size:10px}</style>' +
    '<script>window.__fushiShells={};window.restoreCount=0;' +
    'window.flutter_inappwebview={callHandler:(name,payload)=>{' +
    'if(name==="onTextSelected")window.lastPayload=JSON.parse(payload);' +
    'if(name==="onRestoreComplete")window.restoreCount++;}};' +
    scripts.units + '</script>' + scripts.shell +
    '<script>' + scripts.selection +
    ';window.__fushiShells.vn(' + JSON.stringify(config) + ');</script>' +
    '</head><body>' + fixture.html + '</body></html>';
}

const driver = await launchChromeDriver();
let count = 0;
try {
  for (const fixture of fixtures) {
    const result = await driver.evalOnPage(pageFor(fixture), `(() => {
      const fixture = ${JSON.stringify(fixture)};
      const reader = window.fushiReader;
      const selection = window.fushiSelection;
      function check(condition, label, details) {
        if (!condition) throw Error(fixture.name + ': ' + label +
          (details === undefined ? '' : ' ' + JSON.stringify(details)));
      }
      check(window.restoreCount > 0 && reader.contentStream && reader.rangeMap,
        'the complete VN factory initializes and restores');
      check(reader.screens.length === fixture.screenCount,
        'fixture renders the expected real screens', reader.screens.length);
      check(!document.body.contains(reader.sourceRoot),
        'chapter source is detached, so walking body cannot give chapter offsets');
      const cues = fixture.targets.map(target => ({
        id: target.id, text: target.cueText,
        start: target.sentenceStart, length: target.sentenceLength
      }));
      reader.applySentenceAudioCues(cues);

      function catNode() {
        const walker = reader.createWalker();
        let node;
        while ((node = walker.nextNode())) {
          const offset = node.textContent.indexOf('猫');
          if (offset >= 0) return { node, offset };
        }
        throw Error('rendered screen has no cat');
      }
      function verifyPayload(payload, target, label) {
        check(payload && payload.text === '猫', label + ' selects the real cat', payload);
        check(payload.matchableOffset === target.offset && payload.matchableLength === 1,
          label + ' uses chapter audio UTF-16 coordinates', payload);
        check(payload.sentenceMatchableOffset === target.sentenceStart &&
          payload.sentenceMatchableLength === target.sentenceLength,
          label + ' preserves the sentence audio interval', payload);
        check(payload.normalizedOffset < payload.matchableOffset,
          label + ' does not confuse study units with audio positions', payload);
      }
      function verifySelection(target, phase) {
        const hit = catNode();
        window.lastPayload = null;
        selection.selectFromPosition(hit.node, hit.offset, 1);
        verifyPayload(window.lastPayload, target, phase + ' lookup');
        const range = document.createRange();
        range.setStart(hit.node, hit.offset);
        range.setEnd(hit.node, hit.offset + 1);
        window.getSelection().removeAllRanges();
        window.getSelection().addRange(range);
        verifyPayload(selection.nativeSelectionSentenceRange(), target, phase + ' native');
        window.getSelection().removeAllRanges();
      }
      for (const target of fixture.targets) {
        reader.clearSentenceAudioCue();
        reader.renderScreen(target.screen, true);
        if (fixture.mode === 'sentence') {
          check(reader.sourceRoot.querySelector('p').childNodes.length === 1 &&
            reader.screen.textContent === '猫がいる。',
            'a nonzero source-node slice becomes the rendered screen');
        }
        verifySelection(target, 'before highlight');
        const before = reader.currentScreenIndex;
        reader.highlightSentenceAudioCue(target.id, true);
        check(reader.currentScreenIndex === before,
          'following the selected cue stays on its original screen',
          { expected: before, actual: reader.currentScreenIndex });
        const highlighted = Array.from(reader.screen.querySelectorAll(
          '.fushi-sentence-audio-active')).map(node => node.textContent).join('');
        check(highlighted === target.cueText,
          'audio highlights exactly the selected sentence, excluding ruby rt', highlighted);
        verifySelection(target, 'after wrapper split');

        // Also verify forward/backward follow from a different visible screen.
        reader.clearSentenceAudioCue();
        reader.renderScreen((target.screen + 1) % reader.screens.length, true);
        reader.highlightSentenceAudioCue(target.id, true);
        check(reader.currentScreenIndex === target.screen,
          'chapter audio position follows back to the correct occurrence');
      }
      return fixture.targets.length;
    })()`);
    assert.equal(result, fixture.targets.length);
    count += result;
  }
  // 跨屏合并（`vnMergeCrossScreenSentenceAudioCues`）走的是
  // mergeSentenceAudioCrossScreenScreens，屏界换算与上面三处同源但代码另在一处；
  // 上面的 fixture 一律 merge=false，改错那几行不会被它们发现。
  const mergeFixture = {
    name: 'cue spanning two sentence screens merges them',
    mode: 'sentence',
    merge: true,
    // 学习单位与音频 UTF-16 必须在这里分岔，否则换错坐标也能蒙对：
    // `Eighty Six部隊` 归一化后是 11 个 UTF-16 单元，学习单位只算 4 个。
    html: '<p>Eighty Six部隊。𠀀猫がいる。犬もいる。</p>',
  };
  const merged = await driver.evalOnPage(pageFor(mergeFixture), `(() => {
    const reader = window.fushiReader;
    function check(condition, label, details) {
      if (!condition) throw Error('merge: ' + label +
        (details === undefined ? '' : ' ' + JSON.stringify(details)));
    }
    check(reader.screens.length === 3, 'fixture starts as three sentence screens',
      reader.screens.length);
    // 「𠀀猫がいる」 自 11 起 6 个 UTF-16 单元，「犬もいる」 再 4 个——一条 11..21 的 cue
    // 正好横跨第 2、3 屏。按学习单位算屏界会得到完全不同的一对下标。
    reader.applySentenceAudioCues([
      { id: 'span', text: '𠀀猫がいる。犬もいる', start: 11, length: 10 }
    ]);
    check(reader.screens.length === 2, 'the two straddled screens merge into one',
      reader.screens.length);
    reader.highlightSentenceAudioCue('span', true);
    check(reader.currentScreenIndex === 1, 'follow lands on the merged screen',
      reader.currentScreenIndex);
    const text = reader.screen.textContent;
    check(text.indexOf('猫がいる') >= 0 && text.indexOf('犬もいる') >= 0,
      'the merged screen shows both straddled sentences', text);
    return reader.screens.length;
  })()`);
  assert.equal(merged, 2);
  console.log('PASS ' + count + ' VN lookup/audio targets');
  console.log('PASS 1 VN cross-screen merge');
} finally {
  driver.close();
}
