// TODO-1184：browser-action popup（图标菜单）。展示制卡队列、逐项删除、开始生成/录制。
// 设了 default_popup 后 chrome.action.onClicked 永不触发，「开始生成/录制」这个原本靠点图标
// （activeTab 手势）驱动的入口迁到这里的按钮：按钮点击是用户手势 → chrome.tabs.query 拿当前 tab
// → 发消息给 background 跑原 fushiIconClick（Netflix 就地录 / YouTube 队列生成）。
// 本文件在扩展页上下文运行（有 chrome API），不注入宿主页，故不复用 content.js 的内存镜像，
// 直接读写 chrome.storage.local 的 fushiQueue（跨 content/popup/background 的单一真相源）。

// 纯函数：从队列里剔除指定 id（读-改-写的核心）。抽出来供 node 测试，无 chrome 依赖。
function fushiFilterQueue(queue, removeId) {
  const list = Array.isArray(queue) ? queue : [];
  return list.filter((q) => q && q.id !== removeId);
}

// 队列项主标签：优先「词」(制卡的主体)，无词才回落到句子。
// TODO-1270：原实现优先句子——同一字幕行里查多个词各点「制卡」会入队多条，去重键是「词+句」
// 所以它们是不同卡片，但标签只显示句子 → 队列里多行「句子一模一样」无法区分。改为主标签显词、
// 句子降为下方暗色上下文行(fushiQueueItemContext)，让同句不同词的卡片一眼可辨。
function fushiQueueItemLabel(q) {
  const word = (q && q.fields && (q.fields.expression || q.fields.word || q.fields.term)) || '';
  const raw = String(word).trim() || String((q && q.sentence) || '').trim();
  if (raw) return raw.length > 40 ? raw.slice(0, 40) + '…' : raw;
  return '(空)';
}

// 队列项的上下文句子（主标签下方暗色次要行）。仅当主标签是「词」时才返回句子；无词时主标签已是
// 句子本身，返回 '' 避免重复回显。
function fushiQueueItemContext(q) {
  const word = (q && q.fields && (q.fields.expression || q.fields.word || q.fields.term)) || '';
  if (!String(word).trim()) return '';
  const sent = String((q && q.sentence) || '').trim();
  if (!sent) return '';
  return sent.length > 60 ? sent.slice(0, 60) + '…' : sent;
}

// 兼容既有 netflixSubtitlePanel 设置的严格读值函数。原生侧边栏入口会把它设为 true；
// options.js 与字幕控制器继续用同一判据，避免历史字符串值误启用网页内能力。
function fushiReadPanelEnabled(stored) {
  return !!(stored && stored.netflixSubtitlePanel === true);
}

// TODO-1881：队列项能跳回的视频页 URL（Netflix 生成必须在 netflix.com 页面、YouTube 生成要有
// content script——用户在队列里看到卡片却回不去对应页面是流程断点）。无可跳站点返回 ''。
function fushiQueueItemUrl(q) {
  if (q && q.site === 'netflix' && q.netflixId) {
    return 'https://www.netflix.com/watch/' + encodeURIComponent(String(q.netflixId));
  }
  if (q && q.site === 'youtube' && q.youtubeId) {
    return 'https://www.youtube.com/watch?v=' + encodeURIComponent(String(q.youtubeId));
  }
  return '';
}

// TODO-1881：从 tab URL 推断站点。与 content.js fushiSite() 同判据（hostname 后缀），只是输入
// 从 location 换成 URL 字符串（popup 上下文没有宿主页 location）。
function fushiTabSite(url) {
  try {
    const h = new URL(String(url || '')).hostname;
    if (h === 'netflix.com' || h.endsWith('.netflix.com')) return 'netflix';
    if (h === 'youtu.be' || h === 'youtube.com' || h.endsWith('.youtube.com')) return 'youtube';
  } catch (_) { /* 无效 URL（chrome:// 空页等）按 other 处理 */ }
  return 'other';
}

// TODO-1881：「开始生成/录制」按钮状态机（纯函数，供 node 测试）。
// 旧实现是隐形三态：同一个按钮承担「取消卡住的生成 / 开始生成 / 静默无操作」，队列空或站点不对时
// 点击毫无反馈直接关 popup。改为显式状态：
// - cancel：fushiNfBatch.active（生成中/卡住残留）→ 可点，取消并清理（逃生口保留，队列空也可点）。
// - generate：当前 tab 站点与队列中可生成项匹配 → 可点，标签带数量；跨站点剩余量进 hint。
// - empty / unsupported / wrongSite：不可点 + hint 说明原因与下一步（wrongSite 引导点队列条目跳转）。
function fushiGenButtonState(queue, batchActive, tabSite) {
  if (batchActive) {
    return { mode: 'cancel', label: '取消生成', enabled: true, hint: '正在生成中，点击取消并清理录制状态' };
  }
  const list = Array.isArray(queue) ? queue : [];
  const nf = list.filter((q) => q && q.site === 'netflix' && q.netflixId).length;
  const yt = list.filter((q) => q && q.site === 'youtube' && q.youtubeId).length;
  if (!list.length) {
    return { mode: 'empty', label: '开始生成 / 录制', enabled: false, hint: '' };
  }
  if (!nf && !yt) {
    return {
      mode: 'unsupported', label: '开始生成 / 录制', enabled: false,
      hint: '队列里的卡片来自暂不支持批量生成的站点，可逐项删除或清空',
    };
  }
  if (tabSite === 'netflix' && nf) {
    return {
      mode: 'generate', label: '开始录制生成（' + nf + ' 张）', enabled: true,
      hint: yt ? '另有 YouTube ' + yt + ' 张，需切到 YouTube 页面生成' : '',
    };
  }
  if (tabSite === 'youtube' && yt) {
    return {
      mode: 'generate', label: '开始生成（' + yt + ' 张）', enabled: true,
      hint: nf ? '另有 Netflix ' + nf + ' 张，需切到 Netflix 播放页生成' : '',
    };
  }
  const parts = [];
  if (nf) parts.push('Netflix ' + nf + ' 张');
  if (yt) parts.push('YouTube ' + yt + ' 张');
  return {
    mode: 'wrongSite', label: '开始生成 / 录制', enabled: false,
    hint: '待生成：' + parts.join(' · ') + '，点队列条目跳到对应视频页再生成',
  };
}

// BUG-1079：自更新失效提示文案（纯函数供 node 测试）。stale = background 写入
// chrome.storage.local.fushiUpdateStale 的 {remote, local}（remote=app 内置最新指纹，
// local=浏览器中实际加载副本的指纹）。无 stale（或缺 remote）返回 null（隐藏提示行）。
function fushiUpdateNotice(stale) {
  if (!stale || !stale.remote) return null;
  const short = (s) => String(s || '').slice(0, 8);
  return {
    title: '扩展有新版本，需手动重新加载',
    detail: '自动更新未生效：请到 chrome://extensions 找到本扩展点「重新加载」'
        + '（当前 ' + (short(stale.local) || '未知') + ' → 最新 ' + short(stale.remote) + '）',
  };
}

// node 单测导出（浏览器里 module 未定义，直接跳过）。
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    fushiFilterQueue, fushiQueueItemLabel, fushiQueueItemContext, fushiReadPanelEnabled,
    fushiQueueItemUrl, fushiTabSite, fushiGenButtonState, fushiUpdateNotice,
  };
}

if (typeof document !== 'undefined' && typeof chrome !== 'undefined' && chrome.storage) {
  const listEl = document.getElementById('hp-list');
  const countEl = document.getElementById('hp-count');
  const genEl = document.getElementById('hp-gen');
  const genHintEl = document.getElementById('hp-gen-hint');

  // 点扩展图标就能看见连接状态；离线/密钥错/Yomitan 占端口均给可执行提示，齿轮进完整设置。
  const connEl = document.getElementById('hp-connection');
  const connTitleEl = document.getElementById('hp-connection-title');
  const connDetailEl = document.getElementById('hp-connection-detail');
  // BUG-1036：popup 生命周期很短，每次打开都要新探测；否则会把上次瞬时离线缓存继续显示成
  // “Fushi API 未开启”，直到用户进完整设置手动重检。
  // TODO-1881：探测抽成函数——连接状态行本身可点，点击即强制重检（原来重试只能进 options 页）。
  function refreshConnection() {
    if (connEl) connEl.dataset.tone = 'loading';
    if (connTitleEl) connTitleEl.textContent = '正在检测 Fushi…';
    if (connDetailEl) connDetailEl.textContent = '查词与字幕服务';
    try {
      chrome.runtime.sendMessage({ type: 'connectionStatus', force: true }, (resp) => {
        try { if (chrome.runtime.lastError) return; } catch (_) { return; }
        const c = resp && resp.connection ? resp.connection : { state: 'offline', port: 19633 };
        const copy = self.FUSHI_CONNECTION.copy(c.state, c.port);
        if (connEl) connEl.dataset.tone = copy.tone;
        if (connTitleEl) connTitleEl.textContent = copy.title;
        if (connDetailEl) connDetailEl.textContent = copy.detail;
        if (connEl) connEl.title = copy.detail + '（点击重新检测）';
      });
    } catch (_) {}
  }
  refreshConnection();
  if (connEl) connEl.addEventListener('click', () => refreshConnection());

  // BUG-1079：自更新失效提示行。background 检测到「已 reload 过仍与 app 内置指纹不一致」
  // 时写 fushiUpdateStale；这里渲染「需到 chrome://extensions 手动重新加载」并随 storage
  // 变化实时显隐（恢复一致时 background 清除该键 → 提示消失）。
  const updateEl = document.getElementById('hp-update');
  const updateTitleEl = document.getElementById('hp-update-title');
  const updateDetailEl = document.getElementById('hp-update-detail');
  function renderUpdateNotice(stale) {
    if (!updateEl) return;
    const notice = fushiUpdateNotice(stale);
    updateEl.hidden = !notice;
    if (!notice) return;
    if (updateTitleEl) updateTitleEl.textContent = notice.title;
    if (updateDetailEl) updateDetailEl.textContent = notice.detail;
  }
  try {
    chrome.storage.local.get(['fushiUpdateStale'], (r) => {
      renderUpdateNotice(r && r.fushiUpdateStale);
    });
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === 'local' && changes.fushiUpdateStale) {
        renderUpdateNotice(changes.fushiUpdateStale.newValue);
      }
    });
  } catch (_) {}
  // 「⚙ 扩展设置」按钮已从连接行内移到页脚独立成行（见 action-popup.html 的注释），
  // 不再嵌在可点的连接行里，故不需要 stopPropagation 去防误判成「重新检测」。
  const optionsEl = document.getElementById('hp-open-options');
  if (optionsEl) {
    optionsEl.addEventListener('click', () => chrome.runtime.openOptionsPage());
  }

  function readQueue() {
    return new Promise((resolve) => {
      try {
        chrome.storage.local.get(['fushiQueue'], (r) => {
          resolve(Array.isArray(r && r.fushiQueue) ? r.fushiQueue : []);
        });
      } catch (_) { resolve([]); }
    });
  }

  // 逐项删除：storage 读-改-写（不覆盖并发入队），与 content.js fushiRemoveQueued 一致的安全模型。
  async function removeItem(id) {
    const fresh = await readQueue();
    const remaining = fushiFilterQueue(fresh, id);
    try { await chrome.storage.local.set({ fushiQueue: remaining }); } catch (_) {}
    render(remaining);
  }

  // TODO-1881：清空队列（原来 N 条要点 N 次 ×）。二次确认：首点变「确认清空？」，3 秒内再点才清。
  let clearConfirmTimer = null;
  async function clearQueue() {
    try { await chrome.storage.local.set({ fushiQueue: [] }); } catch (_) {}
    render([]);
  }

  // ── TODO-1881：生成按钮状态机接线 ──
  // popup 打开时 query 一次当前 tab（popup 绑定于当前窗口活动 tab，生命周期内不变）；
  // 队列/批量状态经 storage.onChanged 实时驱动重算。
  let genTab = null; // {id,url}；query 回来前按 other 站点渲染（按钮先禁用，回来后立即修正）
  function updateGenButton(queue, batch) {
    if (!genEl) return;
    const state = fushiGenButtonState(queue, !!(batch && batch.active), fushiTabSite(genTab && genTab.url));
    genEl.textContent = state.label;
    genEl.disabled = !state.enabled;
    genEl.dataset.mode = state.mode;
    if (genHintEl) {
      genHintEl.textContent = state.hint;
      genHintEl.hidden = !state.hint;
    }
  }
  function refreshGenButton(queue) {
    try {
      chrome.storage.local.get(['fushiNfBatch'], (r) => {
        updateGenButton(queue, r && r.fushiNfBatch);
      });
    } catch (_) { updateGenButton(queue, null); }
  }

  function render(queue) {
    const list = Array.isArray(queue) ? queue : [];
    if (countEl) countEl.textContent = list.length ? String(list.length) : '';
    refreshGenButton(list);
    if (!listEl) return;
    listEl.textContent = '';
    if (!list.length) {
      const empty = document.createElement('div');
      empty.className = 'hp-empty';
      empty.textContent = '队列为空：开字幕 → Shift 查词 → 弹窗「制卡」入队，再回来生成';
      listEl.appendChild(empty);
      return;
    }
    // TODO-1222：给队列列表加一行标题头（与顶部应用标题区分：这里标注下方是「待生成的卡片」）。
    const heading = document.createElement('div');
    heading.className = 'hp-list-title';
    const headingText = document.createElement('span');
    headingText.textContent = '待生成的卡片（' + list.length + '）';
    heading.appendChild(headingText);
    // TODO-1881：清空按钮（二次确认）挂在标题行右侧。
    const clearBtn = document.createElement('button');
    clearBtn.className = 'hp-clear';
    clearBtn.type = 'button';
    clearBtn.textContent = '清空';
    clearBtn.addEventListener('click', () => {
      if (clearBtn.dataset.confirm === '1') {
        if (clearConfirmTimer) { clearTimeout(clearConfirmTimer); clearConfirmTimer = null; }
        clearQueue();
        return;
      }
      clearBtn.dataset.confirm = '1';
      clearBtn.textContent = '确认清空？';
      if (clearConfirmTimer) clearTimeout(clearConfirmTimer);
      clearConfirmTimer = setTimeout(() => {
        clearBtn.dataset.confirm = '';
        clearBtn.textContent = '清空';
      }, 3000);
    });
    heading.appendChild(clearBtn);
    listEl.appendChild(heading);
    for (const q of list) {
      const row = document.createElement('div');
      row.className = 'hp-row';
      if (q && q.site && q.site !== 'other') {
        const site = document.createElement('span');
        site.className = 'hp-row-site';
        site.textContent = q.site === 'netflix' ? 'NF' : (q.site === 'youtube' ? 'YT' : q.site);
        row.appendChild(site);
      }
      // TODO-1270：主标签(词) + 下方暗色上下文句子；同一字幕行不同词的卡片靠「词」区分，不再一模一样。
      const main = document.createElement('div');
      main.className = 'hp-row-main';
      const text = document.createElement('span');
      text.className = 'hp-row-text';
      const label = fushiQueueItemLabel(q);
      text.textContent = label;
      main.appendChild(text);
      const context = fushiQueueItemContext(q);
      if (context) {
        const sub = document.createElement('span');
        sub.className = 'hp-row-sub';
        sub.textContent = context;
        main.appendChild(sub);
      }
      // TODO-1881：条目可点击跳回对应视频页（Netflix 生成必须在其页面；wrongSite hint 引导到这里）。
      const jumpUrl = fushiQueueItemUrl(q);
      if (jumpUrl) {
        main.dataset.url = jumpUrl;
        main.title = (context ? (label + ' — ' + context) : label) + '\n点击打开视频页';
        main.addEventListener('click', () => {
          try { chrome.tabs.create({ url: jumpUrl }); } catch (_) {}
        });
      } else {
        main.title = context ? (label + ' — ' + context) : label;
      }
      const del = document.createElement('button');
      del.className = 'hp-del';
      del.type = 'button';
      del.textContent = '×';
      del.title = '从队列移除';
      const id = q && q.id;
      del.addEventListener('click', () => { if (id) removeItem(id); });
      row.appendChild(main);
      row.appendChild(del);
      listEl.appendChild(row);
    }
  }

  // 「开始生成/录制」：按钮点击=用户手势 → 拿当前 tab → 让 background 跑 fushiIconClick。
  // Netflix：background 就地起录屏（复用本次 action 授予的 activeTab）；YouTube：跑队列服务端裁剪。
  if (genEl) {
    genEl.addEventListener('click', () => {
      try {
        chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
          const tab = tabs && tabs[0];
          if (!tab || tab.id == null) { window.close(); return; }
          try {
            chrome.runtime.sendMessage(
              { type: 'fushiIconAction', tab: { id: tab.id, url: tab.url || '' } },
              () => { try { void chrome.runtime.lastError; } catch (_) {} });
          } catch (_) {}
          window.close(); // 关闭 popup，让 content 就地跑（Netflix 就地录需当前页可见）
        });
      } catch (_) { window.close(); }
    });
  }

  // 浏览器原生 Side Panel 入口。按钮总是可点；点击同时启用字幕控制器并把当前 tab 的
  // side_panel 打开。失败时回落给 service worker，仍保持在同一个用户手势链内。
  const nfToggle = document.getElementById('hp-nf-sublist');
  if (nfToggle) {
    nfToggle.addEventListener('click', () => {
      try { chrome.storage.local.set({ netflixSubtitlePanel: true }); } catch (_) {}
      try {
        chrome.tabs.query({ active: true, currentWindow: true }, async (tabs) => {
          const tab = tabs && tabs[0];
          if (!tab || tab.id == null) return;
          try {
            if (!chrome.sidePanel) throw new Error('sidePanel unavailable');
            await chrome.sidePanel.setOptions({ tabId: tab.id, path: 'side-panel.html', enabled: true });
            await chrome.sidePanel.open({ tabId: tab.id });
          } catch (_) {
            try { chrome.runtime.sendMessage({ type: 'openSubtitleSidePanel', tabId: tab.id }); } catch (_) {}
          }
          window.close();
        });
      } catch (_) {}
    });
  }

  // 队列在别处（content 入队 / 生成出队 / 别的标签）变化时，popup 若还开着就实时刷新。
  // TODO-1881：fushiNfBatch 变化（生成开始/结束/取消）也要刷新按钮状态（取消↔生成切换）。
  try {
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area !== 'local') return;
      if (changes.fushiQueue) {
        render(Array.isArray(changes.fushiQueue.newValue) ? changes.fushiQueue.newValue : []);
      } else if (changes.fushiNfBatch) {
        readQueue().then((q) => updateGenButton(q, changes.fushiNfBatch.newValue));
      }
    });
  } catch (_) {}

  // TODO-1881：先渲染（按钮按 other 站点保守禁用），tab query 回来后立即按真实站点修正。
  readQueue().then(render);
  try {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      genTab = (tabs && tabs[0]) || null;
      readQueue().then((q) => refreshGenButton(q));
    });
  } catch (_) {}
}
