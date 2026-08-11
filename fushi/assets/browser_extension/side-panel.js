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
  var lookupTermEl = document.getElementById('lookup-term');
  var lookupHostEl = document.getElementById('lookup-host');
  var lookupShadow = lookupHostEl.attachShadow({ mode: 'open' });
  var lookupStyles = document.createElement('link');
  lookupStyles.rel = 'stylesheet';
  lookupStyles.href = chrome.runtime.getURL('vendor/content.css');
  var lookupOverrides = document.createElement('style');
  lookupOverrides.textContent =
    '#entries-container{width:100%!important;max-width:none!important;max-height:none!important;' +
    'overflow:visible!important;padding:8px 10px 12px!important;}';
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
  var lookupRequestId = 0;
  var lookupCache = new Map();
  var LOOKUP_CACHE_LIMIT = 48;
  var FONT_STEPS = [0.85, 1, 1.15, 1.3];

  function sendRuntime(message) {
    return new Promise(function (resolve) {
      try {
        chrome.runtime.sendMessage(message, function (response) {
          try { if (chrome.runtime.lastError) return resolve(null); } catch (_) { return resolve(null); }
          resolve(response || null);
        });
      } catch (_) { resolve(null); }
    });
  }

  function closeLookup() {
    lookupRequestId += 1;
    lookupPaneEl.hidden = true;
    lookupTermEl.textContent = '';
    lookupContainer.textContent = '';
    currentLookupCue = null;
  }

  function positionLookup(anchorY) {
    if (!Number.isFinite(anchorY)) return;
    var atTop = anchorY > window.innerHeight / 2;
    var available = atTop ? anchorY - 16 : window.innerHeight - anchorY - 16;
    lookupPaneEl.classList.toggle('is-top', atTop);
    lookupPaneEl.style.maxHeight = 'min(72vh, ' + Math.max(96, Math.floor(available)) + 'px)';
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
  }

  function renderLookupData(value, data) {
    try { window.lookupEntries = JSON.parse(data.popupJson); }
    catch (_) { window.lookupEntries = []; }
    window.audioSources = Array.isArray(data.audioSources) ? data.audioSources : [];
    window.needsAudio = true;
    window._noResultsMessage = '没有查到结果';
    applyLookupTheme(data.theme);
    if (typeof window.renderPopup === 'function') window.renderPopup();
    else lookupContainer.innerHTML = '<div class="no-results">词典组件尚未就绪，请重试。</div>';
  }

  function rememberLookup(value, data) {
    if (lookupCache.has(value)) lookupCache.delete(value);
    lookupCache.set(value, data);
    while (lookupCache.size > LOOKUP_CACHE_LIMIT) {
      lookupCache.delete(lookupCache.keys().next().value);
    }
  }

  async function lookupTerm(term, cue, anchorY) {
    var value = String(term || '').trim();
    if (!value) return;
    var requestId = ++lookupRequestId;
    currentLookupCue = cue || currentLookupCue;
    positionLookup(anchorY);
    lookupTermEl.textContent = value;
    lookupPaneEl.hidden = false;
    // 与 Yomitan 的 click scan 一致：点击路径不进入被动扫描 delay。cue 准备与词典 HTTP
    // 并行发起，不能让 tabs 消息往返串在查词请求之前；重复词直接复用本面板内的 LRU 结果。
    sendToTab({ type: 'fushiSubtitleSidePanelPrepareLookup', cue: currentLookupCue });
    var cached = lookupCache.get(value);
    if (cached) {
      lookupCache.delete(value);
      lookupCache.set(value, cached);
      renderLookupData(value, cached);
      return;
    }
    lookupContainer.innerHTML = '<div class="no-results">正在查词…</div>';
    var response = await sendRuntime({ type: 'lookup', term: value });
    if (requestId !== lookupRequestId) return;
    if (!response || response.ok !== true || !response.data || !response.data.popupJson) {
      lookupContainer.innerHTML = '<div class="no-results">查词失败，请确认 Fushi 查词服务已开启。</div>';
      return;
    }
    rememberLookup(value, response.data);
    renderLookupData(value, response.data);
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
      if (name === 'tapOutside') return Promise.resolve(null);
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
      timestamp.addEventListener('click', function () {
        sendToTab({ type: 'fushiSubtitleSidePanelSeek', ms: cue.startMs });
      });
      var text = document.createElement('div');
      text.className = 'subtitle-text';
      text.textContent = cue.text;
      text.title = '单击查词；双击选择文本';
      async function lookupAt(x, y) {
        var term = '';
        try {
          var hit = window.fushiSelection && window.fushiSelection.getCharacterAtPoint
            ? window.fushiSelection.getCharacterAtPoint(x, y) : null;
          if (hit && window.fushiSelection.selectFromPosition) {
            term = window.fushiSelection.selectFromPosition(
              hit.node, hit.offset, 12, x, y,
            );
          }
        } catch (_) { term = ''; }
        if (!term) {
          toast('未识别到可查词文字');
          return;
        }
        lookupTerm(term, cue, y);
      }
      text.addEventListener('click', function (event) {
        // Yomitan 的 click scan 不等待被动扫描 delay：第一击立即查；第二击 detail>1
        // 不重复查。词典抽屉会被放到点击点的另一侧，且共享 popup.js 已限定在自己的
        // Shadow DOM 内，所以后续浏览器原生双击选区不会被遮挡或 removeAllRanges。
        if (event.detail > 1) return;
        lookupAt(event.clientX, event.clientY);
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
  document.getElementById('lookup-close').addEventListener('click', closeLookup);

  try {
    chrome.tabs.onActivated.addListener(function () { refresh(true); });
    chrome.tabs.onUpdated.addListener(function (tabId, changeInfo) {
      if (tabId === currentTabId && changeInfo.status === 'complete') refresh(true);
    });
  } catch (_) {}

  refresh(true);
  setInterval(function () { refresh(false); }, 300);
})();
