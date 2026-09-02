// bridge-shim.js 的 mineEntry 分流守卫：制卡时到底带不带例句、带不带封面。
//
// 根因回归（用户报「B 站外挂了字幕，制卡缺截图 + 例句」）：这里过去的判据是站点名——
//   `if (site !== 'youtube' && site !== 'netflix') { 发 {fields, sentence} }`
// 而 sentence 只从 Netflix 的字幕 DOM 直读、读不到就退回**弹窗内选区**。于是 bilibili.com
// （有外挂字幕轨、有非 DRM 的 `<video>`，只是没有流解析器）整个落进这条分支：
//   · 例句：轨明明在 `fushiActiveFullTrack()` 里，这条路不去问它 → 卡上没有句子；
//   · 封面：画面明明就在 `<video>` 里，这条路一张图都不发 → 卡上没有图。
// 一个站点名枚举把三件正交的能力（有无可裁流 / 有无当前字幕行 / 能否取解码帧）绑死了。
//
// 现在的判据是能力：`clip.mode === 'queue'` 才入队，其余一律立即出卡并尽力附带媒体。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(path.join(__dirname, 'bridge-shim.js'), 'utf8');

// 装一个受控的 content-script 世界：bridge-shim 依赖的每个外部符号都可注入或缺席
// （缺席时它必须靠 `typeof x === 'function'` 安全跳过，不能抛）。
function load({
  mineContext = null,      // window.fushiMineContext 的返回值；null = 该函数不存在
  frame = undefined,       // fushiCaptureCurrentFrame 的返回值；undefined = 该函数不存在
  netflixCueText = undefined, // extractNetflixCueText 的返回值；undefined = 该函数不存在
  enqueueResult = { ok: true, count: 1 },
  title = 'テスト動画_哔哩哔哩_bilibili',
  mineResult = { ok: true, data: { result: 'success' } },
} = {}) {
  const sent = [];
  const enqueued = [];
  const toasts = [];
  const chrome = {
    runtime: {
      sendMessage: (msg, cb) => {
        // bridge-shim 加载时那个 loadFushiDictMediaConfig IIFE 立刻发一条
        // `{type:'dictMediaConfig'}`（词典媒体直连配置，与制卡无关）。不滤掉它，
        // `sent[0]` 恒是它，制卡断言就全落在错的消息上。
        if (!msg || msg.type !== 'dictMediaConfig') sent.push(msg);
        if (typeof cb === 'function') cb(mineResult);
        return Promise.resolve(mineResult);
      },
    },
    storage: { onChanged: { addListener: () => {} } },
  };
  const windowObj = {
    fushiToast: (text) => toasts.push(text),
    fushiEnqueue: (fields, sentence) => {
      enqueued.push({ fields, sentence });
      return enqueueResult;
    },
  };
  if (mineContext !== null) windowObj.fushiMineContext = () => mineContext;
  const ctx = { window: windowObj, chrome, document: { title } };
  if (frame !== undefined) ctx.fushiCaptureCurrentFrame = () => frame;
  if (netflixCueText !== undefined) {
    ctx.extractNetflixCueText = () => netflixCueText;
    ctx.netflixSubtitleContainer = () => ({});
  }
  vm.createContext(ctx);
  vm.runInContext(SRC, ctx);
  return {
    call: windowObj.flutter_inappwebview.callHandler,
    sent, enqueued, toasts,
  };
}

const FIELDS = { expression: '正道', reading: 'せいどう', popupSelectionText: '' };

// 一个「B 站现场」：有外挂字幕轨给出的当前行，没有可裁的原始流，视频帧取得到。
function bilibiliContext() {
  return {
    window: { text: '正道ではなく邪道', startV: 61000, endV: 64500 },
    site: 'other',
    clip: null,
    youtubeId: null,
    netflixId: null,
    mineAtV: 62200,
    documentTitle: '',
  };
}

test('B 站现场：例句来自外挂字幕轨，而不是空的弹窗选区', async () => {
  const { call, sent } = load({
    mineContext: bilibiliContext(),
    frame: { base64: 'SU1H', width: 1920, height: 1080 },
  });
  const ok = await call('mineEntry', FIELDS);
  assert.strictEqual(ok, true);
  assert.strictEqual(sent.length, 1);
  assert.strictEqual(sent[0].type, 'mine', '无可裁流 → 立即出卡，不进批量队列');
  assert.strictEqual(sent[0].sentence, '正道ではなく邪道',
    '这一条就是用户报的「卡里没有例句」——轨在手边却没人去问');
});

test('B 站现场：带上当前解码帧当封面，附时间窗与页面标题', async () => {
  const { call, sent } = load({
    mineContext: bilibiliContext(),
    frame: { base64: 'SU1H', width: 1920, height: 1080 },
  });
  await call('mineEntry', FIELDS);
  const msg = sent[0];
  assert.strictEqual(msg.screenshotBase64, 'SU1H', '画面就在 <video> 里，必须带图');
  assert.strictEqual(msg.cueStartMs, 61000);
  assert.strictEqual(msg.clipStartMs, 61000);
  assert.strictEqual(msg.clipEndMs, 64500);
  assert.strictEqual(msg.mineAtMs, 62200, '制卡那一刻的视频时间');
  assert.strictEqual(msg.documentTitle, 'テスト動画_哔哩哔哩_bilibili',
    '不发标题的话服务端会回落成字面 Netflix');
});

test('取不到帧（DRM/未就绪）→ 不带 screenshotBase64，但照样出卡', async () => {
  const { call, sent } = load({ mineContext: bilibiliContext(), frame: null });
  const ok = await call('mineEntry', FIELDS);
  assert.strictEqual(ok, true);
  assert.strictEqual('screenshotBase64' in sent[0], false,
    '取不到就不带，绝不塞黑图/截屏兜底');
  assert.strictEqual(sent[0].sentence, '正道ではなく邪道', '没有图不影响例句');
});

test('queue 档（Netflix/YouTube）行为不变：仍然入队，不发 mine 消息', async () => {
  const { call, sent, enqueued } = load({
    mineContext: {
      window: { text: 'ネトフリの字幕', startV: 1000, endV: 3000 },
      site: 'netflix', clip: { kind: 'netflix', id: '81', mode: 'queue' },
      netflixId: '81', youtubeId: null, mineAtV: 2000, documentTitle: 'Show',
    },
    frame: { base64: 'SU1H' },
    netflixCueText: 'ネトフリの字幕',
  });
  const ok = await call('mineEntry', FIELDS);
  assert.strictEqual(ok, true);
  assert.strictEqual(sent.length, 0, 'queue 档不得走立即出卡');
  assert.strictEqual(enqueued.length, 1);
  assert.strictEqual(enqueued[0].sentence, 'ネトフリの字幕');
});

test('Netflix 字幕 DOM 直读仍是最高优先级（与画面上那行严格一致）', async () => {
  const { call, enqueued } = load({
    mineContext: {
      window: { text: '轨里的旧句', startV: 1000, endV: 3000 },
      site: 'netflix', clip: { kind: 'netflix', id: '81', mode: 'queue' },
      netflixId: '81', youtubeId: null, mineAtV: 2000, documentTitle: 'Show',
    },
    netflixCueText: '画面上这行',
  });
  await call('mineEntry', FIELDS);
  assert.strictEqual(enqueued[0].sentence, '画面上这行',
    'DOM 直读 == 此刻画面上那一行，优先级不得被轨文本顶掉');
});

test('immediate 档：立即出卡并带上可裁流身份，供服务端裁原始音轨', async () => {
  const ctx = bilibiliContext();
  ctx.clip = {
    kind: 'bilibili', id: 'BV1xx411c7mD', part: 13, mode: 'immediate',
  };
  const { call, sent } = load({ mineContext: ctx, frame: { base64: 'SU1H' } });
  await call('mineEntry', FIELDS);
  assert.strictEqual(sent[0].type, 'mine');
  assert.strictEqual(sent[0].clipSourceKind, 'bilibili');
  assert.strictEqual(sent[0].clipSourceId, 'BV1xx411c7mD');
  assert.strictEqual(sent[0].clipSourcePart, 13,
    '少了分 P 号，服务端会裁第 1 P 的音轨 → 图和句子是这一集、声音是上一集');
  assert.strictEqual(sent[0].clipStartMs, 61000);
  assert.strictEqual(sent[0].clipEndMs, 64500);
});

test('无可裁源时不得发出半个 clipSource（服务端据它决定要不要解析流）', async () => {
  const { call, sent } = load({
    mineContext: bilibiliContext(), frame: { base64: 'SU1H' },
  });
  await call('mineEntry', FIELDS);
  assert.strictEqual('clipSourceKind' in sent[0], false);
  assert.strictEqual('clipSourceId' in sent[0], false);
  assert.strictEqual('clipSourcePart' in sent[0], false);
});

test('普通网页（无轨无视频）：不报「没找到当前字幕」，回落弹窗选区照常出卡', async () => {
  const { call, sent, toasts } = load({
    mineContext: {
      window: null, site: 'other', clip: null,
      youtubeId: null, netflixId: null, mineAtV: null, documentTitle: '',
    },
    frame: null,
  });
  const ok = await call('mineEntry', { ...FIELDS, popupSelectionText: '選択したテキスト' });
  assert.strictEqual(ok, true);
  assert.strictEqual(sent[0].sentence, '選択したテキスト');
  assert.strictEqual('clipStartMs' in sent[0], false, '没有窗就不发窗');
  assert.strictEqual('screenshotBase64' in sent[0], false);
  assert.ok(!toasts.some((t) => t.includes('没找到当前字幕')),
    '普通网页压根没有字幕，不该报这条');
});

test('依赖缺席（老宿主没有 fushiMineContext / 取帧模块）也不抛，退回纯文本卡', async () => {
  const { call, sent } = load({ mineContext: null, frame: undefined });
  const ok = await call('mineEntry', { ...FIELDS, popupSelectionText: 'せんたく' });
  assert.strictEqual(ok, true);
  assert.deepStrictEqual(
    Object.keys(sent[0]).sort(),
    ['documentTitle', 'fields', 'sentence', 'type'],
    '一个媒体字段都不该凭空出现');
  assert.strictEqual(sent[0].sentence, 'せんたく');
});

test('服务端判重复时如实回报，不谎报成功', async () => {
  const { call, toasts } = load({
    mineContext: bilibiliContext(),
    frame: { base64: 'SU1H' },
    mineResult: { ok: true, data: { result: 'duplicate' } },
  });
  const ok = await call('mineEntry', FIELDS);
  assert.strictEqual(ok, true);
  assert.ok(toasts.some((t) => t.includes('已存在')), `实际 toast: ${toasts}`);
});
