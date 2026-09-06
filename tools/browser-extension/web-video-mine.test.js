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
  // subtitle-providers.js 导出的裁切窗边距原语（manifest 同隔离世界，恒在场）。
  // 传 null 模拟「老宿主没有这个函数」，验证降级不抛。
  clipWindowWithMargin = (startV, endV) => ({
    startMs: Math.max(0, startV - 200), endMs: endV + 200,
  }),
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
  if (clipWindowWithMargin) ctx.fushiClipWindowWithMargin = clipWindowWithMargin;
  if (netflixCueText !== undefined) {
    ctx.extractNetflixCueText = () => netflixCueText;
    ctx.netflixSubtitleContainer = () => ({});
  }
  vm.createContext(ctx);
  vm.runInContext(SRC, ctx);
  return {
    call: windowObj.flutter_inappwebview.callHandler,
    sent, enqueued, toasts, windowObj,
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
  assert.strictEqual(msg.cueStartMs, 61000, 'cueStartMs 是真句首，不带边距');
  // 裁切窗带 ±200ms 边距，与入队批量剪辑那条路同源（`fushiClipWindowWithMargin`）——
  // 此前这条路发裸 cue 窗，叠上字幕轮询粒度会把句子开头切掉一点。
  assert.strictEqual(msg.clipStartMs, 60800);
  assert.strictEqual(msg.clipEndMs, 64700);
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
  assert.strictEqual(sent[0].clipStartMs, 60800, '边距与入队路同源');
  assert.strictEqual(sent[0].clipEndMs, 64700);
});

test('裁切窗边距缺席（老宿主无该原语）→ 退回裸 cue 窗，不抛也不出错卡', async () => {
  const ctx = bilibiliContext();
  ctx.clip = { kind: 'bilibili', id: 'BV1xx411c7mD', part: 1, mode: 'immediate' };
  const { call, sent } = load({
    mineContext: ctx, frame: { base64: 'SU1H' }, clipWindowWithMargin: null,
  });
  const ok = await call('mineEntry', FIELDS);
  assert.strictEqual(ok, true);
  assert.strictEqual(sent[0].clipStartMs, 61000);
  assert.strictEqual(sent[0].clipEndMs, 64500);
  assert.strictEqual(sent[0].cueStartMs, 61000);
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

// PR#1172 复审：普通网页带无关 <video> 的现状（未改行为，仅钉现状）。
//
// ⚠️ 这是**已知行为变化，不是期望行为**。改行为要另开 bug，别在这条用例上「顺手修正」——
// 它存在的唯一目的是让下一个人一眼看见现状，而不是让现状看起来是对的。
//
// 现场：一篇纯文字报道，DOM 里恰好躺着一个与阅读内容无关的 <video>（广告位 / 背景视频 /
// 站内推荐位 / 内嵌社交卡片）。用户在正文上查词制卡，主观上这就是一张「网页文本卡」。
//
// 实测（探针跑的是真代码，不是推测）：
//   · fushiClipSource() 返回 **null** —— 它只看 location（site==='other' 直接返回 null），
//     压根不去 DOM 里找 <video>。所以「有无关视频」并不会让它给出一个「带视频的 mode」；
//   · 但 mineEntry 的门是 `!(clip && clip.mode === 'queue')`，null 同样过门 → 走立即出卡。
//     这一步与改判据之前**等价**（旧判据 site!=='youtube'&&site!=='netflix' 也走这条）；
//   · 真正变了的是这条分支现在**尽力附带媒体**：frame-capture.js 取帧目标是
//     `document.querySelector('video')`（文档序第一个 <video>，谁都不问），于是那个无关
//     视频的当前解码帧被当成本卡封面发了出去，页面标题也一并进 documentTitle。
//
// 扩展侧发出的**消息 type 仍是 'mine'**（全仓没有 'mineImmersion' 这种消息类型）；改道发生
// 在 Dart 侧：ImmersionMinePayload.isImmersion 只要 screenshotBytes != null 就为真，于是
// /api/mine 从 mineEntry(纯文本) 转进 mineImmersion()，卡最终被打上 AnkiMiningSource.video、
// 封面命名 web_shot.jpg、documentTitle = 页面标题。
test('普通网页带一个无关 <video>：解码帧与页面标题照发（现状，非期望行为）', async () => {
  const { call, sent } = load({
    // fushiClipSource() 对普通网页恒 null（实测），与页面里有没有 <video> 无关。
    mineContext: {
      window: null, site: 'other', clip: null,
      youtubeId: null, netflixId: null, mineAtV: null, documentTitle: '',
    },
    // 无关 <video> 就绪 → fushiCaptureCurrentFrame() 取到它的解码帧（实测
    // fushiVideoFrameCapturable(readyState:4) === true，不问这个 video 是不是用户在看的）。
    frame: { base64: 'RlJBTUU=', width: 640, height: 360 },
    title: '某新闻网站 - 一篇纯文字报道',
  });
  const ok = await call('mineEntry', { ...FIELDS, popupSelectionText: '選択したテキスト' });
  assert.strictEqual(ok, true);
  assert.strictEqual(sent.length, 1);
  // ① 消息 type：扩展侧没有第二种制卡消息，永远是 'mine'。
  assert.strictEqual(sent[0].type, 'mine');
  // ② 解码帧：**带**。这就是那条行为变化——图来自与正文无关的那个 <video>。
  assert.strictEqual(sent[0].screenshotBase64, 'RlJBTUU=',
    '现状：无关 <video> 的解码帧被当成本卡封面发出（Dart 侧据此判 isImmersion）');
  // ③ 页面标题：**带**。落到 Anki 的 {document-title}（视频名字段）。
  assert.strictEqual(sent[0].documentTitle, '某新闻网站 - 一篇纯文字报道');
  // ④ 例句仍来自弹窗选区（无关视频没有字幕轨，ctx.window 为 null）。
  assert.strictEqual(sent[0].sentence, '選択したテキスト');
  // ⑤ 没有时间窗：ctx.window 为 null，一个窗字段都不发。
  for (const k of ['cueStartMs', 'clipStartMs', 'clipEndMs', 'mineAtMs']) {
    assert.strictEqual(k in sent[0], false, `无字幕行时不得发 ${k}`);
  }
  // ⑥ 没有可裁源身份：clip 为 null，服务端不会去解析任何流。
  assert.strictEqual('clipSourceKind' in sent[0], false);
  assert.strictEqual('clipSourceId' in sent[0], false);
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


// 多句合一制卡（bridge-shim 侧）：宿主 fushiMineContext 给出 contextSentence/contextWindow 时，
// 立即出卡路必须用合成句 + 并集裁切窗；cueStartMs / mineAtMs 仍指当前句。
function contextualBilibili() {
  const c = bilibiliContext();
  c.contextSentence = '前一句\n正道ではなく邪道\n後の句';
  c.contextWindow = { startV: 58000, endV: 68000 };
  return c;
}

test('多句合一：合成句压过字幕 DOM/轨单句，裁切窗取并集，cueStartMs/mineAtMs 仍是当前句', async () => {
  const { call, sent } = load({
    mineContext: contextualBilibili(),
    frame: null,
    netflixCueText: '画面上那一行',
  });
  await call('mineEntry', FIELDS);
  const msg = sent[0];
  assert.strictEqual(msg.sentence, '前一句\n正道ではなく邪道\n後の句');
  assert.strictEqual(msg.clipStartMs, 57800, '并集 startV - 200');
  assert.strictEqual(msg.clipEndMs, 68200, '并集 endV + 200');
  assert.strictEqual(msg.cueStartMs, 61000, '静态帧定位仍是当前句句首');
  assert.strictEqual(msg.mineAtMs, 62200);
});

test('多句合一：出卡成功后清草稿（一次性）；失败不清', async () => {
  let cleared = 0;
  const world = load({ mineContext: contextualBilibili(), frame: null });
  world.windowObj.fushiClearSentenceDraft = () => { cleared++; return 0; };
  await world.call('mineEntry', FIELDS);
  assert.strictEqual(cleared, 1);
  const failWorld = load({
    mineContext: contextualBilibili(), frame: null,
    mineResult: { ok: true, data: { result: 'error' } },
  });
  failWorld.windowObj.fushiClearSentenceDraft = () => { cleared++; return 0; };
  await failWorld.call('mineEntry', FIELDS);
  assert.strictEqual(cleared, 1, '失败不清草稿，用户可重试同一上下文');
});

test('上下文四个 handler 转发到宿主；宿主缺席时按不支持降级', async () => {
  const world = load({ mineContext: bilibiliContext(), frame: null });
  const calls = [];
  world.windowObj.fushiSetSentenceContext = (p, n) => { calls.push(['set', p, n]); return 3; };
  world.windowObj.fushiClearSentenceDraft = () => { calls.push(['clear']); return 0; };
  world.windowObj.fushiSentenceContextPreview = (a) => { calls.push(['preview', a]); return { total: 3 }; };
  world.windowObj.fushiOpenSentenceContextModal = (a) => { calls.push(['modal', a]); };
  assert.strictEqual(await world.call('setSentenceContext', { prev: 2, next: 1 }), 3);
  assert.strictEqual(await world.call('clearSentenceDraft'), 0);
  assert.deepStrictEqual(await world.call('sentenceContextPreview', { matched: 'x' }), { total: 3 });
  assert.strictEqual(await world.call('openSentenceContextModal', { entryIndex: 1, matched: 'x' }), null);
  assert.deepStrictEqual(calls, [
    ['set', 2, 1], ['clear'], ['preview', { matched: 'x' }], ['modal', { entryIndex: 1, matched: 'x' }],
  ]);
  const bare = load({ mineContext: bilibiliContext(), frame: null });
  assert.strictEqual(await bare.call('setSentenceContext', { prev: 2, next: 1 }), 0);
  assert.strictEqual(await bare.call('clearSentenceDraft'), 0);
  assert.strictEqual(Object.keys(await bare.call('sentenceContextPreview', {})).length, 0);
  assert.strictEqual(await bare.call('openSentenceContextModal', {}), null);
});
