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
          if (res && res.ok) toast('✓ 已加入制卡队列（' + res.count + '）\n看完后一次生成全部');
          else if (res && res.reason === 'no-cue') toast('✗ 没找到当前字幕，稍候再试');
          else toast('✗ 入队失败');
          resolve(!!(res && res.ok));
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
