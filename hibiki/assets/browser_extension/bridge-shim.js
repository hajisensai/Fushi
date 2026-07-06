// 垫掉 popup.js 里的 flutter_inappwebview.callHandler，转成扩展逻辑。
// 必须在 popup.js 之前加载（manifest content_scripts 顺序保证）。
window.flutter_inappwebview = {
  callHandler: function (name, ...args) {
    switch (name) {
      case 'popupRendered':
        if (window.__hibikiOnRendered) window.__hibikiOnRendered(args[0]);
        return Promise.resolve(null);
      case 'mineEntry':
        // 批量制卡：点「制卡」= 入队（瞬间，不录不裁不暂停）。末尾统一「生成全部」。
        // subtitle-adapters.js 同 content-script world 提供 Netflix 取词函数；缺失时回落选区文本。
        return new Promise((resolve) => {
          var toast = function (text, sticky) {
            if (typeof window.hibikiToast === 'function') window.hibikiToast(text, sticky);
          };
          var cueText = (typeof extractNetflixCueText === 'function')
            ? extractNetflixCueText(netflixSubtitleContainer()) : '';
          var sentence = cueText || (args[0] && args[0].popupSelectionText) || '';
          var res = (typeof window.hibikiEnqueue === 'function')
            ? window.hibikiEnqueue(args[0], sentence) : { ok: false, reason: 'no-queue' };
          if (res && res.ok && res.duplicate) toast('✓ 已在制卡队列中（' + res.count + '）');
          else if (res && res.ok) toast('✓ 已加入制卡队列（' + res.count + '）\n看完后一次生成全部');
          else if (res && res.reason === 'no-cue') toast('✗ 没找到当前字幕，稍候再试');
          else toast('✗ 入队失败');
          resolve(!!(res && res.ok));
        });
      case 'duplicateCheck':
        // TODO-1176：真查重（+→✓，与 app 内一致）。经 background.js 转发到 server
        // /api/duplicate（Anki findNotes / findDuplicateNotes）。任何失败（扩展已重载、
        // server 未开、未配置 Anki）都 fail-soft 成 false → 弹窗显示「+」，绝不阻断查词。
        return (async function () {
          try {
            var a = args[0] || {};
            var resp = await chrome.runtime.sendMessage({
              type: 'duplicate',
              expression: a.expression || '',
              reading: a.reading || '',
            });
            return !!(resp && resp.ok && resp.data && resp.data.duplicate === true);
          } catch (_) {
            return false;
          }
        })();
      case 'onLinkClick':
        if (window.__hibikiOnLinkClick) window.__hibikiOnLinkClick(args[0]);
        return Promise.resolve(null);
      case 'tapOutside':
        if (window.__hibikiOnTapOutside) window.__hibikiOnTapOutside();
        return Promise.resolve(null);
      case 'openLink':
        try { window.open(args[0], '_blank'); } catch (_) { /* no-op */ }
        return Promise.resolve(null);
      case 'resolveWordAudio':
      case 'playWordAudio':
      default:
        return Promise.resolve(null);
    }
  },
};

// TODO-1215: 词典媒体（gaiji / 声调 accent 的 SVG 等）在真实浏览器无 image:// scheme
// handler 会裂图。向 background 取当前 server 配置（base + token，源同 lookup/mine 的
// cfg()：hibiki-defaults.js 安装期注入的真值，或 options 手改覆盖），存进
// window.__hibikiDictMedia，供共享的 vendor/dict-media.js 里 rewriteDictionaryMediaPath
// 同步读取，改写成 GET /api/media/dictionary?dictionary=&path=&token= 直连（loopback，
// host_permissions 已含 localhost/127.0.0.1）。
(function loadHibikiDictMediaConfig() {
  function apply(resp) {
    if (resp && resp.ok && resp.base && resp.token) {
      window.__hibikiDictMedia = { base: resp.base, token: resp.token };
    }
  }
  function refresh() {
    try {
      chrome.runtime.sendMessage({ type: 'dictMediaConfig' }, apply);
    } catch (_) {
      // background 不可达：dict-media.js 回退 image://。
    }
  }
  refresh();
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area === 'local') refresh();
    });
  } catch (_) { /* no chrome.storage: skip */ }
})();
