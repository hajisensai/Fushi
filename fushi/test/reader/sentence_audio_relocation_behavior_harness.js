// 有声书 cue 重定位模块（kSentenceAudioRelocationJs）的行为跑手。
// 由 sentence_audio_relocation_behavior_test.dart 执行：payload = { script, cases }，
// 每个 case 是 { full, cues: [{ needle, hint, length }] }。在 node:vm 里装生产模块，
// 逐 case 调 resolveSpans，把结果 JSON 打到 stdout，由 Dart 侧与影子算法逐条对拍。
const vm = require('node:vm');
const { readPayload } = require('./reader_harness_support.js');

const payload = readPayload();
const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(payload.script, sandbox);
const relocation = sandbox.window.fushiSentenceAudioRelocation;
if (!relocation || typeof relocation.resolveSpans !== 'function') {
  console.error('fushiSentenceAudioRelocation.resolveSpans missing');
  process.exit(1);
}
const out = payload.cases.map((c) => relocation
  .resolveSpans(c.full, c.cues.map((cue, i) => ({ id: 'c' + i, needle: cue.needle, hint: cue.hint, length: cue.length })))
  .map((span) => [span.start, span.len]));
const constants = [relocation.WINDOW, relocation.OVERLAP, relocation.ADJACENT];
const folded = relocation.foldText(payload.foldInput);
process.stdout.write(JSON.stringify({ spans: out, constants, folded }));
