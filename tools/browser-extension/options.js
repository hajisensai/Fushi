// Hibiki 浏览器扩展设置：自动连接优先，用户覆盖与字幕偏好存 chrome.storage.local。
const $ = (id) => document.getElementById(id);
const D = self.FUSHI_DEFAULTS || { host: '127.0.0.1', port: 19633, token: '' };
const settingDefaults = Object.freeze({
  netflixSubtitlePanel: false,
  subtitleOverlayEnabled: true,
  subtitleDragDropEnabled: true,
  subtitleAutoScroll: true,
  netflixHideNextEpisode: true,
  subtitlePauseOnLookup: false,
  subtitleOverlayAutoLookup: false,
  subtitleOverlayBlur: false,
  subtitleOverlayAllTracks: false,
  // 隐藏字幕是实际显示状态；Shift+H 是否接管由独立快捷键开关控制。
  subtitleHidden: false,
  videoShortcutPrevCue: true,
  videoShortcutNextCue: true,
  videoShortcutReplayCue: true,
  videoShortcutTogglePanel: true,
  videoShortcutToggleSubtitleHide: true,
  videoShortcutOffsetMinus: true,
  videoShortcutOffsetPlus: true,
  videoShortcutOffsetReset: true,
  videoShortcutCopyCue: true,
  videoShortcutRateDown: true,
  videoShortcutRateUp: true,
});
const toggleIds = Object.freeze({
  nfSubList: 'netflixSubtitlePanel',
  subtitleOverlayEnabled: 'subtitleOverlayEnabled',
  subtitleDragDropEnabled: 'subtitleDragDropEnabled',
  subtitleAutoScroll: 'subtitleAutoScroll',
  nfHideNext: 'netflixHideNextEpisode',
  subtitlePauseOnLookup: 'subtitlePauseOnLookup',
  subtitleOverlayAutoLookup: 'subtitleOverlayAutoLookup',
  subtitleOverlayBlur: 'subtitleOverlayBlur',
  subtitleOverlayAllTracks: 'subtitleOverlayAllTracks',
  subtitleHidden: 'subtitleHidden',
  videoShortcutPrevCue: 'videoShortcutPrevCue',
  videoShortcutNextCue: 'videoShortcutNextCue',
  videoShortcutReplayCue: 'videoShortcutReplayCue',
  videoShortcutTogglePanel: 'videoShortcutTogglePanel',
  videoShortcutToggleSubtitleHide: 'videoShortcutToggleSubtitleHide',
  videoShortcutOffsetMinus: 'videoShortcutOffsetMinus',
  videoShortcutOffsetPlus: 'videoShortcutOffsetPlus',
  videoShortcutOffsetReset: 'videoShortcutOffsetReset',
  videoShortcutCopyCue: 'videoShortcutCopyCue',
  videoShortcutRateDown: 'videoShortcutRateDown',
  videoShortcutRateUp: 'videoShortcutRateUp',
});
const shortcutKeys = Object.freeze(Object.values(toggleIds).filter((key) => key.startsWith('videoShortcut')));

let toastTimer = null;
function toast(message) {
  const el = $('status');
  if (!el) return;
  el.textContent = message;
  el.classList.add('is-visible');
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('is-visible'), 2600);
}

function runtimeMessage(message) {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendMessage(message, (response) => {
        try {
          if (chrome.runtime.lastError) return resolve(null);
        } catch (_) {
          return resolve(null);
        }
        resolve(response || null);
      });
    } catch (_) {
      resolve(null);
    }
  });
}

function effectivePort() {
  return parseInt($('port').value, 10) || Number(D.port) || 19633;
}

async function refreshConnection(force) {
  const card = $('connectionCard');
  const title = $('connTitle');
  const detail = $('connDetail');
  const endpoint = $('connEndpoint');
  const button = $('check');
  if (card) card.dataset.tone = 'loading';
  if (title) title.textContent = '正在检测…';
  if (detail) detail.textContent = '确认 Hibiki 的查词与字幕服务状态。';
  if (button) button.disabled = true;

  const response = await runtimeMessage({ type: 'connectionStatus', force: force === true });
  const connection = response && response.connection
    ? response.connection
    : { state: 'offline', port: effectivePort(), base: 'http://127.0.0.1:' + effectivePort() };
  const copy = self.FUSHI_CONNECTION.copy(connection.state, connection.port);
  if (card) card.dataset.tone = copy.tone;
  if (title) title.textContent = copy.title;
  if (detail) detail.textContent = copy.detail;
  if (endpoint) endpoint.textContent = connection.base || ('http://127.0.0.1:' + effectivePort());
  if (button) button.disabled = false;

  if (connection.state === self.FUSHI_CONNECTION.states.unauthorized ||
      connection.state === self.FUSHI_CONNECTION.states.wrongService) {
    $('advancedConnection').open = true;
  }
}

async function loadSettings() {
  $('host').placeholder = D.host || '127.0.0.1';
  $('port').placeholder = String(D.port || 19633);
  $('token').placeholder = D.token ? '已由 Hibiki 自动配置' : '';

  // 旧 subtitleHoverPause / videoShortcutsEnabled 只作一次向后兼容读取：
  // 新键已有显式值时永远优先；旧键不再由 UI 写入。
  const keys = ['host', 'port', 'token', 'subtitleHoverPause', 'videoShortcutsEnabled']
    .concat(Object.values(toggleIds));
  const saved = await chrome.storage.local.get(keys);
  if (saved.host != null && saved.host !== '') $('host').value = saved.host;
  if (saved.port != null && saved.port !== 0) $('port').value = saved.port;
  if (saved.token != null && saved.token !== '') $('token').value = saved.token;

  for (const [id, key] of Object.entries(toggleIds)) {
    const input = $(id);
    if (!input) continue;
    let value = saved[key];
    if (typeof value !== 'boolean' && key === 'subtitlePauseOnLookup') {
      value = saved.subtitleHoverPause;
    }
    if (typeof value !== 'boolean' && shortcutKeys.includes(key)) {
      value = saved.videoShortcutsEnabled;
    }
    input.checked = typeof value === 'boolean' ? value : settingDefaults[key];
    input.addEventListener('change', async () => {
      await chrome.storage.local.set({ [key]: input.checked });
      toast('已更新：' + input.closest('.setting-row').querySelector('strong').textContent);
    });
  }
}

$('connectionForm').addEventListener('submit', async (event) => {
  event.preventDefault();
  await chrome.storage.local.set({
    host: $('host').value.trim(),
    port: parseInt($('port').value, 10) || 0,
    token: $('token').value.trim(),
  });
  toast('连接设置已保存');
  await refreshConnection(true);
});

$('reset').addEventListener('click', async () => {
  await chrome.storage.local.set({ host: '', port: 0, token: '' });
  $('host').value = '';
  $('port').value = '';
  $('token').value = '';
  toast('已恢复 Hibiki 自动配置');
  await refreshConnection(true);
});

$('showToken').addEventListener('click', () => {
  const token = $('token');
  const visible = token.type === 'text';
  token.type = visible ? 'password' : 'text';
  $('showToken').textContent = visible ? '显示' : '隐藏';
});

$('check').addEventListener('click', () => refreshConnection(true));

// 「版本与更新」卡片：把自更新链路状态翻成人话（self-update.js describeUpdateState），
// 让「扩展怎么更新、现在是不是最新」在设置页一眼可见，不再只有失效时的角标。
async function refreshUpdateCard() {
  const titleEl = $('updTitle');
  const detailEl = $('updDetail');
  const buildEl = $('updBuild');
  if (!titleEl || !self.FUSHI_SELF_UPDATE) return;
  let stale = null;
  try {
    stale = (await chrome.storage.local.get('hibikiUpdateStale')).hibikiUpdateStale || null;
  } catch (_) { /* storage 不可用：按无 stale 渲染 */ }
  const s = self.FUSHI_SELF_UPDATE.describeUpdateState(self.FUSHI_DEFAULTS, stale);
  titleEl.textContent = '版本与更新 · ' + s.title;
  if (detailEl) detailEl.textContent = s.detail;
  if (buildEl) buildEl.textContent = s.build ? 'build ' + s.build : '';
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local') return;
  for (const [id, key] of Object.entries(toggleIds)) {
    if (!changes[key]) continue;
    const input = $(id);
    if (input) input.checked = changes[key].newValue === true;
  }
  if (changes.hibikiUpdateStale) refreshUpdateCard();
});

// BUG-1036：选项页每次打开都应报告当前真状态，不能复用 background 最多 5 秒的离线缓存；
// 手动“重新检测”本来就是 force=true，首次自动检测保持同一语义。
loadSettings().then(() => refreshConnection(true));
refreshUpdateCard();
