// 查词后自动朗读（扩展侧）行为守卫。
//
// 用户报：在扩展里查词，单词音频不会自动播放。app 的全局偏好 `autoReadOnLookup` 早就在
// app 内弹窗 / app 外浮窗 / 剪贴板面板三个表面生效（BUG-1210 就是为「一个表面接了线、另一个
// 没接」收的口），浏览器扩展是最后一个漏掉的。这里钉住补上的那份实现：
//   ① 开关来自 app 下发（扩展不另立开关），关着就一个字节都不发；
//   ② 解析走点 ♪ 的同一条 resolveWordAudio 路径，播放走 popup.js 自己的 playWordAudio；
//   ③ 没有可用音频源时不空跑；
//   ④ 换词/关窗作废在途解析——慢响应回来不得盖掉用户已经在看的新词。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const AUTO_READ = fs.readFileSync(path.join(__dirname, 'auto-read.js'), 'utf8');

const flush = async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); };

function load() {
  const resolved = [];   // resolveWordAudio 的调用参数
  const played = [];     // 实际交给 popup.js 播放的 url
  const pendings = [];   // 每次解析各自的 resolver（手动控制何时返回、按次序取）
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    Promise,
    Array,
    String,
  };
  sandbox.window = {
    flutter_inappwebview: {
      callHandler(name, args) {
        if (name !== 'resolveWordAudio') return Promise.resolve(null);
        resolved.push(args);
        return new Promise((resolve) => { pendings.push(resolve); });
      },
    },
    __fushiPlayWordAudioUrl(url) { played.push(url); return Promise.resolve(true); },
  };
  sandbox.window.window = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(AUTO_READ, sandbox, { filename: 'auto-read.js' });
  return {
    window: sandbox.window,
    resolved,
    played,
    // 第 index 次解析（默认最后一次）返回 url。
    settle(url, index) {
      const at = typeof index === 'number' ? index : pendings.length - 1;
      assert.ok(pendings[at], '第 ' + at + ' 次解析并不存在');
      pendings[at](url);
    },
    read(entries, options) {
      return sandbox.window.fushiAutoReadFirstEntry(entries, options);
    },
  };
}

const ENTRIES = [
  { expression: '走る', reading: 'はしる' },
  { expression: '歩く', reading: 'あるく' },
];

test('偏好开着：解析首条词的发音并交给 popup.js 播放', async () => {
  const h = load();
  const started = h.read(ENTRIES, { enabled: true, audioSources: ['jpod101'] });
  assert.strictEqual(started, true, '应发起朗读');
  assert.strictEqual(h.resolved.length, 1, '必须解析一次发音');
  assert.strictEqual(h.resolved[0].expression, '走る',
    '必须按弹窗顶部那条词解析发音（且走点 ♪ 的同一条路径）');
  assert.strictEqual(h.resolved[0].reading, 'はしる');
  h.settle('https://127.0.0.1:19633/api/lookup/audio/file?id=1');
  await flush();
  assert.strictEqual(h.played.join('|'), 'https://127.0.0.1:19633/api/lookup/audio/file?id=1',
    '解析到的音频没有交给 popup.js 播放');
});

test('偏好关着：一个字节都不发（扩展不另立开关，只认 app 下发的那个）', async () => {
  const h = load();
  const started = h.read(ENTRIES, { enabled: false, audioSources: ['jpod101'] });
  assert.strictEqual(started, false);
  assert.strictEqual(h.resolved.length, 0, '偏好关着却仍去解析发音');
  await flush();
  assert.strictEqual(h.played.length, 0);
});

test('没有已启用的音频源：不空跑（那时连 ♪ 按钮都不会渲染）', async () => {
  const h = load();
  assert.strictEqual(h.read(ENTRIES, { enabled: true, audioSources: [] }), false);
  assert.strictEqual(h.resolved.length, 0);
});

test('没有词条 / 首条没有词形：不发起', async () => {
  const h = load();
  assert.strictEqual(h.read([], { enabled: true, audioSources: ['x'] }), false);
  assert.strictEqual(h.read([{ expression: '  ' }], { enabled: true, audioSources: ['x'] }), false);
  assert.strictEqual(h.resolved.length, 0);
});

test('读音缺失时回落到词形本身（不能拿空 reading 去解析）', async () => {
  const h = load();
  h.read([{ expression: 'ねこ' }], { enabled: true, audioSources: ['x'] });
  assert.strictEqual(h.resolved.length, 1);
  assert.strictEqual(h.resolved[0].reading, 'ねこ', '读音缺失时应回落到词形本身');
});

test('换词作废在途解析：慢响应回来不得盖掉用户正在看的新词', async () => {
  const h = load();
  h.read(ENTRIES, { enabled: true, audioSources: ['x'] });          // 第一个词，解析悬着
  h.read([{ expression: '猫', reading: 'ねこ' }], { enabled: true, audioSources: ['x'] });
  h.settle('https://old/audio', 0); // 第一个词的解析这时才回来（慢响应）
  await flush();
  assert.strictEqual(h.played.length, 0, '上一个词的慢响应仍然播了出来');

  h.settle('https://new/audio');
  await flush();
  assert.strictEqual(h.played.join('|'), 'https://new/audio', '当前词的发音没播');
});

test('关窗作废在途解析：弹窗都没了不该再响一声', async () => {
  const h = load();
  h.read(ENTRIES, { enabled: true, audioSources: ['x'] });
  h.window.fushiCancelAutoRead();
  h.settle('https://late/audio');
  await flush();
  assert.strictEqual(h.played.length, 0, '关窗后在途解析回来仍播了');
});
