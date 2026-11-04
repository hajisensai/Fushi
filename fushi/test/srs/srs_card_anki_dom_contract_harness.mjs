// Runs the production SRS card shell (srsCardShellHtml + __fushiSrsSetCard) in
// real headless Chrome with the audio part of the real "eggrolls-JLPT10k-v3"
// back template and checks the Anki reviewer DOM contract it depends on:
// `#qa > .VocabAudio` is a direct child of `#qa` (audioStylePatch moves it into
// the header), `[sound:]` keys carry `.replay-button` (forcePlayback clicks it).
// Payload is produced by srs_card_anki_dom_contract_test.dart.
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

// Records every host bridge call before the card is shown.
const stub = `
  window.__calls = [];
  window.flutter_inappwebview = { callHandler: function(name) {
    window.__calls.push([name].concat(Array.prototype.slice.call(arguments, 1)));
    return Promise.resolve(null);
  } };
`;
const prelude = `
  const fails = [];
  const check = (ok, label) => { if (!ok) fails.push(label); };
  const calls = (name) => window.__calls.filter((c) => c[0] === name);
  const visible = () => { const r = calls('onSrsVisibleSounds'); return r.length ? r[r.length - 1][2] : null; };
  const played = () => calls('onSrsPlaySound').map((c) => c[1]);
`;

const CASES = [
  ['autoplay on: word audio moved into the header, reported visible, template force-play reaches the host', 'on', `
    const qa = document.getElementById('qa');
    check(!!qa, 'shell has #qa');
    check(qa && qa.getAttribute('lang') === 'ja', 'lang on #qa: ' + (qa && qa.getAttribute('lang')));
    check(!!document.querySelector('#FrontSide .VocabAudio [data-sound="word.mp3"]'), 'word audio moved into the header');
    check(!document.querySelector('.VocabAudio.\\\\!hidden'), 'hidden container un-hidden');
    const v = visible();
    check(Array.isArray(v), 'visible sounds reported');
    check(v && v.indexOf('word.mp3') >= 0, 'word audio reported visible: ' + JSON.stringify(v));
    check(v && v.indexOf('sent.mp3') >= 0, 'sentence audio reported visible: ' + JSON.stringify(v));
    check(played().indexOf('word.mp3') >= 0, 'forcePlayback clicked .replay-button: ' + JSON.stringify(played()));
    const key = document.querySelector('.SentAudio [data-sound="sent.mp3"]');
    check(!!key && key.classList.contains('replay-button'), 'sentence key carries replay-button');
    key && key.click();
    check(played().indexOf('sent.mp3') >= 0, 'clicking the sentence key plays it: ' + JSON.stringify(played()));
  `],
  ['autoplay off: word audio still visible (manual key), template force-play refused by the gate', 'off', `
    check(!!document.querySelector('#FrontSide .VocabAudio [data-sound="word.mp3"]'), 'word audio moved into the header');
    const v = visible();
    check(v && v.indexOf('word.mp3') >= 0, 'word audio reported visible: ' + JSON.stringify(v));
    check(played().length === 0, 'synthetic click refused while autoplay is off: ' + JSON.stringify(played()));
  `],
];

const driver = await launchChromeDriver();
let passed = 0;
try {
  for (const [name, mode, body] of CASES) {
    const page = payload[mode];
    const result = await driver.evalOnPage(page.shell, `(async () => {
      ${stub}
      ${page.calls}
      await new Promise((r) => setTimeout(r, 0));
      ${prelude}
      try { ${body} } catch (err) { fails.push('threw: ' + err); }
      return fails;
    })()`);
    if (result.length) {
      console.log('FAIL ' + name + ': ' + result.join('; '));
      process.exitCode = 1;
    } else {
      passed++;
    }
  }
} finally {
  driver.close();
}
if (!process.exitCode) console.log('PASS ' + passed + ' browser cases');
