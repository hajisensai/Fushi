// 制卡结果分类的唯一判据（纯函数，content script / background service worker / node 测试共用）。
//
// 为什么独立成文件：YouTube 批量制卡从 content script 搬到了 service worker（用户 2026-10-04：
// 「点进去放一会儿视频才能制卡，能不能全自动」——生成只是逐条调 /api/mine，本不需要视频页），
// Netflix 回放录制仍在 content script 里分类。两边必须同一判据，否则「什么算成功出队」会分叉。
//
// resp 形状见 background.js：HTTP 成功 {ok:true,status,data}；非 2xx {ok:false,status,data:null}；
// fetch 抛异常（连接被拒/超时/DNS）{ok:false,error}。
//
// 返回 {cls, notice, settingsFixable}：
// - cls：'done'（卡已建 success / 已存在 duplicate → 出队）| 'unconfigured'（Anki 未配置 → 留队）
//   | 'retry'（error / HTTP / 网络失败 → 留队下次重试）。只有 done 才出队（TODO-1184）。
// - notice：要给用户看的一句（'✗ 原因' / '⚠ 音频落空警告'），无则 null（TODO-1303 / TODO-1331）。
// - settingsFixable：401 / 其它 4xx 的文案是让用户去扩展设置核对 token，提示可点直达设置页。
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
   * @returns {{cls: 'done'|'unconfigured'|'retry', notice: string|null, settingsFixable: boolean}}
   */
  function fushiMineOutcome(resp, t) {
    if (!resp || !resp.ok || !resp.data) {
      const st = resp && typeof resp.status === 'number' ? resp.status : 0;
      return {
        cls: 'retry',
        notice: '✗ ' + fushiMineHttpFailureReason(resp, t),
        settingsFixable: st === 401 || (st >= 400 && st < 500 && st !== 404),
      };
    }
    const d = resp.data;
    const r = d.result;
    // 服务端回带诊断（message=失败原因/音频落空警告，detail=技术细节）。
    const reason = (d.message || d.detail || '').toString();
    if (r === 'success' || r === 'duplicate') {
      // 部分成功：卡建好了但单词音频落空（message 非空）→ 警告但仍算 done（卡确实建了）。
      return { cls: 'done', notice: (r === 'success' && reason) ? '⚠ ' + reason : null, settingsFixable: false };
    }
    if (r === 'notConfigured') return { cls: 'unconfigured', notice: null, settingsFixable: false };
    return { cls: 'retry', notice: '✗ ' + (reason || t('mine_err_failed_retry')), settingsFixable: false };
  }

  const api = { fushiMineHttpFailureReason, fushiMineOutcome };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (g) Object.assign(g, api);
})(typeof window !== 'undefined' ? window : (typeof self !== 'undefined' ? self : null));
