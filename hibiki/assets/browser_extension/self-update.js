// BUG-1079：扩展自更新状态机（纯函数，node 可测）。
// 背景：background.js 的自更新此前用「对某 remote build reload 过一次就永不重试」的 latch
// 防死循环，但 reload 失败（磁盘副本没刷成 / 用户从别的目录加载 / 浏览器拒绝 reload）后
// 会永久停在旧版且零提示。这里把决策抽成纯函数：
// - 同一 remote build 仍只 reload 一次（防无限 reload 循环不变）；
// - 已 reload 过仍不一致 → 判定自更新失效（stale），由调用方落 chrome.storage 提示用户；
// - 恢复一致 → clear，由调用方清除 stale 提示。
(function (root, factory) {
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.HIBIKI_SELF_UPDATE = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var actions = Object.freeze({
    none: 'none',       // 任一侧缺指纹 / 录制中：什么都不做（向后兼容，绝不空转）
    reload: 'reload',   // 首次发现新 build：chrome.runtime.reload() 从磁盘拉新
    stale: 'stale',     // 已为该 build reload 过仍不一致：自更新失效，提示用户手动重载
    clear: 'clear',     // 两侧一致：清除 stale 提示（自更新已生效 / 用户已手动重载）
  });

  // remote = server 下发的内置指纹（extensionBuild）；local = 当前加载副本的
  // HIBIKI_DEFAULTS.build；reloadedFor = storage 里记录的「已为哪个 build reload 过」；
  // recording = 正在逐句回放录制（reload 会杀 offscreen 录制，跳过本轮）。
  function decide(remote, local, reloadedFor, recording) {
    if (!remote || !local) return { action: actions.none };
    if (remote === local) return { action: actions.clear };
    if (recording) return { action: actions.none };
    if (reloadedFor === remote) {
      return { action: actions.stale, stale: { remote: remote, local: local } };
    }
    return { action: actions.reload };
  }

  // BUG-1079：/api/extension/status 请求体——扩展自报「浏览器中实际加载的版本」。
  // 此前写死 '{}'，app 端无从得知浏览器里跑的是哪个 build。旧 app 忽略 body，向后兼容。
  function statusRequestBody(defaults, manifestVersion) {
    var body = {};
    if (defaults && typeof defaults.build === 'string' && defaults.build) {
      body.build = defaults.build;
    }
    if (typeof manifestVersion === 'string' && manifestVersion) {
      body.version = manifestVersion;
    }
    return JSON.stringify(body);
  }

  // options 页「版本与更新」卡片：把自更新链路的状态翻成用户可读文案（纯函数，node 可测）。
  // 三态：stale（自动更新失效，需手动重载）/ dev（无内容指纹的开发副本，不参与自动更新）/
  // ok（正常：Hibiki 升级 → 磁盘副本刷新 → 扩展自动 reload）。
  function describeUpdateState(defaults, stale) {
    var build = (defaults && typeof defaults.build === 'string' && defaults.build)
        ? defaults.build : '';
    var short = function (s) { return String(s || '').slice(0, 8); };
    if (stale && stale.remote) {
      return {
        tone: 'warn',
        title: '自动更新未生效',
        detail: 'Hibiki 已内置新版扩展（' + short(stale.remote) + '），请到 chrome://extensions '
            + '找到本扩展点「重新加载」。当前加载：' + (short(stale.local) || '未知') + '。',
        build: build,
      };
    }
    if (!build) {
      return {
        tone: 'neutral',
        title: '开发副本（不参与自动更新）',
        detail: '此副本没有内容指纹（未经 Hibiki 安装助手解压），不会自动跟随 Hibiki 更新。',
        build: '',
      };
    }
    return {
      tone: 'ok',
      title: '随 Hibiki 自动更新',
      detail: 'Hibiki 升级后会刷新磁盘副本，扩展在下次心跳/查词时自动重载到最新版。',
      build: build,
    };
  }

  return {
    actions: actions,
    decide: decide,
    statusRequestBody: statusRequestBody,
    describeUpdateState: describeUpdateState,
  };
});
