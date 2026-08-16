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
  var currentTabId = null;
  var currentState = null;
  var cues = [];
  var rows = [];
  var currentIndex = -1;
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

  function closeLookup() {
    lookupRequestId += 1;
    if (Number.isInteger(window._renderGeneration)) window._renderGeneration += 1;
    window._renderInProgress = false;
    lookupPaneEl.hidden = true;
    lookupPaneEl.style.visibility = 'hidden';
    lookupContainer.textContent = '';
    currentLookupCue = null;
    currentLookupAnchor = null;
    currentLookupPerfContext = null;
    activeScanKey = '';
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
    lookupPaneEl.style.maxHeight = 'min(' + lookupBaseMaxHeight + ', 80vh)';
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
    lookupPaneEl.style.width = theme['--fushi-popup-max-width'] || '400px';
    lookupPaneEl.style.maxWidth = 'calc(100vw - 16px)';
    lookupBaseMaxHeight = theme['--fushi-popup-max-height'] || '360px';
    lookupPaneEl.style.maxHeight = 'min(' + lookupBaseMaxHeight + ', 80vh)';
    lookupPaneEl.style.zoom = theme['--fushi-popup-zoom'] || '1';
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
    if (typeof window.renderPopup === 'function') window.renderPopup();
    else lookupContainer.innerHTML = '<div class="no-results">词典组件尚未就绪，请重试。</div>';
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
      var prepared = {
        audioSources: data.audioSources,
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

  function lookupAtPointer(pointer, announceMissing) {
    if (!pointer || !pointer.textEl || !pointer.textEl.isConnected) return;
    var hovered = document.elementFromPoint(pointer.x, pointer.y);
    if (!hovered || (hovered !== pointer.textEl && !pointer.textEl.contains(hovered))) return;
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
      return;
    }
    var scanKey = pointer.index + '\u0000' + term;
    if (scanKey === activeScanKey && !lookupPaneEl.hidden) return;
    // 在途闸只拦 pointermove 自动扫词（announceMissing=false）；显式手势永远放行。
    // 超过截止时间的在途视为已死（SW 被回收等），放行新查词——死锁不可复活。
    if (!announceMissing && lookupPendingSince &&
        Date.now() - lookupPendingSince < LOOKUP_PENDING_TIMEOUT_MS) {
      return;
    }
    activeScanKey = scanKey;
    lookupTerm(term, pointer.cue, anchorForHit(hit, pointer.x, pointer.y));
  }

  function schedulePointerLookup(pointer) {
    scheduledPointer = pointer;
    if (scanFrame !== null) return;
    scanFrame = requestAnimationFrame(function () {
      scanFrame = null;
      var next = scheduledPointer;
      scheduledPointer = null;
      lookupAtPointer(next, false);
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

  function renderTracks(state) {
    var tracks = Array.isArray(state.tracks) ? state.tracks : [];
    trackEl.textContent = '';
    tracks.forEach(function (track) {
      var option = document.createElement('option');
      option.value = track.lang;
      option.textContent = track.label + '（' + track.length + '）';
      trackEl.appendChild(option);
    });
    trackEl.hidden = tracks.length === 0;
    trackEl.value = state.activeLang || '';
    offsetEl.hidden = tracks.length === 0;
    offsetValueEl.textContent = ((Number(state.offsetMs) || 0) >= 0 ? '+' : '') +
      ((Number(state.offsetMs) || 0) / 1000).toFixed(1) + 's';
  }

  function renderCues() {
    listEl.textContent = '';
    rows = [];
    currentIndex = -1;
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
      text.textContent = cue.text;
      text.title = '单击跳转；按住 Shift 指向文字查词；双击选择文本';
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
    updateCurrent(currentState ? currentState.currentTimeMs : 0);
  }

  function updateCurrent(timeMs) {
    if (!cues.length) return;
    var next = cueIndexAt(cues, Number(timeMs) || 0);
    if (next === currentIndex) return;
    if (rows[currentIndex]) rows[currentIndex].classList.remove('is-current');
    currentIndex = next;
    var row = rows[currentIndex];
    if (row) {
      row.classList.add('is-current');
      if (autoScroll) {
        try { row.scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (_) { row.scrollIntoView(); }
      }
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
    if (autoScroll) { currentIndex = -1; updateCurrent(currentState ? currentState.currentTimeMs : 0); }
  });
  document.getElementById('settings').addEventListener('click', function () {
    chrome.runtime.openOptionsPage();
  });
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') {
      closeLookup();
      return;
    }
    // Yomitan 的 modifier-on-keydown 路径：指针已经停在词上时，按下 Shift 就用最后
    // 一次 pointer 坐标立即查，不要求用户再晃动鼠标，也不 preventDefault。
    if (event.key === 'Shift' && !event.repeat && lastPointer) {
      lookupAtPointer(lastPointer, true);
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
  window.addEventListener('load', function () {
    // popup.js 在扩展上下文只暴露监听器；与 content.js 的 Shift host 一样，把它
    // 限定挂在常驻 shadow host，避免污染整个 Side Panel 的滚动快速路径。
    if (typeof window.__fushiPopupWheelListener === 'function') {
      lookupPaneEl.addEventListener('wheel', window.__fushiPopupWheelListener, { passive: false });
    }
  }, { once: true });

  try {
    chrome.tabs.onActivated.addListener(function () { refresh(true); });
    chrome.tabs.onUpdated.addListener(function (tabId, changeInfo) {
      if (tabId === currentTabId && changeInfo.status === 'complete') refresh(true);
    });
  } catch (_) {}

  refresh(true);
  setInterval(function () { refresh(false); }, 300);
})();
