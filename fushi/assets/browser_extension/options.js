// Fushi 浏览器扩展设置：自动连接优先，用户覆盖与字幕偏好存 chrome.storage.local。
const $ = (id) => document.getElementById(id);
// options.html 与 options.js 任何一次不同步（改版删了控件、或旧 HTML 配新 JS）都会让 $()
// 返回 null；顶层直接 .addEventListener 一抛，它后面注册的所有卡片（版本与更新等）全部
// 不执行，整页静默变砖。统一走 on()：控件不在就跳过这一条绑定，其余照常。
const on = (id, type, handler) => {
  const el = $(id);
  if (el) el.addEventListener(type, handler);
  return el;
};
const D = self.FUSHI_DEFAULTS || { host: '127.0.0.1', port: 19633, token: '' };
// 界面文案统一走 i18n.js（fushiT）。
const tr = (key, params) => (typeof self.fushiT === 'function' ? self.fushiT(key, params) : key);
const settingDefaults = Object.freeze({
  // 按住 Shift 悬停查词（网页正文与侧边栏字幕行）。默认开；关掉只留点击等其余查词入口。
  shiftHoverLookup: true,
  netflixSubtitlePanel: false,
  subtitleOverlayEnabled: true,
  subtitleDragDropEnabled: true,
  subtitleAutoScroll: true,
  netflixHideNextEpisode: true,
  // 默认开启，对齐 app 侧 pauseOnLookup 默认 true（TODO-1108）；显式选择（含旧键）优先。
  subtitlePauseOnLookup: true,
  // 悬停查词离开字幕与弹窗即自动关窗续播（默认开，对齐 app 侧 resume_on_lookup_leave）。
  subtitleResumeOnLookupLeave: true,
  subtitleOverlayAutoLookup: false,
  // 侧边栏查词结果显示在网页上（默认开）：side panel 的 DOM 画不出面板边界，面板内的弹窗
  // 只能有面板那么宽；交给宿主页渲染才有完整空间。关掉则回到面板内那份窄弹窗。
  subtitleLookupOnPage: true,
  subtitleOverlayBlur: false,
  subtitleOverlayAllTracks: false,
  // 视频上字幕的半透明底板（默认开；关掉只剩描边字）。
  subtitleOverlayBackground: true,
  // 网页视频观看时长计入 Fushi 学习统计（视频域，首次覆盖口径）；
  // 具体什么情况才计由 studyTrackVideoCondition（selectSettings）决定。
  studyTrackVideo: true,
  // 用扩展预取的整集轨自绘整句字幕并藏掉站点原生字幕（默认关：改变站点观感的行为要用户点头）。
  subtitleReplaceNative: false,
  // 隐藏字幕是实际显示状态；Shift+H 是否接管由独立快捷键开关控制。
  subtitleHidden: false,
  // 触屏查词：点按默认开（手机端没有 Shift 悬停，点按是主入口），长按默认关
  // （与系统长按选词菜单天然打架）。两者都只在真触屏手势上生效，桌面零影响。
  touchLookupTap: true,
  touchLookupHold: false,
  // 安卓没有 chrome.sidePanel：触屏设备视频页边缘的「字幕列表」抽屉（mobile-drawer.js）。
  mobileSubtitleDrawer: true,
  // 播放器控制栏里的 Fushi 字幕按钮（player-controls.js）。关掉后视频页一个节点都不挂。
  playerControls: true,
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
  shiftHoverLookup: 'shiftHoverLookup',
  nfSubList: 'netflixSubtitlePanel',
  subtitleOverlayEnabled: 'subtitleOverlayEnabled',
  subtitleDragDropEnabled: 'subtitleDragDropEnabled',
  subtitleAutoScroll: 'subtitleAutoScroll',
  nfHideNext: 'netflixHideNextEpisode',
  subtitlePauseOnLookup: 'subtitlePauseOnLookup',
  subtitleResumeOnLookupLeave: 'subtitleResumeOnLookupLeave',
  subtitleOverlayAutoLookup: 'subtitleOverlayAutoLookup',
  subtitleLookupOnPage: 'subtitleLookupOnPage',
  subtitleOverlayBlur: 'subtitleOverlayBlur',
  subtitleOverlayAllTracks: 'subtitleOverlayAllTracks',
  subtitleOverlayBackground: 'subtitleOverlayBackground',
  studyTrackVideo: 'studyTrackVideo',
  subtitleReplaceNative: 'subtitleReplaceNative',
  subtitleHidden: 'subtitleHidden',
  touchLookupTap: 'touchLookupTap',
  touchLookupHold: 'touchLookupHold',
  mobileSubtitleDrawer: 'mobileSubtitleDrawer',
  playerControls: 'playerControls',
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
// 下拉型设置：控件 id → 存储键 → 默认值。主题（theme.js 读）与语言（i18n.js 读）。
const selectSettings = Object.freeze({
  extensionTheme: { key: 'extensionTheme', fallback: 'auto' },
  extensionLanguage: { key: 'extensionLanguage', fallback: 'app' },
  // 网页视频计入沉浸时间的条件（study-tracker.js 的字幕门）：
  // fushiSubtitle = 正在用 Fushi / 外挂字幕（默认）；anySubtitle = 这个视频有字幕轨即可；
  // always = 旧行为，任何正片都计。
  studyTrackVideoCondition: { key: 'studyTrackVideoCondition', fallback: 'fushiSubtitle' },
});

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
  if (title) title.textContent = tr('opt_connTitle_heading');
  if (detail) detail.textContent = tr('opt_connDetail_text');
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
  $('token').placeholder = D.token ? tr('opt_token_auto_placeholder') : '';

  // 旧 subtitleHoverPause / videoShortcutsEnabled 只作一次向后兼容读取：
  // 新键已有显式值时永远优先；旧键不再由 UI 写入。
  const keys = ['host', 'port', 'token', 'subtitleHoverPause', 'videoShortcutsEnabled',
    'popupSizeFromApp'].concat(Object.values(toggleIds))
    .concat(Object.values(selectSettings).map((s) => s.key));
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
      toast(tr('opt_toast_updated', { name: input.closest('.setting-row').querySelector('strong').textContent }));
    });
  }
  for (const [id, spec] of Object.entries(selectSettings)) {
    const select = $(id);
    if (!select) continue;
    const value = saved[spec.key];
    const known = Array.from(select.options).some((o) => o.value === value);
    select.value = known ? value : spec.fallback;
    select.addEventListener('change', async () => {
      await chrome.storage.local.set({ [spec.key]: select.value });
      toast(tr('opt_toast_updated', { name: select.closest('.setting-row').querySelector('strong').textContent }));
    });
  }
  await loadPopupSize(saved);
}

// ── 查词框大小 ──
// 尺寸真相源是 app 的 `extension_popup_max_width/height` 偏好；写入口只有一条
// `POST /api/extension/popup-size`（弹窗拖拽把手、侧边栏拖拽把手、这里三处共用，
// background.js 的 'popupSize' 消息就是它）。**这里绝不在扩展本地另存一份尺寸**——
// 那会变成第二个真相源，用户在 app 设置页调完发现不生效。
// 回显值来自 content.js 在每次查词时镜像下来的 `popupSizeFromApp`（只读，不参与决策）。
const popupSizeIds = Object.freeze(['popupSizeWidth', 'popupSizeHeight']);

function fillPopupSizeInputs(mirror) {
  const m = mirror && typeof mirror === 'object' ? mirror : null;
  const w = $('popupSizeWidth');
  const h = $('popupSizeHeight');
  // 输入框正被编辑时不覆盖用户正在打的字（镜像会随每次查词更新）。
  if (w && document.activeElement !== w) w.value = m && m.width > 0 ? String(Math.round(m.width)) : '';
  if (h && document.activeElement !== h) h.value = m && m.height > 0 ? String(Math.round(m.height)) : '';
}

async function submitPopupSize() {
  const size = fushiClampPopupSize($('popupSizeWidth').value, $('popupSizeHeight').value);
  if (!size) {
    // 两个都得有值才能提交（端点契约是 {maxWidth, maxHeight} 一对）。清空 = 不改。
    return;
  }
  $('popupSizeWidth').value = String(size.width);   // 让用户当场看到被夹住的值
  $('popupSizeHeight').value = String(size.height);
  const resp = await runtimeMessage(
    { type: 'popupSize', maxWidth: size.width, maxHeight: size.height });
  if (resp && resp.ok) {
    toast(tr('opt_toast_popup_size_saved'));
  } else {
    toast(tr('opt_toast_popup_size_not_saved'));
  }
}

async function loadPopupSize(saved) {
  const store = saved && Object.prototype.hasOwnProperty.call(saved, 'popupSizeFromApp')
    ? saved
    : await chrome.storage.local.get(['popupSizeFromApp']);
  fillPopupSizeInputs(store.popupSizeFromApp);
  for (const id of popupSizeIds) {
    // change（失焦/回车）而非 input：边打字边发请求会把「4」当成 4px 提交上去。
    on(id, 'change', submitPopupSize);
  }
}

on('connectionForm', 'submit', async (event) => {
  event.preventDefault();
  await chrome.storage.local.set({
    host: $('host').value.trim(),
    port: parseInt($('port').value, 10) || 0,
    token: $('token').value.trim(),
  });
  toast(tr('opt_toast_connection_saved'));
  await refreshConnection(true);
});

on('reset', 'click', async () => {
  await chrome.storage.local.set({ host: '', port: 0, token: '' });
  $('host').value = '';
  $('port').value = '';
  $('token').value = '';
  toast(tr('opt_toast_auto_config_restored'));
  await refreshConnection(true);
});

// 覆盖层位置：拖过的位置存 subtitleOverlayPosition（视频分数坐标）；删键即回默认（居中、底锚 88%），
// 已打开的视频页经 storage.onChanged 立刻重摆。
on('resetSubtitleOverlayPosition', 'click', async () => {
  await chrome.storage.local.remove('subtitleOverlayPosition');
  toast(tr('opt_toast_overlay_position_reset'));
});

on('showToken', 'click', () => {
  const token = $('token');
  const visible = token.type === 'text';
  token.type = visible ? 'password' : 'text';
  $('showToken').textContent = tr(visible ? 'opt_showToken_button' : 'opt_hideToken_button');
});

on('check', 'click', () => refreshConnection(true));

let lookupPerfRawLogs = [];

function formatLookupPerfValue(key, value) {
  if (typeof value === 'number') {
    if (key.endsWith('Ms') || key === 'renderMs' || key === 'sinceRequestMs') return value + 'ms';
    if (key === 'responseChars') return Math.round(value / 1024) + 'K chars';
    if (key === 'responseBytes') return Math.round(value / 1024) + 'KiB';
  }
  return String(value);
}

function formatLookupPerfLog(item) {
  const ignored = new Set([
    'at', 'id', 'surface', 'stage', 'term', 'termLength', 'maximumTerms',
    'responseReadyEpochMs',
  ]);
  const time = item.at ? new Date(item.at).toLocaleTimeString([], { hour12: false }) : '--:--:--';
  const parts = [];
  for (const [key, value] of Object.entries(item || {})) {
    if (ignored.has(key) || value == null || value === '') continue;
    parts.push(key + '=' + formatLookupPerfValue(key, value));
  }
  return time + ' [' + String(item.id || '-') + '] ' +
    String(item.surface || '-') + '/' + String(item.stage || '-') +
    (Number.isFinite(item.termLength) ? ' len=' + item.termLength : '') +
    (parts.length ? '\n  ' + parts.join(' · ') : '');
}

async function refreshLookupPerfLogs() {
  const output = $('lookupPerfOutput');
  const summary = $('lookupPerfSummary');
  if (output) output.textContent = tr('opt_perf_reading');
  const response = await runtimeMessage({ type: 'lookupPerfGet' });
  lookupPerfRawLogs = response && Array.isArray(response.logs) ? response.logs : [];
  if (summary) summary.textContent = lookupPerfRawLogs.length
    ? tr('opt_perf_recorded', { n: lookupPerfRawLogs.length })
    : tr('opt_lookupPerfSummary_desc');
  if (!output) return;
  output.textContent = lookupPerfRawLogs.length
    ? lookupPerfRawLogs.map(formatLookupPerfLog).join('\n\n')
    : tr('opt_lookupPerfOutput_text');
  output.scrollTop = output.scrollHeight;
}

on('lookupPerfPanel', 'toggle', () => {
  if ($('lookupPerfPanel').open) refreshLookupPerfLogs();
});

on('refreshLookupPerf', 'click', refreshLookupPerfLogs);

on('copyLookupPerf', 'click', async () => {
  try {
    await navigator.clipboard.writeText(JSON.stringify(lookupPerfRawLogs, null, 2));
    toast(tr('opt_toast_perf_copied'));
  } catch (_) {
    toast(tr('opt_toast_perf_copy_failed'));
  }
});

on('clearLookupPerf', 'click', async () => {
  const response = await runtimeMessage({ type: 'lookupPerfClear' });
  if (!response || response.ok !== true) {
    toast(tr('opt_toast_perf_clear_failed'));
    return;
  }
  lookupPerfRawLogs = [];
  const clearedOutput = $('lookupPerfOutput');
  if (clearedOutput) clearedOutput.textContent = tr('opt_lookupPerfOutput_text');
  const clearedSummary = $('lookupPerfSummary');
  if (clearedSummary) clearedSummary.textContent = tr('opt_lookupPerfSummary_desc');
  toast(tr('opt_toast_perf_cleared'));
});

// 「版本与更新」卡片：把自更新链路状态翻成人话（self-update.js describeUpdateState），
// 让「扩展怎么更新、现在是不是最新」在设置页一眼可见，不再只有失效时的角标。
async function refreshUpdateCard() {
  const titleEl = $('updTitle');
  const detailEl = $('updDetail');
  const buildEl = $('updBuild');
  if (!titleEl || !self.FUSHI_SELF_UPDATE) return;
  let stale = null;
  try {
    stale = (await chrome.storage.local.get('fushiUpdateStale')).fushiUpdateStale || null;
  } catch (_) { /* storage 不可用：按无 stale 渲染 */ }
  const s = self.FUSHI_SELF_UPDATE.describeUpdateState(self.FUSHI_DEFAULTS, stale);
  titleEl.textContent = tr('opt_updTitle_title') + ' · ' + s.title;
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
  for (const [id, spec] of Object.entries(selectSettings)) {
    if (!changes[spec.key]) continue;
    const select = $(id);
    if (select) select.value = changes[spec.key].newValue || spec.fallback;
  }
  if (changes.popupSizeFromApp) fillPopupSizeInputs(changes.popupSizeFromApp.newValue);
  if (changes.fushiUpdateStale) refreshUpdateCard();
});

// BUG-1036：选项页每次打开都应报告当前真状态，不能复用 background 最多 5 秒的离线缓存；
// 手动“重新检测”本来就是 force=true，首次自动检测保持同一语义。
loadSettings().then(() => refreshConnection(true));
refreshUpdateCard();

// ── 配色主题（与 Fushi 本体同一套：跟随 Fushi / 预设 / 自定义，见 theme-palette.js / theme.js）──
// 选中项写 extensionPalette；自定义主题列表写 extensionCustomThemes（每项 {id, name, seed,
// surface, text, neutral}）。编辑器里每一次输入都直接落库——theme.js 的 storage 监听立刻把整页
// 重着色，所见即所得；不设「保存」按钮（与 app 的自定义主题页一致）。
const PALETTE = self.fushiThemePalette || null;
const THEME = self.fushiTheme || null;
let paletteState = { palette: 'fushi', customThemes: [], appMirror: null };

function paletteLabel(id) {
  if (id === 'app') return tr('theme_palette_app');
  if (id.indexOf('custom:') === 0) {
    const t = paletteState.customThemes.find((x) => 'custom:' + x.id === id);
    return (t && t.name) || tr('theme_custom_untitled');
  }
  const p = PALETTE && PALETTE.presetFor(id);
  return p ? tr(p.labelKey) : id;
}

// 一颗色块的两个示意色：主色 + 表面色（当前明暗下）。
function swatchColors(id) {
  if (!PALETTE || !THEME) return null;
  const scheme = THEME.resolve();
  let tokens = null;
  if (id === 'app') {
    tokens = PALETTE.tokensFromAppTheme(paletteState.appMirror && paletteState.appMirror[scheme]);
    if (!tokens) return null;
  } else if (id === 'fushi') {
    tokens = null;
  } else {
    const spec = PALETTE.specFor(id, paletteState.customThemes);
    tokens = spec ? PALETTE.derive(spec, scheme) : null;
  }
  if (!tokens) {
    // 默认绿：theme.css 的值经计算样式取，色块与页面同源。
    const cs = getComputedStyle(document.documentElement);
    return { primary: cs.getPropertyValue('--fushi-primary').trim(), surface: cs.getPropertyValue('--fushi-surface').trim() };
  }
  return { primary: tokens['--fushi-primary'], surface: tokens['--fushi-surface'] };
}

function renderPaletteGrid() {
  const grid = $('paletteGrid');
  if (!grid || !PALETTE) return;
  const ids = ['app', 'fushi'].concat(PALETTE.PRESETS.filter((p) => p.key !== 'fushi').map((p) => p.key))
    .concat(paletteState.customThemes.map((t) => 'custom:' + t.id));
  grid.textContent = '';
  for (const id of ids) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'palette-swatch';
    btn.dataset.palette = id;
    btn.setAttribute('role', 'radio');
    const selected = id === paletteState.palette;
    btn.setAttribute('aria-checked', selected ? 'true' : 'false');
    if (selected) btn.classList.add('is-selected');
    const dot = document.createElement('span');
    dot.className = 'palette-dot';
    const colors = swatchColors(id);
    if (colors) {
      dot.style.setProperty('--swatch-primary', colors.primary);
      dot.style.setProperty('--swatch-surface', colors.surface);
    } else {
      dot.classList.add('is-pending');
    }
    const name = document.createElement('span');
    name.className = 'palette-name';
    name.textContent = paletteLabel(id);
    btn.appendChild(dot);
    btn.appendChild(name);
    if (id === 'app' && !colors) btn.title = tr('theme_palette_app_pending');
    btn.addEventListener('click', () => selectPalette(id));
    grid.appendChild(btn);
  }
  const add = document.createElement('button');
  add.type = 'button';
  add.className = 'palette-swatch palette-add';
  add.id = 'paletteAdd';
  const plus = document.createElement('span');
  plus.className = 'palette-dot';
  plus.textContent = '+';
  const label = document.createElement('span');
  label.className = 'palette-name';
  label.textContent = tr('theme_custom_new');
  add.appendChild(plus);
  add.appendChild(label);
  add.addEventListener('click', createCustomTheme);
  grid.appendChild(add);
  renderCustomThemeEditor();
}

async function selectPalette(id) {
  if (!PALETTE) return;
  const patch = { extensionPalette: PALETTE.normalizePaletteId(id) };
  // 自带明暗的预设（app 里选预设时 brightness 回落到预设的出厂明暗）：一并切明暗。
  const preset = PALETTE.presetFor(id);
  if (preset && preset.brightness) patch.extensionTheme = preset.brightness;
  await chrome.storage.local.set(patch);
  toast(tr('opt_toast_updated', { name: paletteLabel(patch.extensionPalette) }));
}

function currentCustomTheme() {
  const id = paletteState.palette;
  if (id.indexOf('custom:') !== 0) return null;
  return paletteState.customThemes.find((t) => 'custom:' + t.id === id) || null;
}

async function createCustomTheme() {
  if (!PALETTE) return;
  const base = currentCustomTheme();
  const entry = PALETTE.normalizeCustomTheme({
    id: PALETTE.newThemeId(),
    name: base ? (base.name || tr('theme_custom_untitled')) + ' 2' : '',
    seed: base ? base.seed : PALETTE.DEFAULT_SEED,
    surface: base ? base.surface : null,
    text: base ? base.text : null,
    neutral: base ? base.neutral : false,
  });
  const list = paletteState.customThemes.concat([entry]);
  await chrome.storage.local.set({ extensionCustomThemes: list, extensionPalette: 'custom:' + entry.id });
  toast(tr('theme_custom_created'));
  const name = $('customThemeName');
  if (name) name.focus();
}

async function deleteCustomTheme() {
  const cur = currentCustomTheme();
  if (!cur) return;
  if (!confirm(tr('theme_custom_delete_confirm', { name: cur.name || tr('theme_custom_untitled') }))) return;
  const list = paletteState.customThemes.filter((t) => t.id !== cur.id);
  await chrome.storage.local.set({ extensionCustomThemes: list, extensionPalette: 'fushi' });
  toast(tr('theme_custom_deleted'));
}

// 编辑器控件 → 当前自定义主题条目；每次输入直接落库。
let customThemeWriteTimer = null;
function writeCustomThemeFromEditor() {
  const cur = currentCustomTheme();
  if (!cur || !PALETTE) return;
  const next = PALETTE.normalizeCustomTheme({
    id: cur.id,
    name: $('customThemeName').value,
    seed: $('customThemeSeed').value,
    surface: $('customThemeSurfaceAuto').checked ? null : $('customThemeSurface').value,
    text: $('customThemeTextAuto').checked ? null : $('customThemeText').value,
    neutral: $('customThemeNeutral').checked,
  });
  const list = paletteState.customThemes.map((t) => (t.id === cur.id ? next : t));
  // 本地先行：预览立刻跟手，落库合并到下一拍（颜色拾取器拖动时事件很密）。
  paletteState.customThemes = list;
  renderCustomThemePreview(next);
  if (customThemeWriteTimer) clearTimeout(customThemeWriteTimer);
  customThemeWriteTimer = setTimeout(() => {
    customThemeWriteTimer = null;
    chrome.storage.local.set({ extensionCustomThemes: list });
  }, 120);
}

function renderCustomThemePreview(entry) {
  const wrap = $('customThemePreview');
  if (!wrap || !PALETTE) return;
  for (const box of wrap.querySelectorAll('.theme-preview')) {
    const tokens = PALETTE.derive(entry, box.dataset.scheme);
    for (const k in tokens) box.style.setProperty(k, tokens[k]);
  }
}

function renderCustomThemeEditor() {
  const editor = $('customThemeEditor');
  if (!editor) return;
  const cur = currentCustomTheme();
  if (!cur) { editor.hidden = true; return; }
  editor.hidden = false;
  const focused = document.activeElement;
  const setIfIdle = (el, value) => { if (el && el !== focused) el.value = value; };
  setIfIdle($('customThemeName'), cur.name);
  setIfIdle($('customThemeSeed'), cur.seed);
  const surfaceAuto = !cur.surface;
  $('customThemeSurfaceAuto').checked = surfaceAuto;
  $('customThemeSurface').disabled = surfaceAuto;
  setIfIdle($('customThemeSurface'), cur.surface || PALETTE.derive(cur, THEME ? THEME.resolve() : 'light')['--fushi-bg']);
  const textAuto = !cur.text;
  $('customThemeTextAuto').checked = textAuto;
  $('customThemeText').disabled = textAuto;
  setIfIdle($('customThemeText'), cur.text || PALETTE.derive(cur, THEME ? THEME.resolve() : 'light')['--fushi-text']);
  $('customThemeNeutral').checked = cur.neutral === true;
  renderCustomThemePreview(cur);
}

function bindCustomThemeEditor() {
  if (!$('customThemeEditor')) return;
  on('customThemeName', 'input', writeCustomThemeFromEditor);
  on('customThemeSeed', 'input', writeCustomThemeFromEditor);
  on('customThemeSurface', 'input', writeCustomThemeFromEditor);
  on('customThemeText', 'input', writeCustomThemeFromEditor);
  on('customThemeNeutral', 'change', writeCustomThemeFromEditor);
  on('customThemeSurfaceAuto', 'change', () => {
    $('customThemeSurface').disabled = $('customThemeSurfaceAuto').checked;
    writeCustomThemeFromEditor();
  });
  on('customThemeTextAuto', 'change', () => {
    $('customThemeText').disabled = $('customThemeTextAuto').checked;
    writeCustomThemeFromEditor();
  });
  on('customThemeDuplicate', 'click', createCustomTheme);
  on('customThemeDelete', 'click', deleteCustomTheme);
}

async function loadPalette() {
  if (!PALETTE) return;
  const saved = await chrome.storage.local.get(['extensionPalette', 'extensionCustomThemes', 'appThemeMirror']);
  paletteState = {
    palette: PALETTE.normalizePaletteId(saved.extensionPalette),
    customThemes: PALETTE.normalizeCustomThemes(saved.extensionCustomThemes),
    appMirror: saved.appThemeMirror && typeof saved.appThemeMirror === 'object' ? saved.appThemeMirror : null,
  };
  bindCustomThemeEditor();
  renderPaletteGrid();
  // 明暗切换后色块要按新明暗重画（theme.js 已在 storage 变化后 notify）。
  if (THEME && typeof THEME.onChange === 'function') THEME.onChange(() => renderPaletteGrid());
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !PALETTE) return;
  let dirty = false;
  if (changes.extensionPalette) { paletteState.palette = PALETTE.normalizePaletteId(changes.extensionPalette.newValue); dirty = true; }
  if (changes.extensionCustomThemes) { paletteState.customThemes = PALETTE.normalizeCustomThemes(changes.extensionCustomThemes.newValue); dirty = true; }
  if (changes.appThemeMirror) { paletteState.appMirror = changes.appThemeMirror.newValue || null; dirty = true; }
  if (dirty) renderPaletteGrid();
});

// ── 字幕外观（subtitle-style.js：字体 / 大小 / 字重 / 间距 / 行高 / 对齐 / 颜色 / 描边 / 底板）──
// 设置整体存 chrome.storage.local.subtitleStyle；控件 id → 字段名。预览与视频上的覆盖层走同一份
// toCssVars（预览节点的默认值在 options.css 里与 content-css-overlay.css 同一组 --fushi-sub-*）。
const SUB = self.fushiSubtitleStyle || null;
const subtitleStyleFields = Object.freeze({
  subtitleStyleFontFamily: { field: 'fontFamily', kind: 'font' },
  subtitleStyleFontScale: { field: 'fontScale', kind: 'range' },
  subtitleStyleFontWeight: { field: 'fontWeight', kind: 'select' },
  subtitleStyleLetterSpacing: { field: 'letterSpacing', kind: 'range' },
  subtitleStyleLineHeight: { field: 'lineHeight', kind: 'range' },
  subtitleStyleTextAlign: { field: 'textAlign', kind: 'select' },
  subtitleStyleTextColor: { field: 'textColor', kind: 'color' },
  subtitleStyleShadow: { field: 'shadow', kind: 'select' },
  subtitleStyleBackgroundColor: { field: 'backgroundColor', kind: 'color' },
  subtitleStyleBackgroundOpacity: { field: 'backgroundOpacity', kind: 'range' },
  subtitleStyleBorderRadius: { field: 'borderRadius', kind: 'range' },
  subtitleStylePadding: { field: 'padding', kind: 'range' },
  subtitleStyleBoxWidth: { field: 'boxWidth', kind: 'range' },
  subtitleStyleBoxHeight: { field: 'boxHeight', kind: 'range' },
  subtitleStyleBoxAutoFit: { field: 'boxAutoFit', kind: 'check' },
});
// 颜色控件的「跟随主题」态：<input type=color> 没有空值，这里用 data-auto 记住并显示主题默认色。
const subtitleColorDefaults = SUB ? {
  subtitleStyleTextColor: SUB.DEFAULT_TEXT_COLOR,
  subtitleStyleBackgroundColor: SUB.DEFAULT_BACKGROUND_COLOR,
} : {};
let subtitleStyleCurrent = SUB ? SUB.normalize(null) : null;

function formatRangeOutput(id, value) {
  const out = document.querySelector('output[for="' + id + '"]');
  if (!out) return;
  const unit = out.dataset.unit || '';
  // data-zero：0 有专门含义（底板宽 / 高的「随内容」），显示文案而不是「0%」。
  if (out.dataset.zero && Number(value) === 0) out.textContent = tr(out.dataset.zero);
  else if (unit === 'em') out.textContent = (Number(value) / 100).toFixed(2) + ' em';
  else out.textContent = String(value) + unit;
}

// 底板宽 / 高落到预览节点：预览舞台的盒充当「视频盒」（覆盖层按 video 盒同一算法 applyBox）。
// 舞台宽随窗口变，所以窗口 resize 也要重算一次。
function applySubtitlePreviewBox() {
  if (!SUB) return;
  const preview = $('subtitleStylePreviewCue');
  const stage = $('subtitleStylePreview');
  if (!preview || !stage) return;
  const frame = typeof stage.getBoundingClientRect === 'function' ? stage.getBoundingClientRect() : null;
  SUB.applyBox(preview, subtitleStyleCurrent, frame);
  // 自适应缩放也进预览：预览与网页覆盖层共用 fitTextInto，所见即所得（否则用户在这里调好
  // 的底板大小，到了视频上字号又是另一回事）。
  if (typeof SUB.fitTextInto === 'function') {
    SUB.fitTextInto(preview, preview.firstElementChild || preview, subtitleStyleCurrent, frame);
  }
}

function fillSubtitleStyleInputs(style) {
  if (!SUB) return;
  const s = SUB.normalize(style);
  subtitleStyleCurrent = s;
  const focused = document.activeElement;
  for (const [id, spec] of Object.entries(subtitleStyleFields)) {
    const el = $(id);
    if (!el) continue;
    const v = s[spec.field];
    if (spec.kind === 'color') {
      const auto = !v;
      el.dataset.auto = auto ? '1' : '0';
      if (el !== focused) el.value = auto ? subtitleColorDefaults[id] : v;
      const reset = $(id + 'Reset');
      if (reset) reset.disabled = auto;
      continue;
    }
    // 字体下拉的选项集随字体库变化，回显交给 fillFontFamilySelect（当前值不在任何组里会挂到「自定义」组）。
    if (spec.kind === 'font') { fillFontFamilySelect(); continue; }
    if (spec.kind === 'check') { el.checked = !!v; continue; }
    if (el !== focused) el.value = String(v);
    if (spec.kind === 'range') formatRangeOutput(id, v);
  }
  const preview = $('subtitleStylePreviewCue');
  if (preview) {
    SUB.applyTo(preview, s);
    applySubtitlePreviewBox();
    // 底板开关同步进预览（与覆盖层 data-bare 同义）。
    const bg = $('subtitleOverlayBackground');
    if (bg) { if (bg.checked) preview.removeAttribute('data-bare'); else preview.setAttribute('data-bare', ''); }
  }
}

function readSubtitleStyleInputs() {
  const out = Object.assign({}, subtitleStyleCurrent || {});
  for (const [id, spec] of Object.entries(subtitleStyleFields)) {
    const el = $(id);
    if (!el) continue;
    if (spec.kind === 'color') { out[spec.field] = el.dataset.auto === '1' ? '' : el.value; continue; }
    if (spec.kind === 'check') { out[spec.field] = !!el.checked; continue; }
    out[spec.field] = el.value;
  }
  return SUB.normalize(out);
}

let subtitleStyleWriteTimer = null;
function writeSubtitleStyle(immediate) {
  if (!SUB) return;
  const s = readSubtitleStyleInputs();
  fillSubtitleStyleInputs(s);
  if (subtitleStyleWriteTimer) clearTimeout(subtitleStyleWriteTimer);
  const commit = () => {
    subtitleStyleWriteTimer = null;
    if (SUB.isDefault(s)) chrome.storage.local.remove('subtitleStyle');
    else chrome.storage.local.set({ subtitleStyle: s });
  };
  if (immediate) commit(); else subtitleStyleWriteTimer = setTimeout(commit, 120);
}

// ── 字体下拉 + Fushi 字体库（用户 2026-09-20：「不要手填而是下拉框并且可以下载字体」）──
// 下拉三组：本机字体栈（FONT_SUGGESTIONS）/ Fushi 字体库（app /api/extension/fonts 的目录字体，
// 值 = `"family"`，网页覆盖层经 @font-face 挂进去）/ 自定义（只为回显旧版手填过的值，用户换了就消失）。
// 字体库列表 = app 的推荐字体表，未安装的一键下载（app 自己跑多源回退下载并入目录，与 app 内视频字幕共用）。
const fontLibrary = { fonts: [], recommended: [], online: false, fetchedAt: 0, pending: new Set() };

function fillFontFamilySelect() {
  const sel = $('subtitleStyleFontFamily');
  if (!sel || !SUB) return;
  const current = subtitleStyleCurrent ? subtitleStyleCurrent.fontFamily : '';
  const sys = $('subtitleFontSystemGroup');
  const fushi = $('subtitleFontFushiGroup');
  const custom = $('subtitleFontCustomGroup');
  if (!sys || !fushi || !custom) return;
  sys.label = tr('opt_subtitleStyleFontFamily_group_system');
  fushi.label = tr('opt_subtitleStyleFontFamily_group_fushi');
  custom.label = tr('opt_subtitleStyleFontFamily_group_custom');
  sys.textContent = ''; fushi.textContent = ''; custom.textContent = '';
  let matched = current === '';
  for (const stack of SUB.FONT_SUGGESTIONS) {
    const o = document.createElement('option');
    o.value = stack;
    o.textContent = SUB.fontStackLabel(stack);
    if (stack === current) { o.selected = true; matched = true; }
    sys.appendChild(o);
  }
  for (const f of fontLibrary.fonts) {
    const value = SUB.fontFamilyValueOf(f.family);
    if (!value) continue;
    const o = document.createElement('option');
    o.value = value;
    o.textContent = f.name || f.family;
    if (SUB.matchesFushiFont(current, f.family)) { o.selected = true; matched = true; }
    fushi.appendChild(o);
  }
  fushi.hidden = fushi.childElementCount === 0;
  if (!matched) {
    const o = document.createElement('option');
    o.value = current;
    o.textContent = current;
    o.selected = true;
    custom.appendChild(o);
  }
  custom.hidden = custom.childElementCount === 0;
  if (matched && current === '') sel.value = '';
}

function renderFontLibrary() {
  const list = $('subtitleFontLibraryList');
  const note = $('subtitleFontLibraryNote');
  if (!list || !note) return;
  note.hidden = fontLibrary.online;
  list.textContent = '';
  if (!fontLibrary.online) return;
  for (const rec of fontLibrary.recommended) {
    const li = document.createElement('li');
    li.className = 'font-library-item';
    const copy = document.createElement('span');
    copy.className = 'font-library-copy';
    const name = document.createElement('strong');
    name.textContent = rec.name + (rec.nameJa && rec.nameJa !== rec.name ? ' · ' + rec.nameJa : '');
    const meta = document.createElement('small');
    meta.textContent = [rec.description, rec.license].filter(Boolean).join(' · ');
    copy.appendChild(name); copy.appendChild(meta);
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'text-button';
    const pending = fontLibrary.pending.has(rec.name);
    btn.disabled = rec.installed || pending;
    btn.textContent = tr(rec.installed ? 'opt_subtitleFontLibrary_installed'
      : pending ? 'opt_subtitleFontLibrary_downloading' : 'opt_subtitleFontLibrary_download');
    if (!rec.installed && !pending) btn.addEventListener('click', () => downloadLibraryFont(rec.name));
    li.appendChild(copy); li.appendChild(btn);
    list.appendChild(li);
  }
}

async function refreshFontLibrary(force) {
  if (!SUB || !$('subtitleStyleFontFamily')) return;
  if (!force && Date.now() - fontLibrary.fetchedAt < 10000) return;
  fontLibrary.fetchedAt = Date.now();
  const resp = await runtimeMessage({ type: 'subtitleFonts' });
  fontLibrary.online = !!(resp && resp.ok);
  fontLibrary.fonts = fontLibrary.online && Array.isArray(resp.fonts) ? resp.fonts : [];
  fontLibrary.recommended = fontLibrary.online && Array.isArray(resp.recommended) ? resp.recommended : [];
  // 预览块要真画出库字体：与网页覆盖层同一份 @font-face（subtitle-panel.js 注入的那份）。
  const css = SUB.fontFaceCss(fontLibrary.fonts);
  let faces = $('subtitleFontFaces');
  if (!faces) {
    faces = document.createElement('style');
    faces.id = 'subtitleFontFaces';
    document.head.appendChild(faces);
  }
  if (faces.textContent !== css) faces.textContent = css;
  fillFontFamilySelect();
  renderFontLibrary();
}

async function downloadLibraryFont(name) {
  if (fontLibrary.pending.has(name)) return;
  fontLibrary.pending.add(name);
  renderFontLibrary();
  const resp = await runtimeMessage({ type: 'subtitleFontDownload', name });
  fontLibrary.pending.delete(name);
  if (!resp || !resp.ok) {
    toast(tr('opt_toast_font_download_failed', { name, error: (resp && resp.error) || 'offline' }));
    renderFontLibrary();
    return;
  }
  await refreshFontLibrary(true);
  // 下载完就选中它（用户点下载的意图就是用它）：用 app 回的条目 family，没有就按同名找目录。
  const added = Array.isArray(resp.fonts) && resp.fonts.length ? resp.fonts[0]
    : fontLibrary.fonts.find((f) => f.name === name);
  const value = added ? SUB.fontFamilyValueOf(added.family) : '';
  const sel = $('subtitleStyleFontFamily');
  if (value && sel) {
    fillFontFamilySelect();
    sel.value = value;
    writeSubtitleStyle(true);
  }
  toast(tr('opt_toast_font_downloaded', { name }));
}

async function loadSubtitleStyle() {
  if (!SUB || !$('subtitleStylePreviewCue')) return;
  const saved = await chrome.storage.local.get(['subtitleStyle']);
  fillSubtitleStyleInputs(saved.subtitleStyle);
  refreshFontLibrary(true);
  // 展开下拉前刷一次清单（app 可能刚启动 / 刚在 app 里加了字体）；10s 内不重复拉。
  on('subtitleStyleFontFamily', 'focus', () => { refreshFontLibrary(false); });
  // 换语言：optgroup 标签与列表按钮文案是 JS 写的，不经 data-i18n，自己重绘。
  if (self.fushiI18n && typeof self.fushiI18n.onChange === 'function') {
    self.fushiI18n.onChange(() => { fillSubtitleStyleInputs(subtitleStyleCurrent); renderFontLibrary(); });
  }
  for (const [id, spec] of Object.entries(subtitleStyleFields)) {
    const el = $(id);
    if (!el) continue;
    if (spec.kind === 'color') {
      el.addEventListener('input', () => { el.dataset.auto = '0'; writeSubtitleStyle(false); });
      el.addEventListener('change', () => { el.dataset.auto = '0'; writeSubtitleStyle(true); });
      on(id + 'Reset', 'click', () => { el.dataset.auto = '1'; writeSubtitleStyle(true); });
      continue;
    }
    el.addEventListener('input', () => writeSubtitleStyle(false));
    el.addEventListener('change', () => {
      writeSubtitleStyle(true);
      // 松手后把滑杆对齐到夹过的值：拖动中 fill 不碰有焦点的控件，底板宽 / 高有「非 0 下限」
      // （5% → 20%），不对齐的话滑杆停在 5、文案却是 20%。
      if (spec.kind === 'range' && subtitleStyleCurrent) el.value = String(subtitleStyleCurrent[spec.field]);
      toast(tr('opt_toast_updated', { name: el.closest('.setting-row').querySelector('strong').textContent }));
    });
  }
  on('subtitleOverlayBackground', 'change', () => fillSubtitleStyleInputs(subtitleStyleCurrent));
  window.addEventListener('resize', applySubtitlePreviewBox);
  on('resetSubtitleStyle', 'click', async () => {
    await chrome.storage.local.remove('subtitleStyle');
    fillSubtitleStyleInputs(null);
    toast(tr('opt_toast_subtitle_style_reset'));
  });
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !SUB) return;
  if (changes.subtitleStyle) fillSubtitleStyleInputs(changes.subtitleStyle.newValue);
  if (changes.subtitleOverlayBackground) fillSubtitleStyleInputs(subtitleStyleCurrent);
});

loadPalette();
loadSubtitleStyle();
