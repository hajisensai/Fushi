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
    // 403：app 的网络访问策略（fushi_api_server.dart _networkAccessMiddleware）拒绝了这个来源地址，
    // 与密钥无关——鉴权中间件根本没跑到。解法在 Fushi 的「允许连接」设置里，不是扩展里的密钥。
    forbidden: 'forbidden',
    yomitanConflict: 'yomitan-conflict',
    wrongService: 'wrong-service',
    // BUG-3146：端口上有东西在听，但状态探测在时限内没回话（app 在跑却卡住 / 被系统挂起）。
    // 只由 background 的限时诊断给出，classify 不产出它——classify 拿到的是已完成的响应。
    noResponse: 'no-response',
  });

  function classify(primary, legacy, version, networkError) {
    if (networkError) return states.offline;
    if (primary && primary.status === 200 && primary.body &&
        primary.body.app === 'fushi') {
      return states.connected;
    }
    if ((primary && primary.status === 403) || (legacy && legacy.status === 403)) {
      return states.forbidden;
    }
    if ((primary && primary.status === 401) || (legacy && legacy.status === 401)) {
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

  // 403 的具体原因：app 回纯文本 body（_accessDeniedMessage 三种固定文案）。认不出（旧 app / 别的
  // 403 来源）→ null，文案退到通用说明。
  var forbiddenReasons = Object.freeze({ noKey: 'no-key', notAllowed: 'not-allowed', localOnly: 'local-only' });
  function forbiddenReason(primary, legacy) {
    var hit = (primary && primary.status === 403) ? primary : ((legacy && legacy.status === 403) ? legacy : null);
    var text = hit && typeof hit.text === 'string' ? hit.text : '';
    if (text.indexOf('until an API key is set') >= 0) return forbiddenReasons.noKey;
    if (text.indexOf('not in the Fushi API allowed networks') >= 0) return forbiddenReasons.notAllowed;
    if (text.indexOf('only accepts requests from this device') >= 0) return forbiddenReasons.localOnly;
    return null;
  }

  // 文案走 i18n.js（fushiT）；node 测试壳没装时退回键名。
  function tr(key, params) {
    var g = typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : globalThis);
    return (g && typeof g.fushiT === 'function') ? g.fushiT(key, params) : key;
  }

  function anyManual(manual) {
    return !!manual && !!(manual.host || manual.port || manual.token);
  }

  // 「恢复自动配置」（清掉 options 里手动保存的 host / port / token）能否解决当前状态：
  // manual = background 诊断回带的「哪几个字段是用户手动覆盖的」。密钥被拒且有任何手动覆盖
  // （手填的 token 过期 / 手填的 host 指向别处）→ 能；连不上 / 端口上是别的服务 / Yomitan 占端口
  // 且手动改过 host 或 port → 能。没有手动覆盖时清空是空操作，不给这个按钮。
  function autoConfigFixable(state, manual) {
    if (!manual) return false;
    if (state === states.unauthorized) return anyManual(manual);
    // 403 只看来源地址：手动改过 host 时，自动配置指向的本机回环恒被放行。
    if (state === states.forbidden) return !!manual.host;
    if (state === states.offline || state === states.wrongService ||
        state === states.yomitanConflict) {
      return !!(manual.host || manual.port);
    }
    return false;
  }

  function copy(state, port, manual, reason) {
    var p = Number(port) || 19633;
    if (state === states.connected) {
      return { title: tr('conn_state_connected_title'), detail: tr('conn_state_connected_detail'), tone: 'good' };
    }
    if (state === states.legacy) {
      return { title: tr('conn_state_legacy_title'), detail: tr('conn_state_legacy_detail'), tone: 'good' };
    }
    if (state === states.unauthorized) {
      // 有手动覆盖：恢复自动配置即可（设置页状态卡就地给按钮）。没有：background 已重读过
      // 磁盘上的自动配置仍被拒，说明 Fushi 没有把当前密钥写进这份扩展目录——重新运行安装助手。
      return {
        title: tr('conn_state_unauthorized_title'),
        detail: tr(anyManual(manual) ? 'conn_state_unauthorized_detail' : 'conn_state_unauthorized_auto_detail'),
        tone: 'warn',
      };
    }
    if (state === states.forbidden) {
      var key = reason === forbiddenReasons.noKey ? 'conn_state_forbidden_no_key_detail'
        : reason === forbiddenReasons.notAllowed ? 'conn_state_forbidden_not_allowed_detail'
          : reason === forbiddenReasons.localOnly ? 'conn_state_forbidden_local_only_detail'
            : 'conn_state_forbidden_detail';
      return { title: tr('conn_state_forbidden_title'), detail: tr(key), tone: 'danger' };
    }
    if (state === states.yomitanConflict) {
      return {
        title: tr('conn_state_yomitan_title'),
        detail: tr('conn_state_yomitan_detail', { port: p }),
        tone: 'danger',
      };
    }
    if (state === states.noResponse) {
      return { title: tr('conn_state_no_response_title'), detail: tr('conn_state_no_response_detail'), tone: 'warn' };
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

  return {
    states: states, classify: classify, copy: copy, autoConfigFixable: autoConfigFixable,
    forbiddenReasons: forbiddenReasons, forbiddenReason: forbiddenReason,
  };
});
