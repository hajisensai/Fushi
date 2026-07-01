// 垫掉 popup.js 里的 flutter_inappwebview.callHandler，转成扩展逻辑。
// 必须在 popup.js 之前加载（manifest content_scripts 顺序保证）。
window.flutter_inappwebview = {
  callHandler: function (name, ...args) {
    switch (name) {
      case 'popupRendered':
        if (window.__hibikiOnRendered) window.__hibikiOnRendered(args[0]);
        return Promise.resolve(null);
      case 'mineEntry':
        // TODO-1000：流媒体（Netflix）挖词时附当前字幕整句 + video 时间戳 + videoId，
        // 供 Hibiki 截图/GIF/音频制卡。subtitle-adapters.js 同 content-script world 提供函数；
        // 非流媒体页面（函数缺失）优雅回落到原纯文本挖词，不破坏现有行为。
        return new Promise((resolve) => {
          var v = (typeof netflixVideoEl === 'function') ? netflixVideoEl() : null;
          var cueText = (typeof extractNetflixCueText === 'function')
            ? extractNetflixCueText(netflixSubtitleContainer()) : '';
          chrome.runtime.sendMessage(
            {
              type: 'mine',
              fields: args[0],
              sentence: cueText || (args[0] && args[0].popupSelectionText) || '',
              timestampMs: (typeof currentVideoTimeMs === 'function') ? currentVideoTimeMs(v) : null,
              netflixVideoId: (typeof netflixVideoIdFromPath === 'function')
                ? netflixVideoIdFromPath(location.pathname) : null,
            },
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
