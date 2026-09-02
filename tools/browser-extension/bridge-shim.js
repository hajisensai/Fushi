// 垫掉 popup.js 里的 flutter_inappwebview.callHandler，转成扩展逻辑。
// 必须在 popup.js 之前加载（manifest content_scripts 顺序保证）。
window.flutter_inappwebview = {
  callHandler: function (name, ...args) {
    switch (name) {
      case 'popupRendered':
        if (window.__fushiOnRendered) window.__fushiOnRendered(args[0]);
        return Promise.resolve(null);
      case 'mineEntry':
        // 批量制卡：点「制卡」= 入队（瞬间，不录不裁不暂停）。末尾统一「生成全部」。
        // subtitle-adapters.js 同 content-script world 提供 Netflix 取词函数；缺失时回落选区文本。
        return new Promise((resolve) => {
          var toast = function (text, sticky) {
            if (typeof window.fushiToast === 'function') window.fushiToast(text, sticky);
          };
          var ctx = (typeof window.fushiMineContext === 'function')
            ? window.fushiMineContext() : null;
          // 例句三级优先：
          //   ① Netflix 字幕 DOM 直读——严格等于「此刻画面上那一行」，优先级最高且**保持原样**；
          //   ② 当前字幕行（`fushiMineContext`：整集拦截轨 / textTracks 收割 / 用户外挂字幕 /
          //      DOM 采样，站点无关）——此前这一级根本不存在，非 Netflix 的轨全被跳过；
          //   ③ 弹窗内选区文本（原兜底）。
          // ② 是这次补上的那一级：用户在 B 站挂了外挂字幕，轨就在 `fushiActiveFullTrack()` 里，
          // 面板和覆盖层都在用它，制卡却直接从 ① 掉到 ③ → 卡上没有句子。
          var cueText = (typeof extractNetflixCueText === 'function')
            ? extractNetflixCueText(netflixSubtitleContainer()) : '';
          var trackText = (ctx && ctx.window) ? (ctx.window.text || '') : '';
          var sentence = cueText || trackText
            || (args[0] && args[0].popupSelectionText) || '';
          // TODO-1271：判据是**能不能拿到可裁的原始媒体**，不是站点名（见 `fushiClipSource`）。
          // `mode:'queue'` = 必须先回放/逐条解析才拿得到媒体（Netflix 录制、YouTube 批量），
          // 只适合「看完一集统一生成」，保持既有行为不动。其余一切页面——普通网页、以及有字幕轨
          // 有视频但还没有流解析器的站点（bilibili.com 等）——都走下面的「立即出卡」，并带上
          // **当前解码帧**当封面。此前这条路只发 {fields,sentence} 纯文本，画面明明就在
          // `<video>` 里却一张图都不带。
          // 也不误报「没找到当前字幕」（那条只对入队路成立：批量生成必须有时间窗；立即出卡没有
          // 字幕也照样是一张合法的词卡，用户报过「这也不是视频，哪来的字幕」）。
          if (!(ctx && ctx.clip && ctx.clip.mode === 'queue')) {
            var msg = { type: 'mine', fields: args[0], sentence: sentence };
            // 当前解码帧（不是截屏，见 frame-capture.js 文件头）。DRM 页面取不到 → 不带图，
            // 照旧出纯文本卡，绝不改用截屏兜底。
            var frame = (typeof fushiCaptureCurrentFrame === 'function')
              ? fushiCaptureCurrentFrame() : null;
            if (frame && frame.base64) msg.screenshotBase64 = frame.base64;
            // 有当前字幕行 → 把时间窗一并带上：服务端据此从原始流裁句子音频/动图
            // （`immediate` 档的站点），没有流解析器时这些字段被忽略，不影响出卡。
            if (ctx && ctx.window) {
              msg.cueStartMs = ctx.window.startV;
              msg.clipStartMs = ctx.window.startV;
              msg.clipEndMs = ctx.window.endV;
              if (ctx.mineAtV !== null && ctx.mineAtV !== undefined) {
                msg.mineAtMs = ctx.mineAtV;
              }
            }
            if (ctx && ctx.clip && ctx.clip.mode === 'immediate') {
              msg.clipSourceKind = ctx.clip.kind;
              msg.clipSourceId = ctx.clip.id;
            }
            // 页面标题当 Anki 的「视频名」字段：此前这条路一个都不发，服务端只好回落硬编码的
            // 'Netflix'，B 站的卡上写着 Netflix。
            if (typeof document !== 'undefined' && document.title) {
              msg.documentTitle = document.title;
            }
            chrome.runtime.sendMessage(
              msg,
              (resp) => {
                try { if (chrome.runtime.lastError) { toast('✗ 制卡失败'); resolve(false); return; } } catch (_) { /* no-op */ }
                var dup = !!(resp && resp.ok && resp.data && resp.data.result === 'duplicate');
                var ok = !!(resp && resp.ok && resp.data && resp.data.result === 'success');
                if (dup) toast('✓ 该词卡片已存在');
                else if (ok) toast('✓ 已制卡');
                else toast('✗ 制卡失败');
                resolve(ok || dup);
              });
            return;
          }
          var res = (typeof window.fushiEnqueue === 'function')
            ? window.fushiEnqueue(args[0], sentence) : { ok: false, reason: 'no-queue' };
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
        if (window.__fushiOnLinkClick) window.__fushiOnLinkClick(args[0]);
        return Promise.resolve(null);
      case 'tapOutside':
        if (window.__fushiOnTapOutside) window.__fushiOnTapOutside();
        return Promise.resolve(null);
      case 'openLink':
        try { window.open(args[0], '_blank'); } catch (_) { /* no-op */ }
        return Promise.resolve(null);
      case 'resolveWordAudio':
        // 单词音频①解析：popup.js 点 ♪ → 传 {expression,reading}。经 background 向 server
        // POST /api/lookup/audio（Basic auth，与 lookup/mine 同链路），拿回可直接播放的
        // /api/lookup/audio/file?id= 短命 URL（不新协议，复用 sync server 既有音频端点）。
        // 命中返 URL 字符串，未命中/失败返 null → popup 显示 ✕（graceful，与 app 一致）。
        return (async function () {
          try {
            var a = args[0] || {};
            var resp = await chrome.runtime.sendMessage({
              type: 'lookupAudio',
              expression: a.expression || '',
              reading: a.reading || '',
            });
            return (resp && resp.ok && resp.url) ? resp.url : null;
          } catch (_) {
            return null;
          }
        })();
      // 单词音频播放已统一到 popup.js 自身（playWordAudio 直接 new Audio(url).play()），
      // 三端同一路径，不再经 callHandler('playWordAudio')。故此处旧的 playWordAudio 桥
      // 已删除。resolveWordAudio 仍返回可直接播放的 URL（扩展侧是 sync server 的
      // /api/lookup/audio/file 短命 URL），popup.js 拿到后本地播放。
      default:
        return Promise.resolve(null);
    }
  },
};

// TODO-1215: 词典媒体（gaiji / 声调 accent 的 SVG 等）在真实浏览器无 image:// scheme
// handler 会裂图。向 background 取当前 server 配置（base + token，源同 lookup/mine 的
// cfg()：fushi-defaults.js 安装期注入的真值，或 options 手改覆盖），存进
// window.__fushiDictMedia，供共享的 vendor/dict-media.js 里 rewriteDictionaryMediaPath
// 同步读取，改写成 GET /api/media/dictionary?dictionary=&path=&token= 直连（loopback，
// host_permissions 已含 localhost/127.0.0.1）。
(function loadFushiDictMediaConfig() {
  function apply(resp) {
    if (resp && resp.ok && resp.base && resp.token) {
      window.__fushiDictMedia = { base: resp.base, token: resp.token };
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
