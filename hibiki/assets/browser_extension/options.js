// TODO-1087：options 页显示「当前生效」的 host/port/token。
// 生效值 = chrome.storage.local 手动覆盖（若有） > hibiki-defaults.js 内置默认（app 注入的真值）。
// 输入框留空即回落默认（保存时把空值写回，cfg() 便走默认），无需用户记住原始端口。
const $ = (id) => document.getElementById(id);
const D = (self.HIBIKI_DEFAULTS) || { host: '127.0.0.1', port: 19633, token: '' };

// placeholder 显示 app 注入的自动配置默认，提示用户「留空即用这个」。
$('host').placeholder = D.host || '127.0.0.1';
$('port').placeholder = String(D.port || 19633);
$('token').placeholder = D.token ? '(auto-configured)' : '';

chrome.storage.local.get(['host', 'port', 'token']).then((c) => {
  // 只在用户曾手动覆盖过时回填输入框；否则留空，靠 placeholder 展示默认。
  if (c.host != null && c.host !== '') $('host').value = c.host;
  if (c.port != null && c.port !== 0) $('port').value = c.port;
  if (c.token != null && c.token !== '') $('token').value = c.token;
});

$('save').onclick = async () => {
  await chrome.storage.local.set({
    host: $('host').value.trim(),
    port: parseInt($('port').value, 10) || 0,
    token: $('token').value.trim(),
  });
  $('status').textContent = ' Saved';
};

// TODO-1219：Netflix 整集字幕列表面板开关（默认关）。这是纯 UI 偏好，独立于 host/port/token 的
// 自动配置——存在 chrome.storage.local 的 netflixSubtitlePanel（缺省即关），改动即时持久化，
// subtitle-panel.js 通过 storage.onChanged 实时生效。Reset 按钮只清连接覆盖，不动此开关。
const nfSubList = $('nfSubList');
if (nfSubList) {
  chrome.storage.local.get('netflixSubtitlePanel').then((c) => {
    nfSubList.checked = !!(c && c.netflixSubtitlePanel === true);
  });
  nfSubList.onchange = async () => {
    await chrome.storage.local.set({ netflixSubtitlePanel: nfSubList.checked });
    $('status').textContent = nfSubList.checked ? ' Subtitle list on' : ' Subtitle list off';
  };
}

// 一键回到自动配置：清空覆盖，cfg() 便回落 app 注入的默认。
const resetBtn = $('reset');
if (resetBtn) {
  resetBtn.onclick = async () => {
    await chrome.storage.local.set({ host: '', port: 0, token: '' });
    $('host').value = '';
    $('port').value = '';
    $('token').value = '';
    $('status').textContent = ' Reset to auto';
  };
}
