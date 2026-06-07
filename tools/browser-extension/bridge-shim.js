// 垫掉 popup.js 里的 flutter_inappwebview.callHandler，转成扩展逻辑。
// 必须在 popup.js 之前加载（manifest content_scripts 顺序保证）。
window.flutter_inappwebview = {
  callHandler: function (name, ...args) {
    switch (name) {
      case 'popupRendered':
        if (window.__hibikiOnRendered) window.__hibikiOnRendered(args[0]);
        return Promise.resolve(null);
      case 'mineEntry':
        return new Promise((resolve) => {
          chrome.runtime.sendMessage(
            { type: 'mine', fields: args[0], sentence: (args[0] && args[0].popupSelectionText) || '' },
            (resp) => resolve(!!(resp && resp.ok && resp.data && resp.data.result === 'success')));
        });
      case 'duplicateCheck':
        return Promise.resolve(false);
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
