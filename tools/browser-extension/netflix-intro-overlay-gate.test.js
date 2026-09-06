// BUG-2170 守卫：Netflix 批量自动制卡**切集后**必须先把片头年龄分级 overlay 播过去再开录。
//
// 复诉根因：批量状态机到达目标集后只 `fushiWaitForPlayer` + `sleep(800)` 就开 tabCapture 并
// 逐句录制，而 Netflix 每集开播时会在左上角显示数秒年龄分级 overlay（"RATED 13+ / 暴力, 自杀"）。
// tabCapture 录的是**合成后的标签页画面**，于是这段窗内的 clip 把提示烧进了卡片图。常驻 CSS
// 隐藏（TODO-1391）不是保证——它受用户开关 netflixHideNextEpisode 门控，选择器也随 Netflix
// 哈希类名漂移，所以录制侧另加一道与选择器无关的时间门。
//
// 本文件在受控 vm 里真加载 content.js，钉住这些**做错了会静默退化**的性质：
//   ① 等待判据是「播放推进量」，不是墙钟、也不是绝对位置——中途续播的集，提示同样在开播那
//      几秒出现，只看绝对位置会让续播集直接放行（等于没修）。
//   ② 等待有上界，而且上界**真的成立**：await 一个可能永不 settle 的 play() 会把上界作废。
//   ③ 放弃名单由门的实际结果驱动。门没跑 / 门确认已播过 → 一张都不放弃；只有「门跑了但到
//      上界仍没播过去」这一档才按门实际观察到的窗口保守放弃，且不从队列里删。
const test = require('node:test');
const assert = require('node:assert');
const {
  loadContentSandbox,
  readConst,
} = require('./scripts/vm-content-harness.js');

function loadContent() {
  return loadContentSandbox();
}

function introSec(sandbox) {
  return readConst(sandbox, 'kNfIntroOverlaySec');
}

// 假 <video>：currentTime 由「已播放的墙钟 × rate」推出。rate 放大只是为了让测试跑得快，
// 被测逻辑看到的仍是「媒体时间在前进」这一个事实。
function makeVideo(startSec, rate, playImpl) {
  const v = {
    paused: true,
    playCalls: 0,
    _base: startSec,
    _since: 0,
    play() {
      v.playCalls++;
      if (playImpl) return playImpl(v);
      if (v.paused) { v.paused = false; v._since = Date.now(); }
      return Promise.resolve();
    },
  };
  Object.defineProperty(v, 'currentTime', {
    get() {
      if (v.paused) return v._base;
      return v._base + ((Date.now() - v._since) / 1000) * rate;
    },
  });
  return v;
}

test('①a 从头开播：把提示窗真播过去才放行', async () => {
  const { sandbox } = loadContent();
  const sec = introSec(sandbox);
  assert.ok(sec > 0, 'kNfIntroOverlaySec 必须是正数秒');
  const v = makeVideo(0, 200); // 200× 媒体时间，窗内耗时 ≈ sec/200 秒
  const t0 = Date.now();
  const gate = await sandbox.fushiWaitPastNetflixIntroOverlay(v, 5000);
  assert.strictEqual(gate.ok, true, '播过窗应报 ok');
  assert.strictEqual(gate.ran, true, '门确实跑过');
  assert.ok(v.currentTime >= sec, '返回时媒体位置必须已越过提示窗');
  assert.ok(Date.now() - t0 >= 1, '不能同步放行（同步放行=完全没等）');
  assert.ok(v.playCalls > 0, '暂停态必须补 play()，否则永远等不到推进');
});

test('①b 中途续播：判据是推进量而不是绝对位置（只看位置会让续播集直接放行）', async () => {
  const { sandbox } = loadContent();
  const sec = introSec(sandbox);
  const v = makeVideo(600, 200); // 已在第 10 分钟：绝对位置远超窗，但这一集刚开播
  const gate = await sandbox.fushiWaitPastNetflixIntroOverlay(v, 5000);
  assert.strictEqual(gate.ok, true);
  assert.strictEqual(gate.base, 600, '门必须把观察到的基线报出来');
  assert.ok(v.currentTime - 600 >= sec,
    '必须相对开始等待时的位置再推进一整个提示窗，不能因绝对位置大就放行');
});

test('②  推不动时有上界返回 ok:false，不无限等卡死批量', async () => {
  const { sandbox } = loadContent();
  const v = makeVideo(0, 0); // rate=0：play() 了也不前进（DRM/弱网）
  const t0 = Date.now();
  const gate = await sandbox.fushiWaitPastNetflixIntroOverlay(v, 400);
  assert.strictEqual(gate.ok, false, '到上界仍没播过窗必须报 ok:false 让批量继续');
  assert.strictEqual(gate.ran, true);
  assert.ok(Date.now() - t0 < 3000, '必须在 maxMs 量级内返回');
  assert.ok(v.playCalls > 0, '等待期间应反复补 play()');
});

test('②b play() 永不 settle 时上界仍然成立（await 它就是死锁）', async () => {
  // 这是上一条测不到的那一档，也是整批唯一的串行关键路径上最致命的形状：
  // 媒体永远不就绪（DRM 授权卡住 / 弱网 stall）时 v.play() 返回的 promise 可以
  // 无限期 pending，既不 resolve 也不 reject。旧实现 `await v.play()` 一挂，
  // tick 链就断了、setTimeout 永不排期、外层 Promise 永不 settle —— 状态机的
  // await 永久挂起，fushiNfBatchRunning 连 finally 都到不了，此后任何图标点击
  // 都被重入锁挡掉，只能刷页面。上一条的假 play() 恒 resolve，抓不到它。
  const { sandbox } = loadContent();
  const v = makeVideo(0, 0, () => new Promise(() => {})); // 永不 settle
  const t0 = Date.now();
  const gate = await sandbox.fushiWaitPastNetflixIntroOverlay(v, 400);
  assert.strictEqual(gate.ok, false);
  assert.ok(Date.now() - t0 < 3000, 'play() 挂住也必须在 maxMs 量级内返回');
});

test('②c 没有 <video> 时立即返回（不 hang），且标记为「门没跑」', async () => {
  const { sandbox } = loadContent();
  const gate = await sandbox.fushiWaitPastNetflixIntroOverlay(null, 400);
  assert.strictEqual(gate.ok, false);
  assert.strictEqual(gate.ran, false, '没有 video = 门根本没观察到任何东西');
});

test('③  门确认已播过提示：一张都不放弃', () => {
  const { sandbox } = loadContent();
  const ms = introSec(sandbox) * 1000;
  const items = [
    { id: 'a', startV: 0 },
    { id: 'b', startV: ms - 1 },
    { id: 'c', startV: ms + 60000 },
  ];
  const split = sandbox.fushiSplitNetflixIntroOverlayItems(
    items, { ok: true, ran: true, base: 0 });
  // Array.from：vm 里造的数组原型属于另一个 realm，deepStrictEqual 会因原型不同而假红。
  assert.deepStrictEqual(Array.from(split.skipped, (q) => q.id), []);
  assert.deepStrictEqual(Array.from(split.recordable, (q) => q.id), ['a', 'b', 'c']);
});

test('③b 门没跑（就地续跑）：一张都不放弃', () => {
  // 这条是旧实现最实际的伤害：门明确只挂 fromLoad，而放弃名单**无条件**执行。
  // 用户在片头 5 秒处排了 3 张卡、看到一半点扩展图标就地生成——页面没重载、没有
  // 任何 overlay——那 3 张仍被全部放弃、计入失败、留在队列，再点一次同样结果，
  // 永远生成不出来；而结尾还告诉他「可再点生成重试」。
  const { sandbox } = loadContent();
  const items = [{ id: 'a', startV: 0 }, { id: 'b', startV: 5000 }];
  for (const gate of [null, undefined, { ok: false, ran: false, base: 0 }]) {
    const split = sandbox.fushiSplitNetflixIntroOverlayItems(items, gate);
    assert.deepStrictEqual(Array.from(split.skipped), []);
    assert.deepStrictEqual(Array.from(split.recordable, (q) => q.id), ['a', 'b']);
  }
});

test('③c 门跑了但没播过去：按门实际观察到的窗口放弃，不是按绝对位置', () => {
  // 从 600s 续播时提示窗在 [600, 608)，旧实现砍的却是 [0, 8)——两个区间没有交集，
  // 既没保护到什么，又确定性丢卡。
  const { sandbox } = loadContent();
  const ms = introSec(sandbox) * 1000;
  const items = [
    { id: 'early', startV: 0 },              // 绝对位置在 [0,8)，但不在门的窗里
    { id: 'in', startV: 600000 },            // 窗起点
    { id: 'in2', startV: 600000 + ms - 1 },  // 窗内最后一毫秒
    { id: 'out', startV: 600000 + ms },      // 边界：窗结束即可录
  ];
  const split = sandbox.fushiSplitNetflixIntroOverlayItems(
    items, { ok: false, ran: true, base: 600 });
  assert.deepStrictEqual(Array.from(split.skipped, (q) => q.id), ['in', 'in2']);
  assert.deepStrictEqual(
    Array.from(split.recordable, (q) => q.id), ['early', 'out']);
  // 放弃 ≠ 丢弃：原数组不被改动，队列项仍在（真正的出队只在 fushiRemoveQueued(okIds)）。
  assert.strictEqual(items.length, 4);
});

test('③d 空输入不炸', () => {
  const { sandbox } = loadContent();
  for (const bad of [undefined, null, []]) {
    const split = sandbox.fushiSplitNetflixIntroOverlayItems(
      bad, { ok: false, ran: true, base: 0 });
    assert.deepStrictEqual(Array.from(split.skipped), []);
    assert.deepStrictEqual(Array.from(split.recordable), []);
  }
});

test('③e 放弃必须可见：有被跳过的句就明确告知，0 张时不打扰', () => {
  const { sandbox, toasts } = loadContent();
  sandbox.fushiToastNetflixIntroSkipped(0);
  assert.strictEqual(toasts.length, 0, '没跳过任何句时不应弹提示');
  sandbox.fushiToastNetflixIntroSkipped(3);
  assert.strictEqual(toasts.length, 1);
  assert.match(toasts[0], /3/, '提示里要有被放弃的张数');
  assert.match(toasts[0], /队列/, '要说明卡还留在队列里（没有被静默丢掉）');
});
