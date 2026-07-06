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

// 队列项的简短标签：优先入队时存的句子，其次表达/词字段。与 content.js 的 hibikiQueueItemLabel 同款。
function hibikiQueueItemLabel(q) {
  const raw = (q && (q.sentence || (q.fields && (q.fields.expression || q.fields.word || q.fields.term)))) || '';
  const txt = String(raw).trim();
  if (txt) return txt.length > 40 ? txt.slice(0, 40) + '…' : txt;
  return '(空)';
}

// node 单测导出（浏览器里 module 未定义，直接跳过）。
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { hibikiFilterQueue, hibikiQueueItemLabel };
}

if (typeof document !== 'undefined' && typeof chrome !== 'undefined' && chrome.storage) {
  const listEl = document.getElementById('hp-list');
  const countEl = document.getElementById('hp-count');
  const genEl = document.getElementById('hp-gen');

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
    for (const q of list) {
      const row = document.createElement('div');
      row.className = 'hp-row';
      if (q && q.site && q.site !== 'other') {
        const site = document.createElement('span');
        site.className = 'hp-row-site';
        site.textContent = q.site === 'netflix' ? 'NF' : (q.site === 'youtube' ? 'YT' : q.site);
        row.appendChild(site);
      }
      const text = document.createElement('span');
      text.className = 'hp-row-text';
      text.textContent = hibikiQueueItemLabel(q);
      text.title = text.textContent;
      const del = document.createElement('button');
      del.className = 'hp-del';
      del.type = 'button';
      del.textContent = '×';
      del.title = '从队列移除';
      const id = q && q.id;
      del.addEventListener('click', () => { if (id) removeItem(id); });
      row.appendChild(text);
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
