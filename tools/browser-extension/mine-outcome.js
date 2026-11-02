// 制卡结果分类的唯一判据（纯函数，content script / background service worker / node 测试共用）。
//
// 为什么独立成文件：YouTube 批量制卡从 content script 搬到了 service worker（用户 2026-10-04：
// 「点进去放一会儿视频才能制卡，能不能全自动」——生成只是逐条调 /api/mine，本不需要视频页），
// Netflix 回放录制仍在 content script 里分类。两边必须同一判据，否则「什么算成功出队」会分叉。
//
// resp 形状见 background.js：HTTP 成功 {ok:true,status,data}；非 2xx {ok:false,status,data:null}；
// fetch 抛异常（连接被拒/超时/DNS）{ok:false,error}。
//
// 返回 {cls, notice, settingsFixable, itemFault, reason}：
// - cls：'done'（卡已建 success / 已存在 duplicate → 出队）| 'unconfigured'（Anki 未配置 → 留队）
//   | 'retry'（可能自行恢复的失败 → 留队下次重试）| 'failed'（永久失败 → 移进失败分组，不再参与
//   生成；EMI05fe8RJ）。只有 done 才出队（TODO-1184）。
//   'failed' 的来源：服务端回 errorKind:'permanent'（付费 / 已删除 / 不可用视频、无效时间窗），
//   或 HTTP 400 / 422（这条请求本身不合法，重发也一样）。
// - notice：要给用户看的一句（'✗ 原因' / '⚠ 音频落空警告'），无则 null（TODO-1303 / TODO-1331）。
// - settingsFixable：401 / 其它 4xx 的文案是让用户去扩展设置核对 token，提示可点直达设置页。
// - itemFault：失败是否归咎于这一项本身（服务端答复了、但这张卡制不出来）。连不上 app / 401 /
//   5xx / 服务端 errorKind:'transient'（网络、判 bot、AnkiConnect 不可达）是环境问题，不计入该项的
//   尝试次数——否则 app 或 AnkiConnect 没开时点几次生成，整队都会被判失败。
// - reason：失败原因原文（无 '✗ ' 前缀），记进队列项 lastError 给失败分组显示；成功为 null。
(function (g) {
  'use strict';

  /**
   * HTTP/网络层失败翻成用户能懂的原因（TODO-1331）。
   * @param {object|null} resp background 回的制卡响应
   * @param {(key: string, params?: object) => string} t 文案函数
   * @returns {string}
   */
  function fushiMineHttpFailureReason(resp, t) {
    if (!resp) return t('mine_err_no_response');
    const status = typeof resp.status === 'number' ? resp.status : 0;
    if (status === 401) return t('mine_err_401');
    if (status === 404) return t('mine_err_404');
    if (status >= 500) return t('mine_err_5xx', { status });
    if (status >= 400) return t('mine_err_4xx', { status, error: resp.error || t('mine_err_check_settings') });
    // ok:false 且无 status = fetch 抛异常（连接被拒/超时/DNS）：server 没开或主机/端口错。
    return t('mine_err_unreachable', { error: resp.error || t('mine_err_refused') });
  }

  /**
   * @param {object|null} resp background 回的制卡响应
   * @param {(key: string, params?: object) => string} t 文案函数
   * @returns {{cls: 'done'|'unconfigured'|'retry'|'failed', notice: string|null, settingsFixable: boolean,
   *   itemFault: boolean, reason: string|null}}
   */
  function fushiMineOutcome(resp, t) {
    if (!resp || !resp.ok || !resp.data) {
      const st = resp && typeof resp.status === 'number' ? resp.status : 0;
      const why = fushiMineHttpFailureReason(resp, t);
      // 400 / 422：服务端解析这条请求就失败了（字段缺失 / 类型错）——同一项重发结果相同。
      const permanent = st === 400 || st === 422;
      return {
        cls: permanent ? 'failed' : 'retry',
        notice: '✗ ' + why,
        settingsFixable: st === 401 || (st >= 400 && st < 500 && st !== 404),
        itemFault: permanent,
        reason: why,
      };
    }
    const d = resp.data;
    const r = d.result;
    // 服务端回带诊断（message=失败原因/音频落空警告，detail=技术细节）。
    const reason = (d.message || d.detail || '').toString();
    if (r === 'success' || r === 'duplicate') {
      // 部分成功：卡建好了但单词音频落空（message 非空）→ 警告但仍算 done（卡确实建了）。
      return {
        cls: 'done', notice: (r === 'success' && reason) ? '⚠ ' + reason : null, settingsFixable: false,
        itemFault: false, reason: null,
      };
    }
    if (r === 'notConfigured') {
      return { cls: 'unconfigured', notice: null, settingsFixable: false, itemFault: false, reason: null };
    }
    const why = reason || t('mine_err_failed_retry');
    // 是否归咎于该项只看服务端分型：permanent → 直接失败；transient（网络 / 超时 / 判 bot / 限流 /
    // AnkiConnect 不可达）是环境问题，不计入该项尝试次数——否则 AnkiConnect 没开或 YouTube 持续判
    // bot 时连点 3 次生成，整条队列都会被移进失败分组。只有不回 errorKind 的旧服务端无从区分，
    // 才走计次兜底（FUSHI_MINE_MAX_ITEM_ATTEMPTS）。
    const kind = d.errorKind;
    return {
      cls: kind === 'permanent' ? 'failed' : 'retry',
      notice: '✗ ' + why,
      settingsFixable: false,
      itemFault: kind !== 'transient',
      reason: why,
    };
  }

  // 服务端答复了 error 但没给 errorKind（旧服务端）、同一项连续这么多次都没制出来：降级为失败项，
  // 不再让它每次生成都排在前面重跑（EMI05fe8RJ 的兜底）。服务端明确标 transient 的不计次。
  const FUSHI_MINE_MAX_ITEM_ATTEMPTS = 3;

  /**
   * 队列项是否还在「待生成」：失败分组里的项不参与生成，只等用户手动重试或删除。
   * @param {object|null} item
   * @returns {boolean}
   */
  function fushiQueueItemPending(item) {
    return !!item && item.failed !== true;
  }

  /**
   * 把一次失败的制卡结果记到队列项上（纯函数，返回新数组，只改 id 命中的那一项）。
   * - outcome.cls==='failed' → 直接进失败分组；
   * - 归咎于该项的 retry（itemFault）→ attempts+1，达到上限也进失败分组；
   * - 环境类失败（连不上 / 401 / 5xx）与 unconfigured → 原样不动。
   * @param {Array<object>} queue
   * @param {string} id
   * @param {{cls: string, itemFault?: boolean, reason?: string|null}} outcome
   * @returns {{queue: Array<object>, movedToFailed: boolean}}
   */
  function fushiQueueAfterMineFailure(queue, id, outcome) {
    const list = Array.isArray(queue) ? queue : [];
    let moved = false;
    const next = list.map((it) => {
      if (!it || it.id !== id || !outcome) return it;
      if (outcome.cls !== 'failed' && !(outcome.cls === 'retry' && outcome.itemFault)) return it;
      const attempts = (typeof it.attempts === 'number' ? it.attempts : 0) + 1;
      const failed = outcome.cls === 'failed' || attempts >= FUSHI_MINE_MAX_ITEM_ATTEMPTS;
      if (failed && it.failed !== true) moved = true;
      const out = Object.assign({}, it, { attempts });
      if (outcome.reason) out.lastError = String(outcome.reason);
      if (failed) out.failed = true;
      return out;
    });
    return { queue: next, movedToFailed: moved };
  }

  /**
   * 失败分组里的「重试」：清掉失败标记与计数，回到待生成。
   * @param {Array<object>} queue
   * @param {string} id
   * @returns {Array<object>}
   */
  function fushiQueueRetryFailed(queue, id) {
    const list = Array.isArray(queue) ? queue : [];
    return list.map((it) => {
      if (!it || it.id !== id) return it;
      const out = Object.assign({}, it);
      delete out.failed;
      delete out.attempts;
      delete out.lastError;
      return out;
    });
  }

  const api = {
    fushiMineHttpFailureReason, fushiMineOutcome, fushiQueueItemPending, fushiQueueAfterMineFailure,
    fushiQueueRetryFailed, FUSHI_MINE_MAX_ITEM_ATTEMPTS,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (g) Object.assign(g, api);
})(typeof window !== 'undefined' ? window : (typeof self !== 'undefined' ? self : null));
