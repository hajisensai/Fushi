(function () {
  'use strict';

  var listEl = document.getElementById('list');
  var trackEl = document.getElementById('track');
  var offsetEl = document.getElementById('offset');
  var offsetValueEl = document.getElementById('offset-value');
  var statusEl = document.getElementById('video-status');
  var fileEl = document.getElementById('subtitle-file');
  var autoButton = document.getElementById('auto-scroll');
  var toastEl = document.getElementById('toast');
  var lookupPaneEl = document.getElementById('lookup-pane');
  // 与宿主页 Shift 查词使用同一种 Shadow DOM host 结构；Side Panel 进一步让它在面板
  // 生命周期内常驻，提前完成 stylesheet/renderer 初始化，首次查词只替换数据。
  var lookupShadow = lookupPaneEl.attachShadow({ mode: 'open' });
  var lookupStyles = document.createElement('link');
  lookupStyles.rel = 'stylesheet';
  lookupStyles.href = chrome.runtime.getURL('vendor/content.css');
  var lookupOverrides = document.createElement('style');
  lookupOverrides.textContent =
    '#entries-container{width:100%!important;max-width:none!important;max-height:none!important;' +
    'overflow:visible!important;zoom:1!important;}';
  var lookupContainer = document.createElement('div');
  lookupContainer.id = 'entries-container';
  lookupShadow.appendChild(lookupStyles);
  lookupShadow.appendChild(lookupOverrides);
  lookupShadow.appendChild(lookupContainer);
  window.__fushiRoot = lookupShadow;
  installDictMediaPlaceholderResolver(lookupShadow); // BUG-1718：兑现词条内图片/样式表占位
  var currentTabId = null;
  // 抽屉嵌入模式（mobile-drawer.js 的 iframe 打开，?fushiEmbed=1）：
  //   · 绑定来源页 tabId——网页内扩展 iframe 里 tabs.query 的 currentWindow 解析不可靠，
  //     以 background drawerSelfTab 如实回报的 sender.tab.id 为准（缺参数仍走 queryActiveTab）；
  //   · 不挂 tabs.onActivated：抽屉只服务这一页，「跟着切的标签页走」语义在这里不存在；
  //   · 抽屉收起时宿主 postMessage pause → 暂停 300ms 轮询（省电），拉开立刻补一次；
  //   · html 根挂 .fushi-embed 类，side-panel.css 按触屏规格放大控件、补安全区。
  // typeof 守卫：vm 行为测试沙箱里没有全局 location，扩展页里永远有——两不耽误。
  var EMBED_SEARCH = typeof location === 'undefined' ? '' : String(location.search || '');
  // BUG-2426：「这份文档是不是被嵌进了别人的页面」是浏览器的客观事实，不能由
  // URL 参数声明。旧判据只看 `?fushiEmbed=1`，于是 #1295 那一整套「宿主 origin 与
  // 目标 tabId 一律不许自证」的加固，被恶意站点**省略这个参数**就能整个绕过：
  // EMBED=false ⇒ queryActiveTab() 落回 chrome.tabs.query({active,currentWindow})，
  // 把用户此刻真正在看的标签页交给嵌入方当靶子（跨源读不到内容，但足够点击劫持
  // 借用户的手去跳转/制卡）。判据改成帧嵌套这一浏览器事实；同源比较不会抛，真抛了
  // 也按「被嵌入」fail-closed。URL 参数保留只为兼容合法抽屉路径，不再是唯一来源。
  var EMBED = (function () {
    try {
      // 真浏览器里 window.top 恒存在：顶层页 top === self，被嵌入则不等（跨源时它是
      // 一个不可读的 Window 代理，但引用比较照样成立）。`window.top &&` 只为挡住
      // 行为测试沙箱里没有 top 的情形，浏览器里永远走不到那条回退。
      if (typeof window !== 'undefined' && window.top && window.top !== window.self) {
        return true;
      }
    } catch (_) {
      return true; // 连比较都被拒 = 必然嵌在别人的页面里，fail-closed
    }
    return /[?&]fushiEmbed=1/.test(EMBED_SEARCH);
  })();
  // 目标标签 id 不从 URL 取：?fushiTabId= 是自证参数，嵌入方填谁的号都行。
  // 改由 SW 在 drawerEmbedVerify 应答里按 sender.tab.id 背书（见文件末尾 EMBED 块），
  // 背书到货前保持 null —— 那期间 queryActiveTab 一律给空，fail-closed。
  var EMBED_TAB_ID = null;
  var embedPaused = false;
  if (EMBED) document.documentElement.classList.add('fushi-embed');
  // 嵌入（手机抽屉）模式头部原本叠了标题+工具排+选轨+时轴偏移三四行，把列表挤得没法看。
  // 加一个折叠钮：折叠后只留工具排（＋J A− A＋ AS ⚙），列表近乎占满；再点恢复。
  if (EMBED) {
    var foldTitleRow = document.querySelector('.title-row');
    if (foldTitleRow) {
      var foldBtn = document.createElement('button');
      foldBtn.type = 'button';
      foldBtn.className = 'hdr-fold';
      foldBtn.textContent = '▾';
      foldBtn.title = '折叠/展开工具区';
      foldBtn.setAttribute('aria-label', '折叠或展开头部工具区');
      var applyFold = function (folded) {
        document.body.classList.toggle('hdr-folded', folded);
        foldBtn.textContent = folded ? '▸' : '▾';
      };
      foldBtn.addEventListener('click', function () {
        var folded = !document.body.classList.contains('hdr-folded');
        applyFold(folded);
        // 折叠状态跨会话记忆：抽屉每次重开都摊着四行工具区是反体验。此键只有 embed
        // 读写（desktop 无此守卫、CSS 全挂 html.fushi-embed），不污染侧板。
        try { localStorage.setItem('fushiHdrFolded', folded ? '1' : '0'); } catch (_) {}
      });
      // 新会话默认折叠（尽量省空间）：只有用户显式展开过（存 '0'）才记住展开；
      // 无存档=首次，直接收成一行工具排。
      var savedFold = null;
      try { savedFold = localStorage.getItem('fushiHdrFolded'); } catch (_) {}
      if (savedFold !== '0') applyFold(true);
      foldTitleRow.insertBefore(foldBtn, foldTitleRow.firstChild);
    }
  }
  var currentState = null;
  var cues = [];
  var rows = [];
  var currentIndex = -1;
  var scrollIndex = -1;
  var stateSignature = '';
  var autoScroll = true;
  var fontStep = 1;
  var refreshBusy = false;
  var toastTimer = null;
  var currentLookupCue = null;
  var currentLookupAnchor = null;
  var lookupRequestId = 0;
  var lookupPerfSequence = 0;
  var currentLookupPerfContext = null;
  var lookupCache = new Map();
  var lookupCacheChars = 0;
  var lookupInFlight = new Map();
  var lookupBaseMaxHeight = '360px';
  var lastPointer = null;
  var scheduledPointer = null;
  var scanFrame = null;
  var activeScanKey = '';
  // pointer 扫词在途闸（对齐 content.js 的 fushiPending/fushiPendingSince，BUG-1024 同款防洪）：
  // 有词典请求在途时暂缓 pointermove 触发的新查词——横扫一行 20 个字不再瞬间打出 20 个请求把
  // 本地服务与 6 连接上限灌满。0=无在途；带截止时间兜底，任何异常都不会永久闸死。
  var lookupPendingSince = 0;
  var LOOKUP_PENDING_TIMEOUT_MS = 1500;
  // 用户拖过查词面板尺寸（CSS resize 把手）后置 true：本会话内主题下发/落点重算不再覆盖
  // 用户宽高；拖拽结果经 popupSize 回写 app（与页面弹窗同一把「拖即解锁」尺寸键）。
  var lookupUserResized = false;
  var lookupResizeSnapshot = null;
  // 「查词结果显示在网页上」。Chrome side panel 是浏览器自己的一份 web contents，面板内的
  // 弹窗永远只能有面板那么宽——DOM 画不出面板边界，这是浏览器边界不是落点逻辑。开启后侧栏
  // 点词把词交给宿主页，用页面弹窗渲染（详见 content.js 的 fushiShowLookupFromSidePanel）；
  // 关掉、或宿主页没有内容脚本时，回落到面板内渲染（下面 lookupTerm 的两条路径）。
  var lookupOnPage = true;
  // 侧栏交出去的那轮页面弹窗是否还开着。用于扫词去重：弹窗还在就别对同一个字重复发请求，
  // 弹窗没了（页面点空白/Esc/手动播放，content.js 回 fushiSidePanelLookupGone）就得放行。
  var pageLookupOpen = false;
  try {
    chrome.storage.local.get('subtitleLookupOnPage', function (saved) {
      try { if (chrome.runtime.lastError) return; } catch (_) { return; }
      if (saved && typeof saved.subtitleLookupOnPage === 'boolean') {
        lookupOnPage = saved.subtitleLookupOnPage;
      }
    });
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes || !changes.subtitleLookupOnPage) return;
      var next = changes.subtitleLookupOnPage.newValue;
      lookupOnPage = typeof next === 'boolean' ? next : true;
      // 切换即收拾另一侧的残留：切到页面渲染时关面板内弹窗，切回面板时关页面上那份。
      if (lookupOnPage) closeLookup();
      else closePageLookup();
    });
  } catch (_) { /* storage 不可用：按默认（页面渲染）走 */ }
  // 复杂词的 popupJson 可超过 2 MB，解析后的对象树通常还会膨胀数倍。只按“48 个词”
  // 淘汰会让 Side Panel 很快常驻数百 MB，并在后续查词时触发秒级 GC。双门槛保留常用
  // 小词，同时让超大结果最多只占少量槽位；最新一条即使单独超预算也保留以支持复查。
  var LOOKUP_CACHE_LIMIT = 12;
  var LOOKUP_CACHE_CHAR_LIMIT = 8 * 1024 * 1024;
  var FONT_STEPS = [0.85, 1, 1.15, 1.3];

  // BUG-1024 孪生（Side Panel 版）：MV3 service worker 在消息在途时被系统回收，sendMessage
  // 回调**永不触发**——没有兜底的话这里的 Promise 永久 pending：「正在查词…」永久停留，且
  // fetchLookup 的同词在途复用（BUG-1525）会把这个死 Promise 缓存起来，同一个词从此永久卡死。
  // 超时竞速保证 Promise 一定 settle（值取 > app 冷查询 P99；超时按失败处理，UI 显示可重试的
  // 失败文案而不是无限转圈）。
  var RUNTIME_MESSAGE_TIMEOUT_MS = 8000;
  function sendRuntime(message) {
    return new Promise(function (resolve) {
      var settled = false;
      var timer = null;
      var finish = function (value) {
        if (settled) return;
        settled = true;
        if (timer !== null) clearTimeout(timer);
        resolve(value);
      };
      timer = setTimeout(function () { finish(null); }, RUNTIME_MESSAGE_TIMEOUT_MS);
      try {
        chrome.runtime.sendMessage(message, function (response) {
          try { if (chrome.runtime.lastError) return finish(null); } catch (_) { return finish(null); }
          finish(response || null);
        });
      } catch (_) { finish(null); }
    });
  }

  function reportLookupPerf(entry) {
    try {
      chrome.runtime.sendMessage({ type: 'lookupPerf', entry: entry }, function () {
        try { void chrome.runtime.lastError; } catch (_) {}
      });
    } catch (_) { /* 扩展重载/关闭时静默 */ }
  }

  function bindPopupPerfContext(ctx) {
    // popup.js 会捕获这一个函数再异步上报；闭包固定本轮 ctx，换词/关窗后
    // cancelled/error 也不会串到下一次 lookup id。
    window.__fushiOnPopupPerf = function (metrics) {
      if (!ctx) return;
      reportLookupPerf({
        id: ctx.id,
        surface: 'side-panel',
        stage: 'popup-' + String(metrics && metrics.phase || 'unknown'),
        term: ctx.term,
        maximumTerms: ctx.maximumTerms,
        cacheHit: ctx.cacheHit === true,
        sinceRequestMs: Number((performance.now() - ctx.clientStartedAt).toFixed(1)),
        ...(metrics || {}),
      });
    };
  }
  bindPopupPerfContext(null);

  function reportLookupVisibleAfterPaint(ctx) {
    if (!ctx || ctx.visibleReported || ctx.visibleReportScheduled) return;
    ctx.visibleReportScheduled = true;
    // 调用点在设置 visibility 的 rAF 内；再等一帧意味着浏览器至少有一次 paint
    // 机会，区别于 popup.js 的“首卡 DOM 已构建”。
    requestAnimationFrame(function () {
      if (lookupPaneEl.hidden || lookupPaneEl.style.visibility !== 'visible') return;
      ctx.visibleReported = true;
      reportLookupPerf({
        id: ctx.id,
        surface: 'side-panel',
        stage: 'visible-after-paint',
        term: ctx.term,
        maximumTerms: ctx.maximumTerms,
        cacheHit: ctx.cacheHit === true,
        sinceRequestMs: Number((performance.now() - ctx.clientStartedAt).toFixed(1)),
      });
    });
  }

  // 只收起面板内那份弹窗：推进请求代际让在途查词的渲染失效，清空内容。**不动 activeScanKey**
  // ——那是扫词去重键，只在「这一轮查词真的没了」时才该复位（closeLookup / 页面弹窗关窗回执）。
  function hideLookupPane() {
    // 收窗即作废在途的自动朗读（弹窗没了不该再响）。
    if (typeof window.fushiCancelAutoRead === 'function') window.fushiCancelAutoRead();
    lookupRequestId += 1;
    if (Number.isInteger(window._renderGeneration)) window._renderGeneration += 1;
    window._renderInProgress = false;
    lookupPaneEl.hidden = true;
    lookupPaneEl.style.visibility = 'hidden';
    lookupContainer.textContent = '';
    currentLookupAnchor = null;
    currentLookupPerfContext = null;
  }

  // 关掉页面上那份（侧栏交出去的）弹窗。面板内那份由 closeLookup 管，两者互不代管。
  function closePageLookup() {
    if (!pageLookupOpen) return;
    pageLookupOpen = false;
    activeScanKey = '';
    sendToTab({ type: 'fushiSubtitleSidePanelCloseLookup' });
  }

  function closeLookup() {
    var wasOpen = !lookupPaneEl.hidden;
    hideLookupPane();
    currentLookupCue = null;
    activeScanKey = '';
    // 面板真关掉时通知视频页：由查词暂停的视频该恢复了（content 侧只恢复「确实是查词
    // 暂停的」，用户自己暂停的不动）。「手动播放→content 反向 dismiss→这里 close」的
    // 环路安全：那时暂停标记已被 play 监听清掉，恢复是 no-op。
    if (wasOpen) sendToTab({ type: 'fushiSubtitleSidePanelLookupClosed' });
  }

  function positionLookup(anchor) {
    if (anchor) currentLookupAnchor = anchor;
    anchor = currentLookupAnchor;
    if (!anchor || lookupPaneEl.hidden) return;
    var requestId = lookupRequestId;
    var firstPlacement = lookupPaneEl.style.visibility !== 'visible';
    if (firstPlacement) {
      lookupPaneEl.style.visibility = 'hidden';
      lookupPaneEl.style.left = '0px';
      lookupPaneEl.style.top = '0px';
    }
    // lookupBaseMaxHeight 已由 applyLookupBox 按「视口 80% ÷ zoom」折算成基准尺度 px，
    // 这里不能再套一层 `min(..., 80vh)`：vh 不随 zoom 缩放，zoom>1 时那个上限会被放大到
    // 视口之外，等于没夹（正是弹窗纵向超出侧边栏的原因）。
    if (!lookupUserResized) lookupPaneEl.style.maxHeight = lookupBaseMaxHeight;
    requestAnimationFrame(function () {
      if (requestId !== lookupRequestId || lookupPaneEl.hidden) return;
      var gap = 4;
      var margin = 8;
      var zoom = parseFloat(lookupPaneEl.style.zoom) || 1;
      var rect = lookupPaneEl.getBoundingClientRect();
      var below = Math.max(0, window.innerHeight - anchor.bottom - margin);
      var above = Math.max(0, anchor.top - margin);
      var top;
      var maxHeight = null;
      if (rect.height + gap <= below) {
        top = anchor.bottom + gap;
      } else if (rect.height + gap <= above) {
        top = anchor.top - gap - rect.height;
      } else if (below >= above) {
        top = anchor.bottom + gap;
        maxHeight = Math.max(64, below - gap);
      } else {
        maxHeight = Math.max(64, above - gap);
        top = Math.max(margin, anchor.top - gap - maxHeight);
      }
      if (maxHeight !== null) {
        lookupPaneEl.style.maxHeight = (maxHeight / zoom) + 'px';
        rect = lookupPaneEl.getBoundingClientRect();
      }
      var left = Math.max(margin, Math.min(anchor.left,
        window.innerWidth - rect.width - margin));
      top = Math.max(margin, Math.min(top, window.innerHeight - rect.height - margin));
      lookupPaneEl.style.left = (left / zoom) + 'px';
      lookupPaneEl.style.top = (top / zoom) + 'px';
      lookupPaneEl.style.visibility = 'visible';
      reportLookupVisibleAfterPaint(currentLookupPerfContext);
    });
  }

  function applyLookupTheme(theme) {
    if (!theme || typeof theme !== 'object') return;
    Object.keys(theme).forEach(function (key) {
      if (typeof theme[key] === 'string') lookupContainer.style.setProperty(key, theme[key]);
    });
    var scheme = theme['--fushi-color-scheme'];
    if (scheme === 'dark' || scheme === 'light') lookupContainer.setAttribute('data-theme', scheme);
    var columns = theme['--dict-columns'];
    if (typeof columns === 'string' && columns) {
      document.documentElement.style.setProperty('--dict-columns', columns);
    }
    var wheelSpeed = parseFloat(theme['--fushi-wheel-speed']);
    window.__fushiPopupWheelSpeed = isFinite(wheelSpeed) && wheelSpeed > 0 ? wheelSpeed : 1;
    // BUG-2284：墨水屏「瞬时滚动」随主题下发（app popupInstantScroll），popup.js 的 wheel
    // 监听读同名全局改走固定步长瞬跳。缺该 key = 旧 app，保持关闭。
    window.__fushiPopupInstantScroll = theme['--fushi-instant-scroll'] === '1';
    // 用户拖过尺寸（lookupUserResized）后，本会话内不再让主题下发的宽高盖掉用户的选择；
    // 拖拽结果经 popupSize 回写 app，下次会话由主题带回来。
    lookupThemeForBox = theme;
    applyLookupBox();
  }

  // 侧边栏弹窗的尺寸盒。与页面弹窗（content.js fushiApplyTheme）同一个决策器，额外把
  // **本文档视口**交给它做夹取——侧边栏可以窄到 300px，而主题宽度是按 app 窗口定的
  // （400~600px），且这些 px 长度写在 CSS `zoom` 之下：zoom=1.4 时 400px 渲染成 560px，
  // 连 `max-width: calc(100vw - 16px)` 这个上限本身也一起被 zoom 放大，根本拦不住 →
  // 弹窗横向溢出，被 `.lookup-pane{overflow-x:hidden}` 硬切掉右半边（用户看到「查词框被切了」）。
  // fushiResolvePopupBox 把上限折回基准尺度；压到最窄可读宽度仍放不下时改压 zoom，
  // 让整窗等比缩小而不是切内容。
  var lookupThemeForBox = null;
  function applyLookupBox() {
    var box = fushiResolvePopupBox(
      lookupThemeForBox, { width: window.innerWidth, height: window.innerHeight });
    // 「用户手动拖过尺寸」只锁**宽高两项**——那才是拖把手拖出来的东西，本会话内不再
    // 被主题下发的值盖掉（拖拽结果经 popupSize 回写 app，下次会话由主题带回来）。
    // zoom 不在此列：它由 app 的「词典字号」下发（--fushi-popup-zoom =
    // dictionaryFontSize/16），拖把手根本改不到它。整个函数早退会让用户拖过一次之后，
    // 本会话内再去 app 里改字号，侧边栏弹窗的缩放永远不跟——这是行为回归。
    if (!lookupUserResized) {
      lookupPaneEl.style.width = box.width + 'px';
      lookupBaseMaxHeight = box.maxHeight + 'px';
      lookupPaneEl.style.maxHeight = lookupBaseMaxHeight;
    }
    lookupPaneEl.style.maxWidth = 'calc(100vw - 16px)';
    lookupPaneEl.style.zoom = String(box.zoom);
  }

  function renderLookupData(value, data, cacheHit) {
    var basePerf = data && data.perf || {};
    currentLookupPerfContext = {
      id: cacheHit
        ? 'side-cache-' + Date.now().toString(36) + '-' + (++lookupPerfSequence).toString(36)
        : (basePerf.id || 'side-' + Date.now().toString(36) + '-' + (++lookupPerfSequence).toString(36)),
      term: value,
      maximumTerms: basePerf.maximumTerms || 10,
      clientStartedAt: cacheHit ? performance.now() : (basePerf.clientStartedAt || performance.now()),
      cacheHit: cacheHit === true,
      visibleReported: false,
      visibleReportScheduled: false,
    };
    bindPopupPerfContext(currentLookupPerfContext);
    if (cacheHit) {
      reportLookupPerf({
        id: currentLookupPerfContext.id,
        surface: 'side-panel',
        stage: 'cache-hit',
        term: value,
        maximumTerms: currentLookupPerfContext.maximumTerms,
      });
    }
    window.lookupEntries = Array.isArray(data.entries) ? data.entries : [];
    window.audioSources = Array.isArray(data.audioSources) ? data.audioSources : [];
    window.needsAudio = true;
    window._noResultsMessage = '没有查到结果';
    applyLookupTheme(data.theme);
    // 花括号是必需的：BUG-1942 的自动朗读块插进来之后，这个 else 曾经绑到了下面那个
    // `if (typeof window.fushiAutoReadFirstEntry === 'function')` 上 —— 于是词典组件
    // 真没就绪时不再显示提示（一片空白），而 auto-read.js 没加载时反倒会把已经渲染好
    // 的弹窗内容覆盖成「词典组件尚未就绪」。
    if (typeof window.renderPopup === 'function') {
      window.renderPopup();
    } else {
      lookupContainer.innerHTML = '<div class="no-results">词典组件尚未就绪，请重试。</div>';
    }
    // 查词后自动朗读：与页面弹窗共用 auto-read.js 那一份（开关同为 app 全局偏好）。
    if (typeof window.fushiAutoReadFirstEntry === 'function') {
      window.fushiAutoReadFirstEntry(window.lookupEntries, {
        enabled: data.autoReadOnLookup === true,
        audioSources: window.audioSources,
      });
    }
    if (lookupPaneEl.style.visibility === 'visible' &&
        currentLookupPerfContext && !currentLookupPerfContext.visibleReported) {
      reportLookupVisibleAfterPaint(currentLookupPerfContext);
    }
  }

  function rememberLookup(value, data) {
    var previous = lookupCache.get(value);
    if (previous) {
      lookupCacheChars -= Number(previous.estimatedChars) || 0;
      lookupCache.delete(value);
    }
    lookupCacheChars += Number(data && data.estimatedChars) || 0;
    lookupCache.set(value, data);
    while ((lookupCache.size > LOOKUP_CACHE_LIMIT ||
            lookupCacheChars > LOOKUP_CACHE_CHAR_LIMIT) && lookupCache.size > 1) {
      var oldestKey = lookupCache.keys().next().value;
      var oldest = lookupCache.get(oldestKey);
      lookupCacheChars -= Number(oldest && oldest.estimatedChars) || 0;
      lookupCache.delete(oldestKey);
    }
    lookupCacheChars = Math.max(0, lookupCacheChars);
  }

  function cachedLookup(value) {
    var cached = lookupCache.get(value);
    if (!cached) return null;
    lookupCache.delete(value);
    lookupCache.set(value, cached);
    return cached;
  }

  function fetchLookup(value) {
    var cached = cachedLookup(value);
    if (cached) return Promise.resolve(cached);
    if (lookupInFlight.has(value)) return lookupInFlight.get(value);
    var clientStartedAt = performance.now();
    var clientSentEpochMs = performance.timeOrigin + clientStartedAt;
    var request = sendRuntime({
      type: 'lookup', term: value, clientSentEpochMs: clientSentEpochMs,
    }).then(function (response) {
      var responseAt = performance.now();
      var responseEpochMs = performance.timeOrigin + responseAt;
      if (!response || response.ok !== true || !response.data ||
          typeof response.data.popupJson !== 'string') {
        var failedPerf = response && response.lookupPerf || {};
        reportLookupPerf({
          id: failedPerf.id || 'side-error-' + Date.now().toString(36) + '-' + (++lookupPerfSequence).toString(36),
          surface: 'side-panel',
          stage: 'client-error',
          term: value,
          maximumTerms: failedPerf.maximumTerms || 10,
          messageRoundTripMs: Number((responseAt - clientStartedAt).toFixed(1)),
          ...(typeof failedPerf.responseReadyEpochMs === 'number' ? {
            deliveryAfterReadyMs: Number(
              Math.max(0, responseEpochMs - failedPerf.responseReadyEpochMs).toFixed(1)),
          } : {}),
          error: String(response && response.error || 'empty lookup response'),
        });
        return null;
      }
      var data = response.data;
      // BUG-1718：词典自带 CSS + 用户自定义 CSS 是全局（非按词）的，随每次真实响应刷新即可，
      // 不进 prepared 缓存（缓存 48 个词，没必要每条都挂一份数百 KB 的引用）。
      applyFushiPopupCss(data);
      var prepared = {
        audioSources: data.audioSources,
        autoReadOnLookup: data.autoReadOnLookup === true,
        theme: data.theme,
        entries: [],
        estimatedChars: data.popupJson.length,
      };
      var servicePerf = response.lookupPerf || {};
      var parseStartedAt = performance.now();
      var parseError = null;
      try { prepared.entries = JSON.parse(data.popupJson); }
      catch (error) {
        prepared.entries = [];
        parseError = String(error && error.message || error);
      }
      var parseFinishedAt = performance.now();
      if (parseError) {
        reportLookupPerf({
          id: servicePerf.id || 'side-parse-' + Date.now().toString(36) + '-' + (++lookupPerfSequence).toString(36),
          surface: 'side-panel',
          stage: 'client-error',
          term: value,
          maximumTerms: servicePerf.maximumTerms || 10,
          innerJsonParseMs: Number((parseFinishedAt - parseStartedAt).toFixed(1)),
          error: 'inner JSON parse: ' + parseError,
        });
        return null;
      }
      prepared.perf = {
        id: servicePerf.id || 'side-' + Date.now().toString(36) + '-' + (++lookupPerfSequence).toString(36),
        maximumTerms: servicePerf.maximumTerms || 10,
        clientStartedAt: clientStartedAt,
      };
      reportLookupPerf({
        id: prepared.perf.id,
        surface: 'side-panel',
        stage: 'client-response',
        term: value,
        maximumTerms: prepared.perf.maximumTerms,
        messageRoundTripMs: Number((responseAt - clientStartedAt).toFixed(1)),
        ...(typeof servicePerf.responseReadyEpochMs === 'number' ? {
          deliveryAfterReadyMs: Number(
            Math.max(0, responseEpochMs - servicePerf.responseReadyEpochMs).toFixed(1)),
        } : {}),
        innerJsonParseMs: Number((parseFinishedAt - parseStartedAt).toFixed(1)),
        parsedEntryCount: prepared.entries.length,
        responseChars: servicePerf.responseChars || data.popupJson.length,
      });
      rememberLookup(value, prepared);
      return prepared;
    }).finally(function () {
      lookupInFlight.delete(value);
    });
    lookupInFlight.set(value, request);
    return request;
  }

  async function lookupTerm(term, cue, anchor) {
    var value = String(term || '').trim();
    if (!value) return;
    var shouldPosition = !!anchor;
    if (lookupOnPage) {
      // 「跨出面板」路径：只负责把词递给宿主页，查词请求、暂停/恢复、嵌套查词、发音、查重、
      // 制卡全部在页面侧走既有链路（与 Shift 划词同源）。
      if (!lookupPaneEl.hidden) hideLookupPane(); // 刚从「面板内」切过来的残留
      currentLookupCue = cue || currentLookupCue;
      var shown = await sendToTab({
        type: 'fushiSubtitleSidePanelShowLookup', term: value, cue: currentLookupCue,
        // 侧栏与宿主页是两个视口，绝对坐标没有意义；交纵向比例，页面按自己的视口还原，
        // 弹窗就落在被点那一行的高度上（贴右缘=紧邻侧栏），不再固定糊在右上角挡内容。
        anchorRatio: lookupAnchorRatio(anchor),
      });
      if (shown && shown.ok === true) {
        pageLookupOpen = true;
        return;
      }
      // 宿主页不可达（无内容脚本的页面、标签已关或正在跳转）：绝不能变成查不了词——
      // 落回下面的面板内渲染。
      pageLookupOpen = false;
    }
    var requestId = ++lookupRequestId;
    currentLookupCue = cue || currentLookupCue;
    lookupPaneEl.hidden = false;
    // 与 Yomitan 的主动修饰键扫描一致：host 已驻留，Shift 按下立即走查询；cue 准备与
    // 词典请求并行，同词的在途请求和已解析结果都复用，避免重复 IPC、JSON.parse 与 DOM 构建。
    sendToTab({ type: 'fushiSubtitleSidePanelPrepareLookup', cue: currentLookupCue });
    var cached = cachedLookup(value);
    if (cached) {
      renderLookupData(value, cached, true);
      if (shouldPosition) positionLookup(anchor);
      return;
    }
    lookupContainer.innerHTML = '<div class="no-results">正在查词…</div>';
    if (shouldPosition) positionLookup(anchor);
    // try/finally 锁死两条不变式：①「正在查词…」绝不永久停留——fetchLookup 无论 resolve /
    // reject（内部处理回调抛错）都必须落到成功或失败文案；② pointer 扫词在途闸一定被复位。
    var data = null;
    try {
      lookupPendingSince = Date.now();
      data = await fetchLookup(value);
    } catch (_) {
      data = null;
    } finally {
      lookupPendingSince = 0;
    }
    if (requestId !== lookupRequestId) return;
    if (!data) {
      lookupContainer.innerHTML = '<div class="no-results">查词失败，请确认 Fushi 查词服务已开启。</div>';
      if (shouldPosition) positionLookup(anchor);
      // 失败后复位扫描去重键：不复位的话鼠标停在同一个字上永远触发不了重试。
      activeScanKey = '';
      return;
    }
    renderLookupData(value, data, false);
    if (shouldPosition) positionLookup(anchor);
  }

  // 被点词在侧栏视口里的纵向比例（0=顶、1=底）。没有锚点（嵌套查词等）时沿用上一次的位置。
  var lastAnchorRatio = 0.15;
  function lookupAnchorRatio(anchor) {
    var height = window.innerHeight || 0;
    if (anchor && height > 0 && typeof anchor.top === 'number') {
      var ratio = anchor.top / height;
      lastAnchorRatio = Math.min(1, Math.max(0, ratio));
    }
    return lastAnchorRatio;
  }

  function anchorForHit(hit, x, y) {
    try {
      var node = hit && hit.node;
      var offset = hit && hit.offset;
      var content = node && node.textContent || '';
      if (!node || !Number.isInteger(offset) || offset < 0 || offset >= content.length) throw new Error();
      var codePoint = content.codePointAt(offset);
      var end = Math.min(content.length, offset + (codePoint > 0xFFFF ? 2 : 1));
      var range = document.createRange();
      range.setStart(node, offset);
      range.setEnd(node, end);
      var rect = range.getBoundingClientRect();
      if (rect && rect.height > 0) {
        return {
          left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
          width: rect.width, height: rect.height,
        };
      }
    } catch (_) {}
    return { left: x, top: y, right: x + 1, bottom: y + 1, width: 1, height: 1 };
  }

  // explicit：用户显式手势（点击 / 按下 Shift），永远放行在途闸；announceMissing：取不到词时
  // 是否提示。两者曾是同一个参数，于是「点击」被迫既放行在途闸又必须弹 toast——而点行内空白
  // 本就取不到词，那条 toast 挡住的正是用户想要的跳转。返回 true 表示这一击真的发起了查词。
  function lookupAtPointer(pointer, options) {
    var explicit = !!(options && options.explicit);
    var announceMissing = !!(options && options.announceMissing);
    if (!pointer || !pointer.textEl || !pointer.textEl.isConnected) return false;
    var hovered = document.elementFromPoint(pointer.x, pointer.y);
    if (!hovered || (hovered !== pointer.textEl && !pointer.textEl.contains(hovered))) return false;
    var term = '';
    var hit = null;
    try {
      hit = window.fushiSelection && window.fushiSelection.getCharacterAtPoint
        ? window.fushiSelection.getCharacterAtPoint(pointer.x, pointer.y) : null;
      if (hit && window.fushiSelection.selectFromPosition) {
        term = window.fushiSelection.selectFromPosition(
          hit.node, hit.offset, 12, pointer.x, pointer.y,
        );
      }
    } catch (_) { term = ''; }
    if (!term) {
      if (announceMissing) toast('未识别到可查词文字');
      return false;
    }
    var scanKey = pointer.index + '\u0000' + term;
    if (scanKey === activeScanKey && (pageLookupOpen || !lookupPaneEl.hidden)) return true;
    // 在途闸只拦 pointermove 自动扫词；显式手势（点击 / Shift）永远放行。
    // 超过截止时间的在途视为已死（SW 被回收等），放行新查词——死锁不可复活。
    if (!explicit && lookupPendingSince &&
        Date.now() - lookupPendingSince < LOOKUP_PENDING_TIMEOUT_MS) {
      return false;
    }
    activeScanKey = scanKey;
    lookupTerm(term, pointer.cue, anchorForHit(hit, pointer.x, pointer.y));
    return true;
  }

  function schedulePointerLookup(pointer) {
    scheduledPointer = pointer;
    if (scanFrame !== null) return;
    scanFrame = requestAnimationFrame(function () {
      scanFrame = null;
      var next = scheduledPointer;
      scheduledPointer = null;
      lookupAtPointer(next, {}); // pointermove 自动扫词：受在途闸约束、不提示
    });
  }

  // popup.js 与 app 内 WebView 共用。Side Panel 自己承接嵌套查词、发音与查重；只有制卡
  // 需要把字段和精确字幕时间窗发给当前视频页，词典 UI 从不回到宿主网页。
  window.flutter_inappwebview = {
    callHandler: function (name) {
      var args = Array.prototype.slice.call(arguments, 1);
      if (name === 'textSelected' || name === 'popupRendered') return Promise.resolve(null);
      if (name === 'onLinkClick') {
        lookupTerm(args[0], currentLookupCue, null);
        return Promise.resolve(null);
      }
      if (name === 'tapOutside') {
        closeLookup();
        return Promise.resolve(null);
      }
      if (name === 'openLink') {
        try { window.open(args[0], '_blank'); } catch (_) {}
        return Promise.resolve(null);
      }
      if (name === 'duplicateCheck') {
        var duplicate = args[0] || {};
        return sendRuntime({
          type: 'duplicate', expression: duplicate.expression || '', reading: duplicate.reading || '',
        }).then(function (response) {
          return !!(response && response.ok && response.data && response.data.duplicate === true);
        });
      }
      if (name === 'resolveWordAudio') {
        var audio = args[0] || {};
        return sendRuntime({
          type: 'lookupAudio', expression: audio.expression || '', reading: audio.reading || '',
        }).then(function (response) { return response && response.ok ? response.url || null : null; });
      }
      if (name === 'mineEntry') {
        return sendToTab({
          type: 'fushiSubtitleSidePanelMine', fields: args[0] || {}, cue: currentLookupCue,
        }).then(function (response) {
          if (response && response.ok) {
            toast(response.duplicate ? '✓ 已在制卡队列中' : '✓ 已加入制卡队列');
            return true;
          }
          toast('✗ 制卡失败：当前视频页不可用');
          return false;
        });
      }
      return Promise.resolve(null);
    },
  };

  // 词典图片仍走 Fushi 本地媒体端点，不依赖宿主页面。
  sendRuntime({ type: 'dictMediaConfig' }).then(function (response) {
    if (response && response.ok && response.base && response.token) {
      window.__fushiDictMedia = { base: response.base, token: response.token };
    }
  });

  function toast(message) {
    toastEl.textContent = String(message || '');
    toastEl.classList.add('is-visible');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.remove('is-visible'); }, 2400);
  }

  function queryActiveTab() {
    // 嵌入态只认 SW 背书的那一页；没背书到就不给（宁可空一轮也不去 tabs.query 猜——
    // 页内扩展 iframe 里 currentWindow 解析本就不可靠，那正是当初要问 SW 的原因）。
    if (EMBED) return Promise.resolve(EMBED_TAB_ID != null ? { id: EMBED_TAB_ID } : null);
    return new Promise(function (resolve) {
      chrome.tabs.query({ active: true, currentWindow: true }, function (tabs) {
        try { if (chrome.runtime.lastError) return resolve(null); } catch (_) { return resolve(null); }
        resolve(tabs && tabs[0] || null);
      });
    });
  }

  function sendToTab(message) {
    return new Promise(function (resolve) {
      if (!Number.isInteger(currentTabId)) return resolve(null);
      try {
        chrome.tabs.sendMessage(currentTabId, message, function (response) {
          try { if (chrome.runtime.lastError) return resolve(null); } catch (_) { return resolve(null); }
          resolve(response || null);
        });
      } catch (_) { resolve(null); }
    });
  }

  function fmtTs(ms) {
    var total = Math.max(0, Math.floor((Number(ms) || 0) / 1000));
    var h = Math.floor(total / 3600);
    var m = Math.floor((total % 3600) / 60);
    var s = total % 60;
    var ss = s < 10 ? '0' + s : String(s);
    if (!h) return m + ':' + ss;
    return h + ':' + (m < 10 ? '0' + m : m) + ':' + ss;
  }

  function cueIndexAt(items, timeMs) {
    var lo = 0, hi = items.length - 1, answer = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (items[mid].startMs <= timeMs) { answer = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return answer >= 0 && timeMs < items[answer].endMs ? answer : -1;
  }

  function metadataSignature(state) {
    return [
      state.videoKey || '', state.activeLang || '', Number(state.offsetMs) || 0,
      (state.tracks || []).map(function (track) {
        return [track.lang, track.signature].join('=');
      }).join('|'),
    ].join('::');
  }

  var trackSig = '~';
  function renderTracks(state) {
    var tracks = Array.isArray(state.tracks) ? state.tracks : [];
    // 每 300ms 刷新都清空重建 option，会把展开中的系统级下拉一次一次销毁——
    // 安卓抽屉里「选轨窗口一直闪烁」就是这么来的（桌面同理）。无变化 = DOM 一律不碰；
    // 指纹含 activeLang，所以切轨后选中值照样落得下去。偏移读数是纯文本，放闸外常刷。
    // 指纹还必须含 pending：懒加载轨从「（选中加载）」变成「（N）」时，
    // 只有它在变（lang/label/signature 都原样）——漏了就永远停在旧标签上。
    var sig = (state.activeLang || '') + '\u0003' + tracks.map(function (t) {
      return [t.lang, t.label, t.length, t.signature, t.pending ? 1 : 0].join('\u0001');
    }).join('\u0002');
    if (sig !== trackSig) {
      trackSig = sig;
      trackEl.textContent = '';
      tracks.forEach(function (track) {
        var option = document.createElement('option');
        option.value = track.lang;
        option.textContent = track.label + (track.pending ? '（选中加载）' : '（' + track.length + '）');
        trackEl.appendChild(option);
      });
      trackEl.hidden = tracks.length === 0;
      trackEl.value = state.activeLang || '';
      offsetEl.hidden = tracks.length === 0;
    }
    offsetValueEl.textContent = ((Number(state.offsetMs) || 0) >= 0 ? '+' : '') +
      ((Number(state.offsetMs) || 0) / 1000).toFixed(1) + 's';
  }

  function renderCues() {
    listEl.textContent = '';
    rows = [];
    currentIndex = -1;
    scrollIndex = -1;
    if (!cues.length) {
      var empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = currentState && currentState.hasVideo
        ? '暂无字幕。开启站内字幕，或点“＋”加载外挂字幕。'
        : '当前标签页没有可用的视频。';
      listEl.appendChild(empty);
      return;
    }
    var fragment = document.createDocumentFragment();
    cues.forEach(function (cue, index) {
      var row = document.createElement('div');
      row.className = 'subtitle-row';
      row.dataset.index = String(index);
      var timestamp = document.createElement('button');
      timestamp.className = 'timestamp';
      timestamp.type = 'button';
      timestamp.textContent = fmtTs(cue.startMs);
      timestamp.title = '跳转到此句';
      timestamp.addEventListener('click', function (event) {
        event.stopPropagation();
        sendToTab({ type: 'fushiSubtitleSidePanelSeek', ms: cue.startMs });
      });
      var text = document.createElement('div');
      text.className = 'subtitle-text';
      // 有振假名就画真正的 <ruby>（读音在正文上方），没有就一个文本节点——与覆盖层共用
      // 同一份渲染，见 ruby-render.js。
      if (typeof window.fushiRenderCueText === 'function') window.fushiRenderCueText(text, cue);
      else text.textContent = cue.text;
      text.title = '单击文字查词；点击时间或行空白跳转；双击选择文本；按住 Shift 悬停扫词';
      text.addEventListener('click', function (event) {
        // 行内文字单击=查词（asbplayer 同款；8-11 迁原生 Side Panel 时随旧 UI 层一起丢了，
        // 用户报「点击查词不见了，只能 Shift 查」）。拖选/双击形成的选区在场时不查，
        // 保住「双击选择文本」。
        try {
          var clickSel = window.getSelection && window.getSelection();
          if (clickSel && !clickSel.isCollapsed) return;
        } catch (_) {}
        // 文字块占满整行宽度，点文字右侧的空白也落在这里：取到词才算「点文字=查词」并吞掉
        // 这一击；取不到词就让它继续冒泡到 row 的 seek（点空白=跳转到这句），而不是只留下
        // 一条「未识别到可查词文字」——那时用户既查不了词也跳不了。
        var started = lookupAtPointer({
          x: event.clientX, y: event.clientY, cue: cue, index: index, textEl: text,
        }, { explicit: true });
        if (started) event.stopPropagation();
      });
      function rememberPointer(event) {
        lastPointer = {
          x: event.clientX, y: event.clientY, cue: cue, index: index, textEl: text,
        };
        if (event.shiftKey) schedulePointerLookup(lastPointer);
      }
      text.addEventListener('pointerenter', rememberPointer, { passive: true });
      text.addEventListener('pointermove', rememberPointer, { passive: true });
      text.addEventListener('pointerleave', function () {
        if (lastPointer && lastPointer.textEl === text) lastPointer = null;
      });
      row.addEventListener('click', function (event) {
        if (event.shiftKey) return;
        // 对齐 asbplayer：拖选/双击形成的原生选区属于本行时不跳转，也绝不清选区；
        // 无选区的普通单击才 seek。正文无需等待浏览器的 dblclick 判定窗口。
        try {
          var selection = window.getSelection && window.getSelection();
          var anchorNode = selection && selection.anchorNode;
          var anchorElement = anchorNode && anchorNode.nodeType === Node.ELEMENT_NODE
            ? anchorNode : anchorNode && anchorNode.parentElement;
          if (selection && !selection.isCollapsed && anchorElement && row.contains(anchorElement)) return;
        } catch (_) {}
        sendToTab({ type: 'fushiSubtitleSidePanelSeek', ms: cue.startMs });
      });
      row.appendChild(timestamp);
      row.appendChild(text);
      rows[index] = row;
      fragment.appendChild(row);
    });
    listEl.appendChild(fragment);
    updateCurrent(currentState && currentState.currentTimeMs);
  }

  // 高亮只属于正在显示的字幕；列表定位还需覆盖字幕间隙、片头和片尾。
  function nearestCueIndex(items, timeMs) {
    var active = cueIndexAt(items, timeMs);
    if (active >= 0 || !items.length) return active;
    var lo = 0, hi = items.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (items[mid].startMs <= timeMs) lo = mid + 1;
      else hi = mid;
    }
    if (lo === 0) return 0;
    if (lo === items.length) return lo - 1;
    return timeMs - items[lo - 1].endMs <= items[lo].startMs - timeMs ? lo - 1 : lo;
  }

  function updateCurrent(timeMs) {
    // 初始取轨可能先于播放状态到达，不能把尚未知的时间当作 0 消耗首次定位。
    if (!cues.length || typeof timeMs !== 'number' || !Number.isFinite(timeMs)) return;
    var next = cueIndexAt(cues, timeMs);
    if (next !== currentIndex) {
      if (rows[currentIndex]) rows[currentIndex].classList.remove('is-current');
      currentIndex = next;
      if (rows[currentIndex]) rows[currentIndex].classList.add('is-current');
    }
    var nearest = nearestCueIndex(cues, timeMs);
    if (autoScroll && nearest !== scrollIndex && rows[nearest]) {
      var behavior = scrollIndex < 0 ? 'instant' : 'smooth';
      scrollIndex = nearest;
      try { rows[nearest].scrollIntoView({ block: 'center', behavior: behavior }); }
      catch (_) { rows[nearest].scrollIntoView(); }
    }
  }

  function applyState(state, includesCues) {
    currentState = state;
    statusEl.textContent = state.hasVideo
      ? ((state.tracks || []).length ? '已连接当前视频' : '已找到视频，等待字幕')
      : '当前标签页没有视频';
    renderTracks(state);
    if (includesCues) {
      cues = Array.isArray(state.cues) ? state.cues : [];
      renderCues();
    } else {
      updateCurrent(state.currentTimeMs);
    }
  }

  async function refresh(forceCues) {
    if (embedPaused) return; // 抽屉收起：不空转消息，resume 时立即补一次全量
    if (refreshBusy) return;
    refreshBusy = true;
    try {
      var tab = await queryActiveTab();
      if (!tab || !Number.isInteger(tab.id)) {
        currentTabId = null;
        statusEl.textContent = '找不到当前标签页';
        return;
      }
      if (currentTabId !== tab.id) {
        currentTabId = tab.id;
        stateSignature = '';
        forceCues = true;
      }
      var state = await sendToTab({
        type: 'fushiSubtitleSidePanelState',
        includeCues: forceCues === true,
      });
      if (!state || !state.ok) {
        statusEl.textContent = '此页面尚未连接 Fushi 扩展';
        if (stateSignature !== 'offline') {
          stateSignature = 'offline'; cues = []; currentState = null; renderCues();
        }
        return;
      }
      var signature = metadataSignature(state);
      if (!forceCues && signature !== stateSignature) {
        state = await sendToTab({ type: 'fushiSubtitleSidePanelState', includeCues: true });
        if (!state || !state.ok) return;
        signature = metadataSignature(state);
        forceCues = true;
      }
      stateSignature = signature;
      applyState(state, forceCues === true);
    } finally {
      refreshBusy = false;
    }
  }

  trackEl.addEventListener('change', async function () {
    var state = await sendToTab({ type: 'fushiSubtitleSidePanelSelectTrack', lang: trackEl.value });
    if (state && state.ok) {
      stateSignature = metadataSignature(state);
      applyState(state, true);
    }
  });

  offsetEl.addEventListener('click', async function (event) {
    var button = event.target.closest('button[data-offset]');
    if (!button) return;
    var state = await sendToTab({
      type: 'fushiSubtitleSidePanelOffset',
      deltaMs: Number(button.dataset.offset) || 0,
    });
    if (state && state.ok) { stateSignature = metadataSignature(state); applyState(state, true); }
  });

  document.getElementById('offset-reset').addEventListener('click', async function () {
    var state = await sendToTab({ type: 'fushiSubtitleSidePanelOffset', reset: true });
    if (state && state.ok) { stateSignature = metadataSignature(state); applyState(state, true); }
  });

  document.getElementById('load').addEventListener('click', function () { fileEl.click(); });
  fileEl.addEventListener('change', async function () {
    var files = Array.from(fileEl.files || []);
    for (var i = 0; i < files.length; i++) {
      var file = files[i];
      if (file.size > 8 * 1024 * 1024) { toast('字幕文件过大（上限 8 MB）'); continue; }
      var content = await file.text();
      var parsed = await new Promise(function (resolve) {
        chrome.runtime.sendMessage(
          { type: 'parseSubtitle', filename: file.name, content: content },
          function (response) {
            try { if (chrome.runtime.lastError) return resolve(null); } catch (_) { return resolve(null); }
            resolve(response || null);
          },
        );
      });
      if (!parsed || !parsed.ok || !parsed.data || !Array.isArray(parsed.data.cues)) {
        toast('字幕解析失败：请确认 Fushi 已启动');
        continue;
      }
      var state = await sendToTab({
        type: 'fushiSubtitleSidePanelInstallTrack',
        filename: file.name,
        cues: parsed.data.cues,
      });
      if (state && state.ok) {
        stateSignature = metadataSignature(state);
        applyState(state, true);
        toast('已加载外挂字幕：' + parsed.data.cues.length + ' 句');
      }
    }
    fileEl.value = '';
  });

  // ── Jimaku 查字幕（asb 式云端字幕）：搜索框 → server /api/subtitle/jimaku/search（用户在
  // app 设置里填的 API key；真人剧 anime=false 补搜在 server 侧）→ 点候选下载解析 →
  // 复用外挂字幕的 InstallTrack 落地（与本地文件同一条轨/偏移/覆盖层链路）。
  var jimakuRowEl = document.getElementById('jimaku-row');
  var jimakuQueryEl = document.getElementById('jimaku-query');
  var jimakuEpEl = document.getElementById('jimaku-ep');
  var jimakuResultsEl = document.getElementById('jimaku-results');
  function jimakuErrorText(data, response) {
    var error = data && data.error;
    if (error === 'no-api-key') return '请先在 Fushi 设置 → 视频 → 字幕 填写 Jimaku API key';
    if (error === 'unauthorized') return 'Jimaku API key 无效或无权限';
    if (error === 'rate-limited') return 'Jimaku 限流，请稍后再试';
    if (error === 'missing-query') return '请输入搜索词';
    if (!response || response.ok !== true) return 'Jimaku 搜索失败：请确认 Fushi 已启动';
    return 'Jimaku 暂不可用，请稍后再试';
  }
  async function jimakuInstall(candidate) {
    toast('正在下载：' + candidate.fileName);
    var response = await sendRuntime({ type: 'jimakuFetch', handle: candidate.handle });
    var data = response && response.data;
    if (!response || response.ok !== true || !data || data.ok !== true ||
        !Array.isArray(data.cues) || !data.cues.length) {
      toast(data && data.error === 'unknown-handle'
        ? '候选已过期，请重新搜索'
        : (data && data.error === 'unsupported' ? '不支持的字幕格式' : jimakuErrorText(data, response)));
      return;
    }
    var state = await sendToTab({
      type: 'fushiSubtitleSidePanelInstallTrack',
      filename: data.filename || candidate.fileName,
      cues: data.cues,
    });
    if (state && state.ok) {
      stateSignature = metadataSignature(state);
      applyState(state, true);
      jimakuResultsEl.hidden = true;
      jimakuResultsEl.textContent = '';
      toast('已加载 Jimaku 字幕：' + data.cues.length + ' 句');
    }
  }
  function renderJimakuResults(candidates, truncated) {
    jimakuResultsEl.textContent = '';
    if (!candidates.length) {
      var empty = document.createElement('div');
      empty.className = 'jimaku-empty';
      empty.textContent = '无结果。试试日文原名，或填集数缩小范围。';
      jimakuResultsEl.appendChild(empty);
      jimakuResultsEl.hidden = false;
      return;
    }
    candidates.forEach(function (candidate) {
      var row = document.createElement('button');
      row.type = 'button';
      row.className = 'jimaku-item';
      var name = document.createElement('span');
      name.className = 'jimaku-item-name';
      name.textContent = candidate.fileName;
      var meta = document.createElement('span');
      meta.className = 'jimaku-item-meta';
      meta.textContent = candidate.entryName +
        (candidate.language ? ' · ' + candidate.language : '') +
        (candidate.episode != null ? ' · 第' + candidate.episode + '集' : '');
      row.appendChild(name);
      row.appendChild(meta);
      row.addEventListener('click', function () { jimakuInstall(candidate); });
      jimakuResultsEl.appendChild(row);
    });
    if (truncated) {
      var more = document.createElement('div');
      more.className = 'jimaku-empty';
      more.textContent = '结果过多已截断，填集数可缩小范围。';
      jimakuResultsEl.appendChild(more);
    }
    jimakuResultsEl.hidden = false;
  }
  var jimakuSearching = false;
  async function jimakuSearch() {
    if (jimakuSearching) return;
    var query = String(jimakuQueryEl.value || '').trim();
    if (!query) { toast('请输入搜索词'); return; }
    var episode = parseInt(jimakuEpEl.value, 10);
    jimakuSearching = true;
    toast('正在搜索 Jimaku…');
    try {
      var response = await sendRuntime({
        type: 'jimakuSearch',
        query: query,
        ...(Number.isInteger(episode) && episode > 0 ? { episode: episode } : {}),
      });
      var data = response && response.data;
      if (!response || response.ok !== true || !data || data.ok !== true) {
        toast(jimakuErrorText(data, response));
        return;
      }
      renderJimakuResults(Array.isArray(data.candidates) ? data.candidates : [],
        data.truncated === true);
    } finally {
      jimakuSearching = false;
    }
  }
  document.getElementById('jimaku').addEventListener('click', function () {
    var show = jimakuRowEl.hidden;
    jimakuRowEl.hidden = !show;
    if (!show) { jimakuResultsEl.hidden = true; return; }
    // 预填当前标签页标题（长显示名命中率低，用户可改成日文原名——placeholder 已提示）。
    if (!jimakuQueryEl.value && currentTabId != null) {
      try {
        chrome.tabs.get(currentTabId, function (tab) {
          try { if (chrome.runtime.lastError) return; } catch (_) { return; }
          if (tab && tab.title && !jimakuQueryEl.value) jimakuQueryEl.value = tab.title;
        });
      } catch (_) {}
    }
    jimakuQueryEl.focus();
  });
  document.getElementById('jimaku-go').addEventListener('click', function () { jimakuSearch(); });
  jimakuQueryEl.addEventListener('keydown', function (event) {
    if (event.key === 'Enter') jimakuSearch();
  });

  document.getElementById('smaller').addEventListener('click', function () {
    fontStep = Math.max(0, fontStep - 1);
    document.documentElement.style.setProperty('--subtitle-scale', String(FONT_STEPS[fontStep]));
  });
  document.getElementById('larger').addEventListener('click', function () {
    fontStep = Math.min(FONT_STEPS.length - 1, fontStep + 1);
    document.documentElement.style.setProperty('--subtitle-scale', String(FONT_STEPS[fontStep]));
  });
  autoButton.addEventListener('click', function () {
    autoScroll = !autoScroll;
    autoButton.classList.toggle('is-on', autoScroll);
    if (autoScroll) { scrollIndex = -1; updateCurrent(currentState && currentState.currentTimeMs); }
  });
  document.getElementById('settings').addEventListener('click', function () {
    chrome.runtime.openOptionsPage();
  });
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') {
      closeLookup();
      closePageLookup();
      return;
    }
    // Yomitan 的 modifier-on-keydown 路径：指针已经停在词上时，按下 Shift 就用最后
    // 一次 pointer 坐标立即查，不要求用户再晃动鼠标，也不 preventDefault。
    if (event.key === 'Shift' && !event.repeat && lastPointer) {
      lookupAtPointer(lastPointer, { explicit: true, announceMissing: true });
    }
  }, true);
  document.addEventListener('keyup', function (event) {
    if (event.key === 'Shift') activeScanKey = '';
  }, true);
  document.addEventListener('mousedown', function (event) {
    if (!event.shiftKey && !lookupPaneEl.hidden &&
        event.target !== lookupPaneEl && !lookupPaneEl.contains(event.target)) {
      closeLookup();
    }
  });
  // 「popup 不好关」的补齐三路：①content.js 在用户手动播放视频时反向推送 dismiss（页面弹窗
  // 与本面板一起关）；②焦点离开 Side Panel（点回网页/播放器）即关；③滚动字幕列表（锚点行
  // 已滚走，浮窗不该原地留着）即关。均幂等，重复触发无副作用。
  try {
    chrome.runtime.onMessage.addListener(function (msg) {
      if (!msg || typeof msg.type !== 'string') return;
      if (msg.type === 'fushiLookupDismiss') {
        closeLookup();
        pageLookupOpen = false;
      } else if (msg.type === 'fushiSidePanelLookupGone') {
        // 交出去的那份页面弹窗关了（点页面空白 / Esc / 手动播放）：复位去重键，鼠标停在
        // 同一个字上也能立刻重查。
        pageLookupOpen = false;
        activeScanKey = '';
      }
    });
  } catch (_) {}
  window.addEventListener('blur', function () { closeLookup(); });
  listEl.addEventListener('wheel', function () { closeLookup(); }, { passive: true });
  listEl.addEventListener('touchmove', function () { closeLookup(); }, { passive: true });
  // 用户主动翻阅后停止跟随，点击跟随按钮才重新定位；普通状态轮询不会抢回视口。
  function stopAutoScroll() {
    autoScroll = false;
    autoButton.classList.toggle('is-on', false);
  }
  listEl.addEventListener('wheel', stopAutoScroll, { passive: true });
  listEl.addEventListener('touchmove', stopAutoScroll, { passive: true });
  // 查词面板拖拽调整大小（CSS resize 把手在右下角）：pointerdown 落在右下角 20px 内时快照
  // 尺寸，松手时尺寸真变了才算「用户拖过」——置 lookupUserResized + 回写 app 尺寸键
  // （app clamp 后按「拖即解锁」持久化，下次查词/会话经主题带回来）。
  lookupPaneEl.addEventListener('pointerdown', function (event) {
    try {
      var rect = lookupPaneEl.getBoundingClientRect();
      lookupResizeSnapshot =
        (rect.right - event.clientX <= 20 && rect.bottom - event.clientY <= 20)
          ? { w: rect.width, h: rect.height }
          : null;
    } catch (_) { lookupResizeSnapshot = null; }
  }, { passive: true });
  window.addEventListener('pointerup', function () {
    if (!lookupResizeSnapshot) return;
    var snap = lookupResizeSnapshot;
    lookupResizeSnapshot = null;
    var rect;
    try { rect = lookupPaneEl.getBoundingClientRect(); } catch (_) { return; }
    if (Math.abs(rect.width - snap.w) < 3 && Math.abs(rect.height - snap.h) < 3) return;
    lookupUserResized = true;
    var zoom = parseFloat(lookupPaneEl.style.zoom) || 1;
    lookupBaseMaxHeight = Math.round(rect.height / zoom) + 'px';
    lookupPaneEl.style.maxHeight = '';
    sendRuntime({
      type: 'popupSize',
      maxWidth: Math.round(rect.width / zoom),
      maxHeight: Math.round(rect.height / zoom),
    });
  }, { passive: true });
  window.addEventListener('load', function () {
    // popup.js 在扩展上下文只暴露监听器；与 content.js 的 Shift host 一样，把它
    // 限定挂在常驻 shadow host，避免污染整个 Side Panel 的滚动快速路径。
    if (typeof window.__fushiPopupWheelListener === 'function') {
      lookupPaneEl.addEventListener('wheel', window.__fushiPopupWheelListener, { passive: false });
    }
  }, { once: true });

  // 侧边栏宽度是用户随时可拖的：变窄后原尺寸盒必然溢出被裁。视口一变就按新可用空间
  // 重算尺寸盒，并对开着的弹窗重跑落点（positionLookup 内部自带 hidden 守卫）。
  window.addEventListener('resize', function () {
    applyLookupBox();
    if (!lookupPaneEl.hidden) positionLookup();
  });


  try {
    if (!EMBED) chrome.tabs.onActivated.addListener(function () { refresh(true); });
    chrome.tabs.onUpdated.addListener(function (tabId, changeInfo) {
      if (tabId === currentTabId && changeInfo.status === 'complete') refresh(true);
    });
  } catch (_) {}

  // 抽屉宿主（mobile-drawer.js）的可见性协议：收起=暂停轮询，拉开=立刻全量刷新。
  // 审计报告 #1295：宿主 origin 的来源从「URL 参数自证」（任意网站可伪造）改为
  // 「持 SW 签发的 token 回 SW 核销」——SW 绑定签发 tab、TTL 过期，伪造的 token 兑不出
  // origin。核销前 EMBED_HOST_ORIGIN 保持初始 sentinel（永不等于任何真实 origin），
  // 天然 fail-closed：兑不到就一直不收宿主消息。
  var requestEmbedAttestation = null; // EMBED 时装上；见下（轮询要复用它重试）
  if (EMBED) {
    var EMBED_HOST_ORIGIN = 'fushi-unverified-pending'; // 未核销前的哨兵，绝不匹配任何 origin
    var hostMsg = function (ev) {
      if (ev.origin !== EMBED_HOST_ORIGIN) return;
      var d = ev && ev.data;
      if (!d || d.source !== 'fushi-drawer') return;
      if (d.type === 'pause') embedPaused = true;
      else if (d.type === 'resume') { embedPaused = false; refresh(true); }
    };
    window.addEventListener('message', hostMsg);
    var embedTok = '';
    var embedTokMatch = /[?&]fushiEmbedToken=([^&]*)/.exec(EMBED_SEARCH);
    if (embedTokMatch) {
      try { embedTok = decodeURIComponent(embedTokMatch[1]); } catch (_) { embedTok = ''; }
    }
    var embedVerifyBusy = false;
    // 有没有 token 都要问：origin 要 token 才兑得出（宿主 pause/resume 通道），而 tabId
    // 只看 sender.tab.id、SW 无条件如实给。两者信任根不同，别合成一个判断。
    // 做成**幂等可重试**而不是开局一发：SW 是会被浏览器随时休眠/重启的，那一次 sendMessage
    // 撞上 lastError 就永远拿不到 tabId 了 —— 而 tabId 现在是驱动本页的唯一来源，
    // 一次哑火 = 抽屉永久停在「找不到当前标签页」。轮询里补请求，最多 300ms 自愈。
    requestEmbedAttestation = function () {
      if (embedVerifyBusy || EMBED_TAB_ID != null) return;
      embedVerifyBusy = true;
      try {
        chrome.runtime.sendMessage({ type: 'drawerEmbedVerify', token: embedTok }, function (resp) {
          embedVerifyBusy = false;
          try { if (chrome.runtime.lastError) return; } catch (_) { return; }
          if (!resp) return;
          var o = typeof resp.origin === 'string' ? resp.origin : '';
          if (o) EMBED_HOST_ORIGIN = o; // 只有核销成功才把哨兵换成真 origin
          if (Number.isInteger(resp.tabId)) {
            EMBED_TAB_ID = resp.tabId;
            refresh(true); // 背书到货之前 queryActiveTab 是空的，这一刻才是真正的开局刷新
          }
        });
      } catch (_) { embedVerifyBusy = false; /* 保持哨兵 + 空 tab = fail-closed */ }
    };
    requestEmbedAttestation();
  }

  refresh(true);
  setInterval(function () {
    if (requestEmbedAttestation) requestEmbedAttestation(); // 背书没到手就一直补请求
    refresh(false);
  }, 300);
})();
