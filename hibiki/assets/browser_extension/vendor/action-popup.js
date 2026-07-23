// TODO-1184：browser-action popup（图标菜单）。展示制卡队列、逐项删除、开始生成/录制。
// 设了 default_popup 后 chrome.action.onClicked 永不触发，「开始生成/录制」这个原本靠点图标
// （activeTab 手势）驱动的入口迁到这里的按钮：按钮点击是用户手势 → chrome.tabs.query 拿当前 tab
// → 发消息给 background 跑原 hibikiIconClick（Netflix 就地录 / YouTube 队列生成）。
// 本文件在扩展页上下文运行（有 chrome API），不注入宿主页，故不复用 content.js 的内存镜像，
// 直接读写 chrome.storage.local 的 hibikiQueue（跨 content/popup/background 的单一真相源）。

// 纯函数：从队列里剔除指定 id（读-改-写的核心）。抽出来供 node 测试，无 chrome 依赖。
function hibikiFilterQueue(queue, removeId) {
  const list = Array.isArray(queue) ? queue : [];
  return list.filter((q) => q && q.id !== removeId);
}

// 队列项主标签：优先「词」(制卡的主体)，无词才回落到句子。
// TODO-1270：原实现优先句子——同一字幕行里查多个词各点「制卡」会入队多条，去重键是「词+句」
// 所以它们是不同卡片，但标签只显示句子 → 队列里多行「句子一模一样」无法区分。改为主标签显词、
// 句子降为下方暗色上下文行(hibikiQueueItemContext)，让同句不同词的卡片一眼可辨。
function hibikiQueueItemLabel(q) {
  const word = (q && q.fields && (q.fields.expression || q.fields.word || q.fields.term)) || '';
  const raw = String(word).trim() || String((q && q.sentence) || '').trim();
  if (raw) return raw.length > 40 ? raw.slice(0, 40) + '…' : raw;
  return '(空)';
}

// 队列项的上下文句子（主标签下方暗色次要行）。仅当主标签是「词」时才返回句子；无词时主标签已是
// 句子本身，返回 '' 避免重复回显。
function hibikiQueueItemContext(q) {
  const word = (q && q.fields && (q.fields.expression || q.fields.word || q.fields.term)) || '';
  if (!String(word).trim()) return '';
  const sent = String((q && q.sentence) || '').trim();
  if (!sent) return '';
  return sent.length > 60 ? sent.slice(0, 60) + '…' : sent;
}

// TODO-1219：网飞字幕列表面板开关的读值纯函数（默认关 + 只认 boolean true）。抽出来供 node 测试，
// 与 subtitle-panel.js 的 enabled:false 默认、options.js 的 === true 判据一致，防回归成默认打开。
function hibikiReadPanelEnabled(stored) {
  return !!(stored && stored.netflixSubtitlePanel === true);
}

// node 单测导出（浏览器里 module 未定义，直接跳过）。
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { hibikiFilterQueue, hibikiQueueItemLabel, hibikiQueueItemContext, hibikiReadPanelEnabled };
}

if (typeof document !== 'undefined' && typeof chrome !== 'undefined' && chrome.storage) {
  const listEl = document.getElementById('hp-list');
  const countEl = document.getElementById('hp-count');
  const genEl = document.getElementById('hp-gen');

  // 点扩展图标就能看见连接状态；离线/密钥错/Yomitan 占端口均给可执行提示，齿轮进完整设置。
  const connEl = document.getElementById('hp-connection');
  const connTitleEl = document.getElementById('hp-connection-title');
  const connDetailEl = document.getElementById('hp-connection-detail');
  try {
    // BUG-1036：popup 生命周期很短，每次打开都要新探测；否则会把上次瞬时离线缓存继续显示成
    // “Hibiki API 未开启”，直到用户进完整设置手动重检。
    chrome.runtime.sendMessage({ type: 'connectionStatus', force: true }, (resp) => {
      try { if (chrome.runtime.lastError) return; } catch (_) { return; }
      const c = resp && resp.connection ? resp.connection : { state: 'offline', port: 19633 };
      const copy = self.HIBIKI_CONNECTION.copy(c.state, c.port);
      if (connEl) connEl.dataset.tone = copy.tone;
      if (connTitleEl) connTitleEl.textContent = copy.title;
      if (connDetailEl) connDetailEl.textContent = copy.detail;
      if (connEl) connEl.title = copy.detail;
    });
  } catch (_) {}
  const optionsEl = document.getElementById('hp-open-options');
  if (optionsEl) optionsEl.addEventListener('click', () => chrome.runtime.openOptionsPage());

  function readQueue() {
    return new Promise((resolve) => {
      try {
        chrome.storage.local.get(['hibikiQueue'], (r) => {
          resolve(Array.isArray(r && r.hibikiQueue) ? r.hibikiQueue : []);
        });
      } catch (_) { resolve([]); }
    });
  }

  // 逐项删除：storage 读-改-写（不覆盖并发入队），与 content.js hibikiRemoveQueued 一致的安全模型。
  async function removeItem(id) {
    const fresh = await readQueue();
    const remaining = hibikiFilterQueue(fresh, id);
    try { await chrome.storage.local.set({ hibikiQueue: remaining }); } catch (_) {}
    render(remaining);
  }

  function render(queue) {
    const list = Array.isArray(queue) ? queue : [];
    if (countEl) countEl.textContent = list.length ? String(list.length) : '';
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
    heading.textContent = '待生成的卡片（' + list.length + '）';
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
      const label = hibikiQueueItemLabel(q);
      text.textContent = label;
      main.appendChild(text);
      const context = hibikiQueueItemContext(q);
      if (context) {
        const sub = document.createElement('span');
        sub.className = 'hp-row-sub';
        sub.textContent = context;
        main.appendChild(sub);
      }
      main.title = context ? (label + ' — ' + context) : label;
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

  // 「开始生成/录制」：按钮点击=用户手势 → 拿当前 tab → 让 background 跑 hibikiIconClick。
  // Netflix：background 就地起录屏（复用本次 action 授予的 activeTab）；YouTube：跑队列服务端裁剪。
  if (genEl) {
    genEl.addEventListener('click', () => {
      try {
        chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
          const tab = tabs && tabs[0];
          if (!tab || tab.id == null) { window.close(); return; }
          try {
            chrome.runtime.sendMessage(
              { type: 'hibikiIconAction', tab: { id: tab.id, url: tab.url || '' } },
              () => { try { void chrome.runtime.lastError; } catch (_) {} });
          } catch (_) {}
          window.close(); // 关闭 popup，让 content 就地跑（Netflix 就地录需当前页可见）
        });
      } catch (_) { window.close(); }
    });
  }

  // TODO-1219：网飞字幕列表面板开关（扩展弹窗入口，方案 B）。读写与 options 页同一
  // chrome.storage.local.netflixSubtitlePanel（缺省即关），改动即时持久化；subtitle-panel.js 经
  // storage.onChanged 实时生效。这里只加「点扩展图标即可开」的入口，不动上方 1270 制卡队列。
  const nfToggle = document.getElementById('hp-nf-sublist');
  if (nfToggle) {
    try {
      chrome.storage.local.get(['netflixSubtitlePanel'], (r) => {
        nfToggle.checked = hibikiReadPanelEnabled(r);
      });
    } catch (_) {}
    nfToggle.addEventListener('change', () => {
      try { chrome.storage.local.set({ netflixSubtitlePanel: nfToggle.checked }); } catch (_) {}
    });
    // options 页或别处改了开关时，popup 若还开着即时反映勾选态（独立监听，不动队列监听）。
    try {
      chrome.storage.onChanged.addListener((changes, area) => {
        if (area === 'local' && changes.netflixSubtitlePanel) {
          nfToggle.checked = changes.netflixSubtitlePanel.newValue === true;
        }
      });
    } catch (_) {}
  }

  // 队列在别处（content 入队 / 生成出队 / 别的标签）变化时，popup 若还开着就实时刷新。
  try {
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === 'local' && changes.hibikiQueue) {
        render(Array.isArray(changes.hibikiQueue.newValue) ? changes.hibikiQueue.newValue : []);
      }
    });
  } catch (_) {}

  readQueue().then(render);
}
