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

  // 文案走 i18n.js（fushiT）；node 测试壳没装时退回键名。
  function tr(key, params) {
    var g = typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : globalThis);
    return (g && typeof g.fushiT === 'function') ? g.fushiT(key, params) : key;
  }

  function copy(state, port) {
    var p = Number(port) || 19633;
    if (state === states.connected) {
      return { title: tr('conn_state_connected_title'), detail: tr('conn_state_connected_detail'), tone: 'good' };
    }
    if (state === states.legacy) {
      return { title: tr('conn_state_legacy_title'), detail: tr('conn_state_legacy_detail'), tone: 'good' };
    }
    if (state === states.unauthorized) {
      return { title: tr('conn_state_unauthorized_title'), detail: tr('conn_state_unauthorized_detail'), tone: 'warn' };
    }
    if (state === states.yomitanConflict) {
      return {
        title: tr('conn_state_yomitan_title'),
        detail: tr('conn_state_yomitan_detail', { port: p }),
        tone: 'danger',
      };
    }
    if (state === states.wrongService) {
      return { title: tr('conn_state_wrong_service_title'), detail: tr('conn_state_wrong_service_detail', { port: p }), tone: 'danger' };
    }
    return {
      title: tr('conn_state_offline_title'),
      detail: tr('conn_state_offline_detail'),
      tone: 'warn',
    };
  }

  return { states: states, classify: classify, copy: copy };
});
