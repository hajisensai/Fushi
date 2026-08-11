(function () {
  'use strict';

  // vendor/selection.js 与 app/WebView 共用，selectFromPosition() 在返回命中的词之前会通知
  // flutter_inappwebview.textSelected。Side Panel 是纯扩展页面，没有 WebView bridge；提供无副作用
  // 兼容桥，避免选词已经成功却在返回值前抛错。真正的查词仍通过 sendToTab 发给当前视频页。
  if (!window.flutter_inappwebview) {
    window.flutter_inappwebview = {
      callHandler: function () { return Promise.resolve(null); },
    };
  }

  var listEl = document.getElementById('list');
  var trackEl = document.getElementById('track');
  var offsetEl = document.getElementById('offset');
  var offsetValueEl = document.getElementById('offset-value');
  var statusEl = document.getElementById('video-status');
  var fileEl = document.getElementById('subtitle-file');
  var autoButton = document.getElementById('auto-scroll');
  var toastEl = document.getElementById('toast');
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
  var lookupTimer = null;
  var FONT_STEPS = [0.85, 1, 1.15, 1.3];

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
      text.title = '点击文字查词';
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
        var response = await sendToTab({
          type: 'fushiSubtitleSidePanelLookup', term: term, cue: cue,
        });
        if (!response || response.ok !== true) toast('查词失败：请刷新当前视频页后重试');
      }
      text.addEventListener('click', function (event) {
        // 双击完全交给浏览器原生文本选择；只有确认不是双击后才发单击查词。
        if (lookupTimer) { clearTimeout(lookupTimer); lookupTimer = null; }
        if (event.detail > 1) return;
        var x = event.clientX;
        var y = event.clientY;
        lookupTimer = setTimeout(function () {
          lookupTimer = null;
          lookupAt(x, y);
        }, 240);
      });
      text.addEventListener('dblclick', function () {
        if (lookupTimer) { clearTimeout(lookupTimer); lookupTimer = null; }
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

  try {
    chrome.tabs.onActivated.addListener(function () { refresh(true); });
    chrome.tabs.onUpdated.addListener(function (tabId, changeInfo) {
      if (tabId === currentTabId && changeInfo.status === 'complete') refresh(true);
    });
  } catch (_) {}

  refresh(true);
  setInterval(function () { refresh(false); }, 300);
})();
