(function (root, factory) {
  var api = factory();
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.FUSHI_CONNECTION = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var states = Object.freeze({
    connected: 'connected',
    legacy: 'legacy',
    offline: 'offline',
    unauthorized: 'unauthorized',
    yomitanConflict: 'yomitan-conflict',
    wrongService: 'wrong-service',
  });

  function classify(primary, legacy, version, networkError) {
    if (networkError) return states.offline;
    if (primary && primary.status === 200 && primary.body &&
        primary.body.app === 'fushi') {
      return states.connected;
    }
    if ((primary && (primary.status === 401 || primary.status === 403)) ||
        (legacy && (legacy.status === 401 || legacy.status === 403))) {
      return states.unauthorized;
    }
    if (legacy && legacy.status === 200 && legacy.body && legacy.body.type === 'dictionaryResult') {
      return states.legacy;
    }
    if (version && version.status === 200 && version.body && version.body.version != null) {
      return states.yomitanConflict;
    }
    return states.wrongService;
  }

  function copy(state, port) {
    var p = Number(port) || 19633;
    if (state === states.connected) {
      return { title: '已连接 Fushi', detail: '查词、字幕解析和制卡服务均可用。', tone: 'good' };
    }
    if (state === states.legacy) {
      return { title: '已连接旧版 Fushi', detail: '基础功能可用；更新 Fushi 可获得完整连接诊断。', tone: 'good' };
    }
    if (state === states.unauthorized) {
      return { title: 'API 密钥不匹配', detail: '连接到了 Fushi，但扩展中的 Token 已过期。请点“恢复自动配置”或重新运行安装助手。', tone: 'warn' };
    }
    if (state === states.yomitanConflict) {
      return {
        title: '端口被 Yomitan API 占用',
        detail: '端口 ' + p + ' 正由 Yomitan 使用。请在 Yomitan 高级设置中关闭“Enable Yomitan API”，再回 Fushi 开启“Yomitan API 服务器”。',
        tone: 'danger',
      };
    }
    if (state === states.wrongService) {
      return { title: '端口连接到了其他服务', detail: '端口 ' + p + ' 有响应，但不是 Fushi。请检查端口设置或关闭占用该端口的程序。', tone: 'danger' };
    }
    return {
      title: 'Fushi API 未开启',
      detail: '请打开 Fushi → 设置 → 查词 → 开启“Yomitan API 服务器”，然后重新检测。',
      tone: 'warn',
    };
  }

  return { states: states, classify: classify, copy: copy };
});
