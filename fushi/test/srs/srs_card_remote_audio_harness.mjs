// Feedback ffWC0TPq1I: runs the production SRS card shell (srsCardShellHtml with
// the autoplay gate + the remote-audio helper) in real headless Chrome with the
// online-TTS part of the real eggrolls template (setEdgeTTS, verbatim) and checks
// that a page <audio> whose sources are public http(s) URLs is fetched through
// the host bridge (candidates in document order) and played from a blob: URL,
// that a host failure rejects play() like "no supported source", that pause()
// or a card change while the host is fetching cancels the start, and that
// local media (the card media host) never goes through the bridge.
// Payload is produced by srs_card_remote_audio_test.dart.
//
// Exit codes: 0 = all cases passed, 1 = a case failed, 77 = no Chrome.
import fs from 'node:fs';
import { launchChromeDriver, resolveChrome } from '../../../tool/reader_pitch_headless/cdp_client.mjs';

if (!resolveChrome()) {
  console.log('Chrome unavailable');
  process.exit(77);
}
const payload = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

// 0.1 s of silence, mono 8 kHz 16-bit PCM WAV, base64 (what the host bridge returns).
function silenceWavBase64() {
  const n = 800;
  const buf = Buffer.alloc(44 + n * 2);
  buf.write('RIFF', 0);
  buf.writeUInt32LE(36 + n * 2, 4);
  buf.write('WAVE', 8);
  buf.write('fmt ', 12);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(8000, 24);
  buf.writeUInt32LE(16000, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write('data', 36);
  buf.writeUInt32LE(n * 2, 40);
  return buf.toString('base64');
}
const WAV = silenceWavBase64();

// Host bridge stub: records calls; the remote-audio handler answers through
// window.__reply (default: the WAV), or is held until window.__release() runs.
const stub = `
  window.__calls = [];
  window.__reply = function(){ return { mime: 'audio/wav', data: '${WAV}' }; };
  window.__hold = false;
  window.__release = null;
  window.flutter_inappwebview = { callHandler: function(name) {
    var args = Array.prototype.slice.call(arguments, 1);
    window.__calls.push([name].concat(args));
    if (name !== '${payload.handler}') return Promise.resolve(null);
    if (!window.__hold) return Promise.resolve(window.__reply(args[0]));
    return new Promise(function(resolve){
      window.__release = function(){ resolve(window.__reply(args[0])); };
    });
  } };
`;
const prelude = `
  const fails = [];
  const check = (ok, label) => { if (!ok) fails.push(label); };
  const fetches = () => window.__calls.filter((c) => c[0] === '${payload.handler}');
  const ticks = async (n) => { for (let i = 0; i < n; i++) await new Promise((r) => setTimeout(r, 0)); };
  const audio = () => document.querySelector('.SentAudio audio');
  const outcome = async (p) => { try { await p; return 'played'; } catch (e) { return e && e.name; } };
`;

const CASES = [
  ['template TTS key: sources fetched through the host in order, played from blob:', `
    const key = document.querySelector('.SentAudio .tts.replay-button');
    check(!!key, 'setEdgeTTS built the TTS key');
    check(!!audio() && !audio().hasAttribute('src'), 'TTS audio starts with <source> children only');
    key && key.click();
    await ticks(5);
    const f = fetches();
    check(f.length === 1, 'one host fetch: ' + f.length);
    const urls = f.length ? f[0][1] : null;
    check(Array.isArray(urls) && urls.length === 2, 'both candidate sources passed: ' + JSON.stringify(urls));
    check(urls && urls[0].indexOf('https://tts-a.example/api/aiyue?') === 0, 'first candidate first: ' + (urls && urls[0]));
    check(urls && urls[1].indexOf('https://tts-b.example/api/aiyue?') === 0, 'second candidate second: ' + (urls && urls[1]));
    check(urls && urls[0].indexOf('text=') > 0, 'sentence text in the query: ' + (urls && urls[0]));
    const src = audio() && audio().getAttribute('src');
    check(!!src && src.indexOf('blob:') === 0, 'audio now plays a blob: url: ' + src);
    key && key.click();
    await ticks(5);
    check(fetches().length === 1, 'second click plays the blob, no refetch: ' + fetches().length);
  `],
  ['host could not fetch: play() rejects like "no supported source", source untouched', `
    window.__reply = function(){ return { error: 'remote audio unavailable: tts-a.example: HTTP 502' }; };
    const r = await outcome(audio().play());
    check(r === 'NotSupportedError', 'rejected with NotSupportedError: ' + r);
    check(!audio().hasAttribute('src'), 'no src set on failure');
    window.__reply = function(){ return { mime: 'audio/wav', data: '${WAV}' }; };
    await outcome(audio().play());
    check(fetches().length === 2, 'a failed fetch is not cached: ' + fetches().length);
  `],
  ['pause() while the host is fetching cancels the start', `
    window.__hold = true;
    const p = audio().play();
    await ticks(2);
    audio().pause();
    window.__release && window.__release();
    const r = await outcome(p);
    check(r === 'AbortError', 'interrupted by pause: ' + r);
    check(!audio().hasAttribute('src'), 'no src swapped after pause');
  `],
  ['card change while the host is fetching cancels the start', `
    window.__hold = true;
    const p = audio().play();
    await ticks(2);
    window.__fushiSrsStopAllMedia();
    window.__release && window.__release();
    const r = await outcome(p);
    check(r === 'AbortError', 'interrupted by the card change: ' + r);
    check(!audio().hasAttribute('src'), 'no src swapped after the card change');
  `],
  ['local card media never goes through the host', `
    const local = document.createElement('audio');
    local.src = 'https://srs.local/media/word.mp3';
    document.body.appendChild(local);
    const blob = document.createElement('audio');
    blob.src = 'data:audio/wav;base64,${WAV}';
    document.body.appendChild(blob);
    await outcome(local.play());
    await outcome(blob.play());
    check(fetches().length === 0, 'no host fetch for local media: ' + fetches().length);
  `],
];

const driver = await launchChromeDriver();
let passed = 0;
try {
  for (const [name, body] of CASES) {
    const result = await driver.evalOnPage(payload.shell, `(async () => {
      ${stub}
      ${payload.calls}
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
